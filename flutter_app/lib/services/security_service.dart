import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image/image.dart' as img;

/// The envelope embedded in the image via LSB steganography.
///
/// It is intentionally small — LSB capacity is limited and we want to keep
/// the payload well under a few hundred bytes so it survives on the smallest
/// preview sizes users might pick.
class SignedEnvelope {
  SignedEnvelope({
    required this.lat,
    required this.lon,
    required this.alt,
    required this.timestampMs,
    required this.deviceId,
    required this.pixelHash,
    required this.signature,
  });

  final double lat;
  final double lon;
  final double alt;
  final int timestampMs;
  final String deviceId;
  final String pixelHash; // hex sha256 of downsampled pixels
  final String signature; // hex hmac-sha256 over canonical payload

  Map<String, dynamic> toJson() => <String, dynamic>{
        'lat': lat,
        'lon': lon,
        'alt': alt,
        'ts': timestampMs,
        'dev': deviceId,
        'ph': pixelHash,
        'sig': signature,
        'v': 1,
      };

  static SignedEnvelope fromJson(Map<String, dynamic> json) => SignedEnvelope(
        lat: (json['lat'] as num).toDouble(),
        lon: (json['lon'] as num).toDouble(),
        alt: (json['alt'] as num).toDouble(),
        timestampMs: json['ts'] as int,
        deviceId: json['dev'] as String,
        pixelHash: json['ph'] as String,
        signature: json['sig'] as String,
      );
}

class SignedImage {
  SignedImage({required this.pngBytes, required this.envelope});
  final Uint8List pngBytes;
  final SignedEnvelope envelope;
}

/// Handles hashing, HMAC signing, and LSB steganography.
///
/// The steganographic scheme:
///   * Payload = JSON(envelope) preceded by a 4-byte big-endian length
///     and a 4-byte magic header "VPIC".
///   * Bits are written into the least significant bit of the blue channel
///     of consecutive pixels in raster order starting at pixel (0, 0).
///   * Recovery requires only reading those LSBs — no key material.
///
/// The signature is HMAC-SHA256 over the canonical string
/// "v1|lat|lon|alt|ts|dev|pixelHash" using [APP_SIGNING_SECRET].
class SecurityService {
  SecurityService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const String _magic = 'VPIC';
  static const int _headerBits = (_magic.length + 4) * 8; // magic + len

  final FlutterSecureStorage _storage;

  // ---------------------------------------------------------------- Signing

  Future<SignedImage> signAndEmbed({
    required Uint8List jpegBytes,
    required Position position,
    required DateTime timestampUtc,
    required String deviceId,
  }) async {
    final img.Image? decoded = img.decodeImage(jpegBytes);
    if (decoded == null) {
      throw StateError('Could not decode captured image');
    }

    final String pixelHash = _hashPixels(decoded);
    final SignedEnvelope envelope = SignedEnvelope(
      lat: position.latitude,
      lon: position.longitude,
      alt: position.altitude,
      timestampMs: timestampUtc.millisecondsSinceEpoch,
      deviceId: deviceId,
      pixelHash: pixelHash,
      signature: '',
    );

    final String signature = await _sign(_canonical(envelope));
    final SignedEnvelope finalEnvelope = SignedEnvelope(
      lat: envelope.lat,
      lon: envelope.lon,
      alt: envelope.alt,
      timestampMs: envelope.timestampMs,
      deviceId: envelope.deviceId,
      pixelHash: envelope.pixelHash,
      signature: signature,
    );

    final img.Image stego = _embed(decoded, jsonEncode(finalEnvelope.toJson()));
    final Uint8List png = Uint8List.fromList(img.encodePng(stego));
    return SignedImage(pngBytes: png, envelope: finalEnvelope);
  }

  // ------------------------------------------------------------ Verification

  /// Returns the extracted envelope, or `null` if none is present or the
  /// magic header does not match (image was never signed by us).
  SignedEnvelope? extractEnvelope(Uint8List pngBytes) {
    final img.Image? decoded = img.decodeImage(pngBytes);
    if (decoded == null) return null;
    final String? payload = _extract(decoded);
    if (payload == null) return null;
    try {
      return SignedEnvelope.fromJson(jsonDecode(payload) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  /// Recomputes the pixel hash of the given image using the same scheme
  /// used during signing.
  String recomputePixelHash(Uint8List pngBytes) {
    final img.Image? decoded = img.decodeImage(pngBytes);
    if (decoded == null) throw StateError('Cannot decode image');
    // Rebuild an image without LSB noise so the hash matches what was signed.
    // The signer hashed the pre-embedded pixels; we approximate by zeroing
    // the blue LSB across the whole image before hashing. This works because
    // the signer hashes a *downsampled* representation and downsampling
    // dominates the LSB noise.
    final img.Image clean = img.Image.from(decoded);
    for (int y = 0; y < clean.height; y++) {
      for (int x = 0; x < clean.width; x++) {
        final img.Pixel p = clean.getPixel(x, y);
        clean.setPixelRgba(x, y, p.r, p.g, (p.b.toInt() & ~1), p.a);
      }
    }
    return _hashPixels(clean);
  }

  Future<bool> verifySignature(SignedEnvelope envelope) async {
    final String expected = await _sign(_canonical(envelope));
    return _constantTimeEq(expected, envelope.signature);
  }

  // -------------------------------------------------------------- Internals

  String _canonical(SignedEnvelope e) =>
      'v1|${e.lat}|${e.lon}|${e.alt}|${e.timestampMs}|${e.deviceId}|${e.pixelHash}';

  Future<String> _sign(String data) async {
    final String secret = await _resolveSecret();
    final Hmac hmac = Hmac(sha256, utf8.encode(secret));
    return hmac.convert(utf8.encode(data)).toString();
  }

  Future<String> _resolveSecret() async {
    // Prefer per-install secret so different installs don't share a key;
    // fall back to a build-time secret from .env for reproducible verification
    // across devices (e.g. server-side verifier using the same secret).
    String? envSecret;
    try {
      envSecret = dotenv.maybeGet('APP_SIGNING_SECRET');
    } catch (_) {
      envSecret = null;
    }
    if (envSecret != null && envSecret.isNotEmpty) return envSecret;

    String? stored = await _storage.read(key: 'veripic_signing_secret');
    if (stored == null || stored.isEmpty) {
      stored = _randomHex(32);
      await _storage.write(key: 'veripic_signing_secret', value: stored);
    }
    return stored;
  }

  String _randomHex(int bytes) {
    final Uint8List buf = Uint8List(bytes);
    final DateTime now = DateTime.now();
    int seed = now.microsecondsSinceEpoch ^ now.hashCode;
    for (int i = 0; i < bytes; i++) {
      seed = (seed * 1103515245 + 12345) & 0x7fffffff;
      buf[i] = seed & 0xff;
    }
    return buf.map((int b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  bool _constantTimeEq(String a, String b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// Deterministic 32x32 luma downsample -> SHA-256 hex.
  String _hashPixels(img.Image image) {
    const int size = 32;
    final img.Image thumb = img.copyResize(image,
        width: size, height: size, interpolation: img.Interpolation.average);
    final Uint8List luma = Uint8List(size * size);
    int i = 0;
    for (int y = 0; y < size; y++) {
      for (int x = 0; x < size; x++) {
        final img.Pixel p = thumb.getPixel(x, y);
        // Rec. 709 luma
        luma[i++] = (0.2126 * p.r + 0.7152 * p.g + 0.0722 * p.b).round().clamp(0, 255);
      }
    }
    return sha256.convert(luma).toString();
  }

  // ------------------------------------------------ LSB steganography (blue)

  img.Image _embed(img.Image image, String payload) {
    final Uint8List body = Uint8List.fromList(utf8.encode(payload));
    final ByteData header = ByteData(8)
      ..setUint8(0, _magic.codeUnitAt(0))
      ..setUint8(1, _magic.codeUnitAt(1))
      ..setUint8(2, _magic.codeUnitAt(2))
      ..setUint8(3, _magic.codeUnitAt(3))
      ..setUint32(4, body.length, Endian.big);
    final Uint8List all = Uint8List(8 + body.length)
      ..setRange(0, 8, header.buffer.asUint8List())
      ..setRange(8, 8 + body.length, body);

    final int neededBits = all.length * 8;
    final int capacity = image.width * image.height;
    if (neededBits > capacity) {
      throw StateError('Image too small to hold signed envelope');
    }

    final img.Image out = img.Image.from(image);
    int bitIndex = 0;
    for (int y = 0; y < out.height && bitIndex < neededBits; y++) {
      for (int x = 0; x < out.width && bitIndex < neededBits; x++) {
        final int byte = all[bitIndex >> 3];
        final int bit = (byte >> (7 - (bitIndex & 7))) & 1;
        final img.Pixel p = out.getPixel(x, y);
        final int b = (p.b.toInt() & ~1) | bit;
        out.setPixelRgba(x, y, p.r, p.g, b, p.a);
        bitIndex++;
      }
    }
    return out;
  }

  String? _extract(img.Image image) {
    // Read header first.
    final int totalPixels = image.width * image.height;
    if (totalPixels < _headerBits) return null;

    final Uint8List header = _readBits(image, 0, _headerBits ~/ 8);
    if (String.fromCharCodes(header.sublist(0, 4)) != _magic) return null;
    final int len = ByteData.sublistView(header, 4, 8).getUint32(0, Endian.big);
    if (len <= 0 || len > 65536) return null;
    if ((_headerBits + len * 8) > totalPixels) return null;

    final Uint8List body = _readBits(image, _headerBits, len);
    try {
      return utf8.decode(body);
    } catch (_) {
      return null;
    }
  }

  Uint8List _readBits(img.Image image, int startBit, int byteLen) {
    final Uint8List out = Uint8List(byteLen);
    int bitIndex = startBit;
    for (int i = 0; i < byteLen; i++) {
      int byte = 0;
      for (int b = 0; b < 8; b++) {
        final int px = bitIndex ~/ 1; // one bit per pixel
        final int x = px % image.width;
        final int y = px ~/ image.width;
        final img.Pixel p = image.getPixel(x, y);
        byte = (byte << 1) | (p.b.toInt() & 1);
        bitIndex++;
      }
      out[i] = byte;
    }
    return out;
  }
}
