import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image/image.dart' as img;

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
  final String pixelHash;
  final String signature;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'lat': lat,
        'lon': lon,
        'alt': alt,
        'ts': timestampMs,
        'dev': deviceId,
        'ph': pixelHash,
        'sig': signature,
        'v': 3,
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

class SecurityService {
  SecurityService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  static const String _secretStorageKey = 'veripic_hw_signing_key_v3';
  final FlutterSecureStorage _storage;

  static const int maxPerceptualHammingDistance = 10;

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

    final String pixelHash = computeBannerDHash(decoded);

    final SignedEnvelope unsigned = SignedEnvelope(
      lat: position.latitude,
      lon: position.longitude,
      alt: position.altitude,
      timestampMs: timestampUtc.millisecondsSinceEpoch,
      deviceId: deviceId,
      pixelHash: pixelHash,
      signature: '',
    );

    final String signature = await _sign(_canonical(unsigned));
    final SignedEnvelope finalEnvelope = SignedEnvelope(
      lat: unsigned.lat,
      lon: unsigned.lon,
      alt: unsigned.alt,
      timestampMs: unsigned.timestampMs,
      deviceId: unsigned.deviceId,
      pixelHash: unsigned.pixelHash,
      signature: signature,
    );

    final String jsonPayload = jsonEncode(finalEnvelope.toJson());
    decoded.textData ??= {};
    decoded.textData!['Comment'] = 'VPIC_METADATA:$jsonPayload';

    final Uint8List finalJpeg =
        Uint8List.fromList(img.encodeJpg(decoded, quality: 95));

    final List<int> footerBytes = utf8.encode('VPIC_PAYLOAD:$jsonPayload');
    final BytesBuilder builder = BytesBuilder();
    builder.add(finalJpeg);
    builder.add(footerBytes);

    return SignedImage(pngBytes: builder.toBytes(), envelope: finalEnvelope);
  }

  SignedEnvelope? extractEnvelope(Uint8List imageBytes) {
    try {
      final String raw = latin1.decode(imageBytes);
      final int idx = raw.lastIndexOf('VPIC_PAYLOAD:');
      if (idx != -1) {
        final String jsonStr = raw.substring(idx + 'VPIC_PAYLOAD:'.length);
        return SignedEnvelope.fromJson(
            jsonDecode(jsonStr) as Map<String, dynamic>);
      }
    } catch (_) {}

    try {
      final img.Image? decoded = img.decodeImage(imageBytes);
      if (decoded != null && decoded.textData != null) {
        final String? comment = decoded.textData!['Comment'];
        if (comment != null && comment.startsWith('VPIC_METADATA:')) {
          final String jsonStr = comment.substring('VPIC_METADATA:'.length);
          return SignedEnvelope.fromJson(
              jsonDecode(jsonStr) as Map<String, dynamic>);
        }
      }
    } catch (_) {}

    return null;
  }

  String computeBannerDHash(img.Image image) {
    final int bannerHeight = (image.height * 0.18).toInt();
    final int bannerY = image.height - bannerHeight;

    final img.Image bannerCrop = img.copyCrop(
      image,
      x: 0,
      y: bannerY,
      width: image.width,
      height: bannerHeight,
    );

    final img.Image resized = img.copyResize(
      bannerCrop,
      width: 9,
      height: 8,
      interpolation: img.Interpolation.average,
    );

    int dHash = 0;
    int bitIndex = 0;

    for (int y = 0; y < 8; y++) {
      for (int x = 0; x < 8; x++) {
        final img.Pixel pLeft = resized.getPixel(x, y);
        final img.Pixel pRight = resized.getPixel(x + 1, y);

        final int lumaLeft =
            (0.299 * pLeft.r + 0.587 * pLeft.g + 0.114 * pLeft.b).round();
        final int lumaRight =
            (0.299 * pRight.r + 0.587 * pRight.g + 0.114 * pRight.b).round();

        if (lumaLeft > lumaRight) {
          dHash |= (1 << (63 - bitIndex));
        }
        bitIndex++;
      }
    }

    return dHash.toRadixString(16).padLeft(16, '0');
  }

  int hammingDistance(String hash1, String hash2) {
    if (hash1.length != hash2.length) return 64;
    final BigInt val1 = BigInt.parse(hash1, radix: 16);
    final BigInt val2 = BigInt.parse(hash2, radix: 16);
    BigInt xorVal = val1 ^ val2;

    int distance = 0;
    while (xorVal > BigInt.zero) {
      if ((xorVal & BigInt.one) == BigInt.one) distance++;
      xorVal >>= 1;
    }
    return distance;
  }

  Future<bool> verifySignature(SignedEnvelope envelope) async {
    final String expected = await _sign(_canonical(envelope));
    return _constantTimeEq(expected, envelope.signature);
  }

  String _canonical(SignedEnvelope e) =>
      'v1|${e.lat}|${e.lon}|${e.alt}|${e.timestampMs}|${e.deviceId}|${e.pixelHash}';

  Future<String> _sign(String data) async {
    final String secret = await _resolveSecret();
    final Hmac hmac = Hmac(sha256, utf8.encode(secret));
    return hmac.convert(utf8.encode(data)).toString();
  }

  Future<String> _resolveSecret() async {
    String? stored = await _storage.read(key: _secretStorageKey);
    if (stored == null || stored.isEmpty) {
      stored = _generateRandomSecret();
      await _storage.write(key: _secretStorageKey, value: stored);
    }
    return stored;
  }

  String _generateRandomSecret() {
    final Random rng = Random.secure();
    final List<int> bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    return base64UrlEncode(bytes);
  }

  bool _constantTimeEq(String a, String b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}