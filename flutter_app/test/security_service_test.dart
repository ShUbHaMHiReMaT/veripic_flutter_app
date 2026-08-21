import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:geoguard/services/security_service.dart';

/// Hex helper for the RFC test vectors.
Uint8List _hex(String s) {
  final Uint8List out = Uint8List(s.length ~/ 2);
  for (int i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _toHex(List<int> b) =>
    b.map((int x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  group('HKDF-SHA256 (RFC 5869)', () {
    test('matches Test Case 1', () {
      // https://datatracker.ietf.org/doc/html/rfc5869#appendix-A.1
      final Uint8List okm = SecurityService.hkdfSha256(
        ikm: _hex('0b' * 22),
        salt: _hex('000102030405060708090a0b0c'),
        info: _hex('f0f1f2f3f4f5f6f7f8f9'),
        length: 42,
      );

      expect(
        _toHex(okm),
        '3cb25f25faacd57a90434f64d0362f2a'
        '2d2d0a90cf1a5a4c5db02d56ecc4c5bf'
        '34007208d5b887185865',
      );
    });

    test('matches Test Case 3 (empty salt and info)', () {
      // https://datatracker.ietf.org/doc/html/rfc5869#appendix-A.3
      final Uint8List okm = SecurityService.hkdfSha256(
        ikm: _hex('0b' * 22),
        salt: const <int>[],
        info: const <int>[],
        length: 42,
      );

      expect(
        _toHex(okm),
        '8da4e775a563c18f715f802a063c5a31'
        'b8a11f5c5ee1879ec3454e5f3c738d2d'
        '9d201395faa4b61a96c8',
      );
    });

    test('is deterministic for the documented parameters', () {
      const String seed = 'veripic|android|abc123|brand=Google|model=Pixel 7';
      Uint8List derive() => SecurityService.hkdfSha256(
            ikm: utf8.encode(seed),
            salt: utf8.encode(SecurityService.hkdfSalt),
            info: utf8.encode(SecurityService.hkdfInfo),
          );

      expect(derive(), equals(derive()));
      expect(derive().length, 32);
    });

    test('a different hardware seed yields a different key', () {
      Uint8List derive(String seed) => SecurityService.hkdfSha256(
            ikm: utf8.encode(seed),
            salt: utf8.encode(SecurityService.hkdfSalt),
            info: utf8.encode(SecurityService.hkdfInfo),
          );

      expect(derive('device-a'), isNot(equals(derive('device-b'))));
    });
  });

  group('SigningKey', () {
    test('key id is a stable 16-hex-char digest of the material', () {
      final SigningKey k = SigningKey.fromMaterial(
        utf8.encode('material'),
        SigningKeyOrigin.hardwareDerived,
      );
      expect(k.kid.length, 16);
      expect(RegExp(r'^[0-9a-f]{16}$').hasMatch(k.kid), isTrue);
      expect(
        SigningKey.fromMaterial(
                utf8.encode('material'), SigningKeyOrigin.hardwareDerived)
            .kid,
        k.kid,
      );
    });

    test('survives a JSON round-trip', () {
      final SigningKey k = SigningKey.fromMaterial(
        List<int>.generate(32, (int i) => i),
        SigningKeyOrigin.legacyRandom,
      );
      final SigningKey back = SigningKey.fromJson(k.toJson());

      expect(back.kid, k.kid);
      expect(back.material, k.material);
      expect(back.origin, SigningKeyOrigin.legacyRandom);
    });
  });

  group('SignedEnvelope', () {
    test('v4 round-trips through JSON', () {
      final SignedEnvelope e = SignedEnvelope(
        lat: 15.8497,
        lon: 74.4977,
        alt: 751.2,
        timestampMs: 1770000000000,
        deviceId: 'a' * 64,
        pixelHash: '0123456789abcdef',
        signature: 'f' * 64,
        kid: '00112233aabbccdd',
      );

      final SignedEnvelope back =
          SignedEnvelope.fromJson(jsonDecode(jsonEncode(e.toJson()))
              as Map<String, dynamic>);

      expect(back.lat, e.lat);
      expect(back.lon, e.lon);
      expect(back.alt, e.alt);
      expect(back.timestampMs, e.timestampMs);
      expect(back.deviceId, e.deviceId);
      expect(back.pixelHash, e.pixelHash);
      expect(back.signature, e.signature);
      expect(back.kid, e.kid);
      expect(back.version, SecurityService.envelopeVersion);
      expect(back.isHardwareBound, isTrue);
    });

    test('parses a legacy v3 envelope with no key id', () {
      // Exactly the shape written by the pre-2026 build.
      const String legacy = '{"lat":15.8,"lon":74.4,"alt":700.0,'
          '"ts":1700000000000,"dev":"deadbeef","ph":"0123456789abcdef",'
          '"sig":"abc","v":3}';

      final SignedEnvelope e =
          SignedEnvelope.fromJson(jsonDecode(legacy) as Map<String, dynamic>);

      expect(e.version, 3);
      expect(e.kid, isNull);
      expect(e.isHardwareBound, isFalse);
      expect(e.deviceId, 'deadbeef');
    });

    test('tolerates integer-typed coordinates and a missing version', () {
      const String odd = '{"lat":15,"lon":74,"alt":0,"ts":1,'
          '"dev":"x","ph":"y","sig":"z"}';

      final SignedEnvelope e =
          SignedEnvelope.fromJson(jsonDecode(odd) as Map<String, dynamic>);

      expect(e.lat, 15.0);
      expect(e.version, 3); // defaults to the pre-key-ring schema
    });
  });

  group('hammingDistance', () {
    final SecurityService s = SecurityService();

    test('identical hashes score zero', () {
      expect(s.hammingDistance('0123456789abcdef', '0123456789abcdef'), 0);
    });

    test('counts differing bits', () {
      // 0x...0 vs 0x...f differs in 4 bits.
      expect(s.hammingDistance('0000000000000000', '000000000000000f'), 4);
      expect(s.hammingDistance('0000000000000000', 'ffffffffffffffff'), 64);
    });

    test('mismatched or empty inputs are treated as maximally distant', () {
      expect(s.hammingDistance('abc', 'abcdef0123456789'), 64);
      expect(s.hammingDistance('', '0123456789abcdef'), 64);
      expect(s.hammingDistance('zzzzzzzzzzzzzzzz', '0123456789abcdef'), 64);
    });

    test('the tamper threshold is the documented 10 bits', () {
      expect(SecurityService.maxPerceptualHammingDistance, 10);
    });
  });

  group('hash serialisation', () {
    final SecurityService svc = SecurityService();

    test('a top-bit digest is unsigned and 16 chars', () {
      // 0x8000000000000000 vs 0x0 differ by exactly one bit. The pre-fix code
      // serialised the former as "-8000000000000000" and reported distance 0,
      // silently missing a tamper.
      expect(svc.hammingDistance('8000000000000000', '0000000000000000'), 1);
    });

    test('the legacy signed form still compares correctly', () {
      // Photos signed before the fix carry the negative spelling. It must
      // normalise to the same value rather than being treated as unparseable.
      expect(svc.hammingDistance('-8000000000000000', '8000000000000000'), 0);
      expect(svc.hammingDistance('-8000000000000000', '0000000000000000'), 1);
    });

    test('all-bits-different scores 64', () {
      expect(svc.hammingDistance('ffffffffffffffff', '0000000000000000'), 64);
    });
  });
}
