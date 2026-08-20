import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image/image.dart' as img;

import 'device_service.dart';

/// How a signing key came to exist. Surfaced in the verification UI so an
/// operator can tell a hardware-bound signature from a legacy one.
enum SigningKeyOrigin {
  /// HKDF-SHA256 derived from the device's hardware identifier.
  hardwareDerived,

  /// Pre-2026 randomly generated per-install secret. Verify-only.
  legacyRandom,
}

extension SigningKeyOriginLabel on SigningKeyOrigin {
  String get label => switch (this) {
        SigningKeyOrigin.hardwareDerived => 'Hardware-derived (HKDF-SHA256)',
        SigningKeyOrigin.legacyRandom => 'Legacy random secret (v3)',
      };

  String get storageCode => switch (this) {
        SigningKeyOrigin.hardwareDerived => 'hkdf',
        SigningKeyOrigin.legacyRandom => 'legacy',
      };

  static SigningKeyOrigin fromCode(String? code) =>
      code == 'legacy' ? SigningKeyOrigin.legacyRandom : SigningKeyOrigin.hardwareDerived;
}

/// One HMAC key in the device key ring.
///
/// The ring exists so that rotating the hardware-derived key (factory reset,
/// device swap, migration off the legacy random secret) never orphans photos
/// that were already signed — verification walks the whole ring.
class SigningKey {
  const SigningKey({
    required this.kid,
    required this.material,
    required this.origin,
    required this.createdAtMs,
  });

  /// Key identifier: first 16 hex chars of SHA-256 over the key material.
  /// Embedded in v4 envelopes so verification can pick the right key directly.
  final String kid;

  /// Raw HMAC key bytes.
  final Uint8List material;

  final SigningKeyOrigin origin;
  final int createdAtMs;

  static String kidFor(List<int> material) =>
      sha256.convert(material).toString().substring(0, 16);

  factory SigningKey.fromMaterial(
    List<int> material,
    SigningKeyOrigin origin, {
    int? createdAtMs,
  }) {
    final Uint8List bytes = Uint8List.fromList(material);
    return SigningKey(
      kid: kidFor(bytes),
      material: bytes,
      origin: origin,
      createdAtMs: createdAtMs ?? DateTime.now().millisecondsSinceEpoch,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kid': kid,
        'mat': base64Encode(material),
        'org': origin.storageCode,
        'ts': createdAtMs,
      };

  static SigningKey fromJson(Map<String, dynamic> json) => SigningKey(
        kid: json['kid'] as String,
        material: base64Decode(json['mat'] as String),
        origin: SigningKeyOriginLabel.fromCode(json['org'] as String?),
        createdAtMs: (json['ts'] as num?)?.toInt() ?? 0,
      );
}

/// Result of an HMAC check, including *which* key matched.
class SignatureCheck {
  const SignatureCheck({required this.valid, this.matchedKey, this.note});

  final bool valid;
  final SigningKey? matchedKey;
  final String? note;

  SigningKeyOrigin? get origin => matchedKey?.origin;
}

class SignedEnvelope {
  SignedEnvelope({
    required this.lat,
    required this.lon,
    required this.alt,
    required this.timestampMs,
    required this.deviceId,
    required this.pixelHash,
    required this.signature,
    this.kid,
    this.version = SecurityService.envelopeVersion,
  });

  final double lat;
  final double lon;
  final double alt;
  final int timestampMs;
  final String deviceId;
  final String pixelHash;
  final String signature;

  /// Key identifier. Null for pre-v4 envelopes signed before key ring support.
  final String? kid;

  final int version;

  bool get isHardwareBound => version >= 4 && kid != null;

  SignedEnvelope copyWith({String? signature, String? kid, int? version}) =>
      SignedEnvelope(
        lat: lat,
        lon: lon,
        alt: alt,
        timestampMs: timestampMs,
        deviceId: deviceId,
        pixelHash: pixelHash,
        signature: signature ?? this.signature,
        kid: kid ?? this.kid,
        version: version ?? this.version,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'lat': lat,
        'lon': lon,
        'alt': alt,
        'ts': timestampMs,
        'dev': deviceId,
        'ph': pixelHash,
        'sig': signature,
        if (kid != null) 'kid': kid,
        'v': version,
      };

  static SignedEnvelope fromJson(Map<String, dynamic> json) => SignedEnvelope(
        lat: _toDouble(json['lat']),
        lon: _toDouble(json['lon']),
        alt: _toDouble(json['alt']),
        timestampMs: (json['ts'] as num?)?.toInt() ?? 0,
        deviceId: json['dev'] as String? ?? '',
        pixelHash: json['ph'] as String? ?? '',
        signature: json['sig'] as String? ?? '',
        kid: json['kid'] as String?,
        // Envelopes written before the key ring carried v:3 (or nothing).
        version: (json['v'] as num?)?.toInt() ?? 3,
      );

  static double _toDouble(Object? v) =>
      v is num ? v.toDouble() : double.tryParse('$v') ?? 0.0;
}

class SignedImage {
  SignedImage({required this.pngBytes, required this.envelope, this.signingKey});

  /// Final encoded JPEG bytes (name kept for call-site compatibility).
  final Uint8List pngBytes;
  final SignedEnvelope envelope;
  final SigningKey? signingKey;
}

class SecurityService {
  SecurityService({FlutterSecureStorage? storage, DeviceService? deviceService})
      : _storage = storage ?? const FlutterSecureStorage(),
        _deviceService = deviceService ?? DeviceService();

  final FlutterSecureStorage _storage;
  final DeviceService _deviceService;

  // ---------------------------------------------------------------------
  // Key derivation parameters (Requirement 1)
  //
  //   Key = HKDF-SHA256(
  //     IKM  = <hardware device seed>,
  //     Salt = "VeriPic-Device-Salt-2026",
  //     Info = "HMAC-Image-Signing",
  //   )
  // ---------------------------------------------------------------------
  static const String hkdfSalt = 'VeriPic-Device-Salt-2026';
  static const String hkdfInfo = 'HMAC-Image-Signing';
  static const int hkdfKeyLength = 32;

  /// Current envelope schema version.
  static const int envelopeVersion = 4;

  /// Key ring (v4+). Holds the active hardware-derived key plus any historical
  /// keys needed to verify older captures.
  static const String _keyRingStorageKey = 'veripic_key_ring_v4';

  /// Legacy per-install random secret (v3 and earlier). Read-only — imported
  /// into the ring once so old photos stay verifiable, never used for signing.
  static const String _legacySecretStorageKey = 'veripic_hw_signing_key_v3';

  static const int maxPerceptualHammingDistance = 10;

  static const String _comMarker = 'VPIC_METADATA:';
  static const String _eofMarker = 'VPIC_PAYLOAD:';

  List<SigningKey>? _ringCache;
  SigningKey? _activeKeyCache;
  Future<SigningKey>? _activeKeyInFlight;

  // =====================================================================
  // HKDF-SHA256 (RFC 5869)
  // =====================================================================

  /// RFC 5869 HKDF using SHA-256. Pure `package:crypto`, no native deps.
  static Uint8List hkdfSha256({
    required List<int> ikm,
    required List<int> salt,
    required List<int> info,
    int length = hkdfKeyLength,
  }) {
    if (length <= 0 || length > 255 * 32) {
      throw ArgumentError.value(length, 'length', 'Invalid HKDF output length');
    }

    // Extract: PRK = HMAC-SHA256(salt, IKM)
    final List<int> prk =
        Hmac(sha256, salt.isEmpty ? Uint8List(32) : salt).convert(ikm).bytes;

    // Expand: T(n) = HMAC-SHA256(PRK, T(n-1) | info | n)
    final BytesBuilder okm = BytesBuilder(copy: false);
    List<int> previous = const <int>[];
    int counter = 1;
    while (okm.length < length) {
      final List<int> block = <int>[...previous, ...info, counter];
      previous = Hmac(sha256, prk).convert(block).bytes;
      okm.add(previous);
      counter++;
    }

    return Uint8List.fromList(okm.toBytes().sublist(0, length));
  }

  // =====================================================================
  // Key ring management
  // =====================================================================

  /// Resolves the active hardware-bound signing key, deriving and caching it in
  /// the Keystore/Keychain on first use.
  Future<SigningKey> activeKey() {
    final SigningKey? cached = _activeKeyCache;
    if (cached != null) return Future<SigningKey>.value(cached);
    return _activeKeyInFlight ??= _resolveActiveKey().then((SigningKey k) {
      _activeKeyCache = k;
      _activeKeyInFlight = null;
      return k;
    }, onError: (Object e) {
      _activeKeyInFlight = null;
      throw e;
    });
  }

  Future<SigningKey> _resolveActiveKey() async {
    final String seed = await _deviceService.hardwareSeed();
    final Uint8List material = hkdfSha256(
      ikm: utf8.encode(seed),
      salt: utf8.encode(hkdfSalt),
      info: utf8.encode(hkdfInfo),
    );
    final SigningKey derived =
        SigningKey.fromMaterial(material, SigningKeyOrigin.hardwareDerived);

    // Persist into the ring so verification of today's captures still works
    // after a future key rotation.
    await _ensureInRing(derived);
    return derived;
  }

  /// Every key this device can verify with: the hardware-derived key, any
  /// previously derived keys, and the imported legacy random secret.
  Future<List<SigningKey>> keyRing() async {
    final List<SigningKey>? cached = _ringCache;
    if (cached != null) return cached;

    final List<SigningKey> ring = <SigningKey>[];
    try {
      final String? raw = await _storage.read(key: _keyRingStorageKey);
      if (raw != null && raw.isNotEmpty) {
        final Map<String, dynamic> decoded =
            jsonDecode(raw) as Map<String, dynamic>;
        for (final Object? entry in (decoded['keys'] as List<dynamic>? ??
            const <dynamic>[])) {
          if (entry is Map<String, dynamic>) {
            ring.add(SigningKey.fromJson(entry));
          }
        }
      }
    } catch (_) {
      // Corrupt ring — rebuild from scratch rather than blocking capture.
    }

    // One-time import of the pre-2026 random secret so previously signed
    // envelopes remain verifiable (Requirement 1, backward compatibility).
    final SigningKey? legacy = await _readLegacyKey();
    if (legacy != null && !ring.any((SigningKey k) => k.kid == legacy.kid)) {
      ring.add(legacy);
      await _persistRing(ring);
    }

    _ringCache = ring;
    return ring;
  }

  Future<SigningKey?> _readLegacyKey() async {
    try {
      final String? secret = await _storage.read(key: _legacySecretStorageKey);
      if (secret == null || secret.isEmpty) return null;
      // v3 signed with `Hmac(sha256, utf8.encode(secret))`, so the legacy key
      // material is the UTF-8 bytes of the stored string — not its base64
      // decoding. Reproduce that exactly.
      return SigningKey.fromMaterial(
        utf8.encode(secret),
        SigningKeyOrigin.legacyRandom,
        createdAtMs: 0,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _ensureInRing(SigningKey key) async {
    final List<SigningKey> ring = List<SigningKey>.of(await keyRing());
    if (ring.any((SigningKey k) => k.kid == key.kid)) return;
    ring.add(key);
    await _persistRing(ring);
    _ringCache = ring;
  }

  Future<void> _persistRing(List<SigningKey> ring) async {
    try {
      await _storage.write(
        key: _keyRingStorageKey,
        value: jsonEncode(<String, dynamic>{
          'keys': ring.map((SigningKey k) => k.toJson()).toList(),
        }),
      );
    } catch (_) {
      // Secure storage unavailable (rare OEM Keystore failures). Signing still
      // works this session because the key is deterministically derivable.
    }
  }

  /// Diagnostics for the UI: active key id + how many verify-only keys exist.
  Future<Map<String, String>> keyDiagnostics() async {
    try {
      final SigningKey active = await activeKey();
      final List<SigningKey> ring = await keyRing();
      return <String, String>{
        'Key derivation': 'HKDF-SHA256',
        'Salt': hkdfSalt,
        'Info': hkdfInfo,
        'Active key id': active.kid,
        'Key origin': active.origin.label,
        'Keys in ring': '${ring.length}',
      };
    } catch (e) {
      return <String, String>{'Key derivation': 'unavailable: $e'};
    }
  }

  /// Test hook — clears in-memory key caches.
  void resetKeyCache() {
    _ringCache = null;
    _activeKeyCache = null;
    _activeKeyInFlight = null;
  }

  // =====================================================================
  // Signing + embedding
  // =====================================================================

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
    final SigningKey key = await activeKey();

    final SignedEnvelope unsigned = SignedEnvelope(
      lat: position.latitude,
      lon: position.longitude,
      alt: position.altitude,
      timestampMs: timestampUtc.millisecondsSinceEpoch,
      deviceId: deviceId,
      pixelHash: pixelHash,
      signature: '',
      kid: key.kid,
    );

    final String signature = _hmacHex(key, _canonical(unsigned));
    final SignedEnvelope envelope = unsigned.copyWith(signature: signature);
    final String jsonPayload = jsonEncode(envelope.toJson());

    // Embed #1 — EXIF UserComment (survives most metadata-preserving tools).
    try {
      decoded.exif.imageIfd['UserComment'] = '$_comMarker$jsonPayload';
    } catch (_) {
      // EXIF write is best-effort; the COM + EOF copies still carry the payload.
    }

    // `image` 4.x keeps `textData` for PNG only — the JPEG encoder drops it —
    // so the JPEG COM segment below is written by hand instead.
    decoded.textData ??= <String, String>{};
    decoded.textData!['Comment'] = '$_comMarker$jsonPayload';

    final Uint8List encoded =
        Uint8List.fromList(img.encodeJpg(decoded, quality: 95));

    // Embed #2 — real JPEG COM (0xFFFE) segment injected after SOI.
    final Uint8List withComment =
        _injectJpegComment(encoded, '$_comMarker$jsonPayload');

    // Embed #3 — EOF payload (survives EXIF stripping).
    final BytesBuilder builder = BytesBuilder(copy: false)
      ..add(withComment)
      ..add(utf8.encode('$_eofMarker$jsonPayload'));

    return SignedImage(
      pngBytes: builder.toBytes(),
      envelope: envelope,
      signingKey: key,
    );
  }

  /// Inserts a standards-compliant JPEG COM segment directly after the SOI
  /// marker. Returns the input untouched if it is not a JPEG or the payload is
  /// too large for a single segment.
  Uint8List _injectJpegComment(Uint8List jpeg, String comment) {
    if (jpeg.length < 2 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) return jpeg;

    final List<int> payload = utf8.encode(comment);
    // Segment length field covers itself (2 bytes) + payload, max 65535.
    if (payload.length + 2 > 0xFFFF) return jpeg;
    final int segLength = payload.length + 2;

    final BytesBuilder out = BytesBuilder(copy: false)
      ..add(<int>[0xFF, 0xD8]) // SOI
      ..add(<int>[0xFF, 0xFE]) // COM marker
      ..add(<int>[(segLength >> 8) & 0xFF, segLength & 0xFF])
      ..add(payload)
      ..add(Uint8List.sublistView(jpeg, 2));

    return out.toBytes();
  }

  // =====================================================================
  // Extraction
  // =====================================================================

  /// Recovers the envelope from any of the three embed sites. Tolerant of
  /// every historical layout so previously signed photos still parse.
  SignedEnvelope? extractEnvelope(Uint8List imageBytes) {
    // 1. EOF payload — the most robust copy, and the only one older builds
    //    reliably produced.
    try {
      final String raw = latin1.decode(imageBytes, allowInvalid: true);
      final int idx = raw.lastIndexOf(_eofMarker);
      if (idx != -1) {
        final SignedEnvelope? env =
            _parseEnvelopeAt(raw, idx + _eofMarker.length);
        if (env != null) return env;
      }

      // 2. COM segment / EXIF UserComment — both are plain bytes in the file,
      //    so a single scan finds either.
      final int comIdx = raw.indexOf(_comMarker);
      if (comIdx != -1) {
        final SignedEnvelope? env =
            _parseEnvelopeAt(raw, comIdx + _comMarker.length);
        if (env != null) return env;
      }
    } catch (_) {}

    // 3. Decoder-assisted fallback: PNG text chunks and parsed EXIF.
    try {
      final img.Image? decoded = img.decodeImage(imageBytes);
      if (decoded != null) {
        final String? text = decoded.textData?['Comment'];
        if (text != null && text.contains(_comMarker)) {
          final SignedEnvelope? env = _parseEnvelopeAt(
              text, text.indexOf(_comMarker) + _comMarker.length);
          if (env != null) return env;
        }
        final String? userComment =
            decoded.exif.imageIfd['UserComment']?.toString();
        if (userComment != null && userComment.contains(_comMarker)) {
          final SignedEnvelope? env = _parseEnvelopeAt(userComment,
              userComment.indexOf(_comMarker) + _comMarker.length);
          if (env != null) return env;
        }
      }
    } catch (_) {}

    return null;
  }

  SignedEnvelope? _parseEnvelopeAt(String source, int start) {
    final String? jsonStr = _balancedJsonFrom(source, start);
    if (jsonStr == null) return null;
    try {
      final Object? decoded = jsonDecode(jsonStr);
      if (decoded is Map<String, dynamic>) {
        return SignedEnvelope.fromJson(decoded);
      }
    } catch (_) {}
    return null;
  }

  /// Extracts one brace-balanced JSON object starting at/after [start].
  ///
  /// Needed because the COM/EXIF copies are found by scanning raw bytes, so
  /// there is no delimiter marking where the JSON ends.
  String? _balancedJsonFrom(String source, int start) {
    final int open = source.indexOf('{', start);
    if (open == -1) return null;

    int depth = 0;
    bool inString = false;
    bool escaped = false;

    for (int i = open; i < source.length; i++) {
      final String c = source[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (c == r'\') {
          escaped = true;
        } else if (c == '"') {
          inString = false;
        }
        continue;
      }
      if (c == '"') {
        inString = true;
      } else if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0) return source.substring(open, i + 1);
      }
    }
    return null;
  }

  // =====================================================================
  // Perceptual hashing
  // =====================================================================

  String computeBannerDHash(img.Image image) {
    final int bannerHeight = max(8, (image.height * 0.18).toInt());
    final int bannerY = max(0, image.height - bannerHeight);

    final img.Image bannerCrop = img.copyCrop(
      image,
      x: 0,
      y: bannerY,
      width: image.width,
      height: min(bannerHeight, image.height),
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
    if (hash1.isEmpty || hash2.isEmpty) return 64;
    if (hash1.length != hash2.length) return 64;
    try {
      BigInt xorVal = BigInt.parse(hash1, radix: 16) ^
          BigInt.parse(hash2, radix: 16);
      int distance = 0;
      while (xorVal > BigInt.zero) {
        if ((xorVal & BigInt.one) == BigInt.one) distance++;
        xorVal >>= 1;
      }
      return distance;
    } catch (_) {
      return 64;
    }
  }

  // =====================================================================
  // Verification
  // =====================================================================

  /// Backward-compatible boolean check.
  Future<bool> verifySignature(SignedEnvelope envelope) async =>
      (await verifySignatureDetailed(envelope)).valid;

  /// Verifies against the whole key ring and reports which key matched.
  ///
  /// Order of attempts:
  ///   1. the key named by `envelope.kid` (v4 envelopes — the fast path),
  ///   2. the active hardware-derived key,
  ///   3. every remaining ring key, including the imported legacy secret.
  Future<SignatureCheck> verifySignatureDetailed(
      SignedEnvelope envelope) async {
    if (envelope.signature.isEmpty) {
      return const SignatureCheck(valid: false, note: 'Envelope carries no signature');
    }

    final String canonical = _canonical(envelope);
    final List<SigningKey> candidates = <SigningKey>[];

    try {
      final SigningKey active = await activeKey();
      candidates.add(active);
    } catch (_) {
      // Hardware seed unavailable — fall back to whatever the ring holds.
    }

    try {
      for (final SigningKey k in await keyRing()) {
        if (!candidates.any((SigningKey c) => c.kid == k.kid)) {
          candidates.add(k);
        }
      }
    } catch (_) {}

    if (candidates.isEmpty) {
      return const SignatureCheck(
          valid: false, note: 'No signing keys available on this device');
    }

    // Prefer the key the envelope names, when we hold it.
    final String? kid = envelope.kid;
    if (kid != null) {
      final int i = candidates.indexWhere((SigningKey k) => k.kid == kid);
      if (i > 0) candidates.insert(0, candidates.removeAt(i));
    }

    for (final SigningKey key in candidates) {
      if (_constantTimeEq(_hmacHex(key, canonical), envelope.signature)) {
        return SignatureCheck(
          valid: true,
          matchedKey: key,
          note: key.origin == SigningKeyOrigin.legacyRandom
              ? 'Verified with the legacy v3 secret retained for backward compatibility.'
              : 'Verified with the hardware-bound HKDF-SHA256 key.',
        );
      }
    }

    return SignatureCheck(
      valid: false,
      note: kid != null && candidates.every((SigningKey k) => k.kid != kid)
          ? 'Signed by key $kid, which this device does not hold.'
          : 'No key in the device ring reproduces this signature.',
    );
  }

  /// Canonical string bound by the HMAC.
  ///
  /// v4 envelopes additionally bind the key id, so an attacker cannot strip
  /// `kid` to force a downgrade — removing it changes the canonical form and
  /// therefore invalidates the signature. Pre-v4 envelopes keep the exact
  /// original `v1|…` layout so they still verify byte-for-byte.
  String _canonical(SignedEnvelope e) {
    final String base =
        '${e.lat}|${e.lon}|${e.alt}|${e.timestampMs}|${e.deviceId}|${e.pixelHash}';
    final String? kid = e.kid;
    return kid == null ? 'v1|$base' : 'v4|$base|$kid';
  }

  String _hmacHex(SigningKey key, String data) =>
      Hmac(sha256, key.material).convert(utf8.encode(data)).toString();

  bool _constantTimeEq(String a, String b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
