import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image/image.dart' as img;
import 'package:geoguard/services/security_service.dart';

/// In-memory stand-in for the Keystore/Keychain so the signing pipeline can be
/// exercised on the test host.
class _FakeSecureStore {
  final Map<String, String> values = <String, String>{};

  void install() {
    const MethodChannel channel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      final Map<Object?, Object?> args =
          (call.arguments as Map<Object?, Object?>?) ?? <Object?, Object?>{};
      final String? key = args['key'] as String?;
      switch (call.method) {
        case 'read':
          return values[key];
        case 'write':
          values[key!] = args['value'] as String;
          return null;
        case 'delete':
          values.remove(key);
          return null;
        case 'containsKey':
          return values.containsKey(key);
        case 'readAll':
          return values;
        case 'deleteAll':
          values.clear();
          return null;
      }
      return null;
    });
  }
}

Position _position() => Position(
      latitude: 15.849700,
      longitude: 74.497700,
      timestamp: DateTime.utc(2026, 3, 1, 12),
      accuracy: 4.2,
      altitude: 751.3,
      altitudeAccuracy: 2.0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

/// A small image whose lower banner zone has real luminance structure, so the
/// dHash is not a degenerate all-zero value.
Uint8List _syntheticJpeg() {
  final img.Image image = img.Image(width: 160, height: 120);
  for (int y = 0; y < image.height; y++) {
    for (int x = 0; x < image.width; x++) {
      final int v = ((x * 7 + y * 13) % 256);
      image.setPixelRgb(x, y, v, (v * 2) % 256, (v * 3) % 256);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 95));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeSecureStore store;
  late SecurityService security;

  setUp(() {
    store = _FakeSecureStore()..install();
    security = SecurityService();
  });

  test('signs, embeds and recovers an envelope end to end', () async {
    final SignedImage signed = await security.signAndEmbed(
      jpegBytes: _syntheticJpeg(),
      position: _position(),
      timestampUtc: DateTime.utc(2026, 3, 1, 12),
      deviceId: 'a' * 64,
    );

    expect(signed.signingKey, isNotNull);
    expect(signed.envelope.kid, signed.signingKey!.kid);
    expect(signed.envelope.version, SecurityService.envelopeVersion);
    expect(signed.envelope.signature.length, 64); // hex SHA-256

    final SignedEnvelope? recovered =
        security.extractEnvelope(signed.pngBytes);

    expect(recovered, isNotNull);
    expect(recovered!.lat, closeTo(15.8497, 1e-9));
    expect(recovered.deviceId, 'a' * 64);
    expect(recovered.kid, signed.envelope.kid);
    expect(recovered.signature, signed.envelope.signature);

    expect(await security.verifySignature(recovered), isTrue);
  });

  test('embeds a standards-compliant JPEG COM segment', () async {
    final SignedImage signed = await security.signAndEmbed(
      jpegBytes: _syntheticJpeg(),
      position: _position(),
      timestampUtc: DateTime.utc(2026, 3, 1, 12),
      deviceId: 'device',
    );
    final Uint8List bytes = signed.pngBytes;

    // SOI immediately followed by the COM marker we inject.
    expect(bytes[0], 0xFF);
    expect(bytes[1], 0xD8);
    expect(bytes[2], 0xFF);
    expect(bytes[3], 0xFE);

    final int segLength = (bytes[4] << 8) | bytes[5];
    final String comment =
        utf8.decode(bytes.sublist(6, 6 + segLength - 2), allowMalformed: true);
    expect(comment.startsWith('VPIC_METADATA:'), isTrue);

    // The image must still decode with the extra segment in place.
    expect(img.decodeImage(bytes), isNotNull);
  });

  test('recovers the envelope from the COM copy when the EOF tail is stripped',
      () async {
    final SignedImage signed = await security.signAndEmbed(
      jpegBytes: _syntheticJpeg(),
      position: _position(),
      timestampUtc: DateTime.utc(2026, 3, 1, 12),
      deviceId: 'device',
    );

    final Uint8List full = signed.pngBytes;
    final int tail =
        latin1.decode(full, allowInvalid: true).lastIndexOf('VPIC_PAYLOAD:');
    expect(tail, greaterThan(0));

    final Uint8List stripped = Uint8List.sublistView(full, 0, tail);
    final SignedEnvelope? recovered = security.extractEnvelope(stripped);

    expect(recovered, isNotNull);
    expect(recovered!.signature, signed.envelope.signature);
    expect(await security.verifySignature(recovered), isTrue);
  });

  test('rejects an envelope whose payload was edited', () async {
    final SignedImage signed = await security.signAndEmbed(
      jpegBytes: _syntheticJpeg(),
      position: _position(),
      timestampUtc: DateTime.utc(2026, 3, 1, 12),
      deviceId: 'device',
    );

    // Attacker nudges the latitude but keeps the original signature.
    final SignedEnvelope tampered = SignedEnvelope(
      lat: 28.6139, // moved to Delhi
      lon: signed.envelope.lon,
      alt: signed.envelope.alt,
      timestampMs: signed.envelope.timestampMs,
      deviceId: signed.envelope.deviceId,
      pixelHash: signed.envelope.pixelHash,
      signature: signed.envelope.signature,
      kid: signed.envelope.kid,
    );

    expect(await security.verifySignature(tampered), isFalse);
  });

  test('stripping the key id does not downgrade to a forgeable canonical form',
      () async {
    final SignedImage signed = await security.signAndEmbed(
      jpegBytes: _syntheticJpeg(),
      position: _position(),
      timestampUtc: DateTime.utc(2026, 3, 1, 12),
      deviceId: 'device',
    );

    final SignedEnvelope downgraded = SignedEnvelope(
      lat: signed.envelope.lat,
      lon: signed.envelope.lon,
      alt: signed.envelope.alt,
      timestampMs: signed.envelope.timestampMs,
      deviceId: signed.envelope.deviceId,
      pixelHash: signed.envelope.pixelHash,
      signature: signed.envelope.signature,
      kid: null, // stripped
      version: 3,
    );

    expect(await security.verifySignature(downgraded), isFalse);
  });

  test('a legacy v3 random-secret signature still verifies', () async {
    // Simulate an install that signed photos before the HKDF migration.
    const String legacySecret = 'bGVnYWN5LXNlY3JldC1ieXRlcy0zMi1ieXRlcw==';
    store.values['veripic_hw_signing_key_v3'] = legacySecret;

    final SecurityService svc = SecurityService();

    // Reproduce exactly what the v3 build wrote: `v1|…` canonical form, HMAC
    // keyed by the UTF-8 bytes of the stored secret, and no key id.
    const String canonical =
        'v1|15.8497|74.4977|751.3|1770000000000|olddevice|0123456789abcdef';
    final SignedEnvelope legacyEnvelope = SignedEnvelope(
      lat: 15.8497,
      lon: 74.4977,
      alt: 751.3,
      timestampMs: 1770000000000,
      deviceId: 'olddevice',
      pixelHash: '0123456789abcdef',
      signature: _hmacHex(utf8.encode(legacySecret), canonical),
      version: 3,
    );

    final SignatureCheck check =
        await svc.verifySignatureDetailed(legacyEnvelope);

    expect(check.valid, isTrue);
    expect(check.origin, SigningKeyOrigin.legacyRandom);
  });

  group('scene protection', () {
    test('tiles the scene and binds them into the signature', () {
      final SecurityService svc = SecurityService();
      final img.Image frame = img.Image(width: 320, height: 240);
      // Give the frame structure so tiles are not all identical.
      for (int y = 0; y < frame.height; y++) {
        for (int x = 0; x < frame.width; x++) {
          frame.setPixelRgb(x, y, (x * 7) % 256, (y * 5) % 256, (x + y) % 256);
        }
      }

      final List<String> tiles = svc.computeSceneTiles(frame);
      expect(tiles.length, SecurityService.sceneGrid * SecurityService.sceneGrid,
          reason: 'one dHash per tile, row-major');
      for (final String t in tiles) {
        expect(t.length, 16, reason: 'each tile is a 64-bit unsigned hex digest');
      }

      // Recomputing over the same pixels is stable.
      expect(svc.computeSceneTiles(frame), tiles);
    });

    test('an edit confined to one tile moves only that tile', () {
      final SecurityService svc = SecurityService();
      final img.Image frame = img.Image(width: 320, height: 240);
      for (int y = 0; y < frame.height; y++) {
        for (int x = 0; x < frame.width; x++) {
          frame.setPixelRgb(x, y, (x * 7) % 256, (y * 5) % 256, (x + y) % 256);
        }
      }
      final List<String> before = svc.computeSceneTiles(frame);

      // Paint out a block inside the first tile only.
      img.fillRect(frame,
          x1: 2, y1: 2, x2: 60, y2: 40, color: img.ColorRgb8(255, 255, 255));

      final List<String> after = svc.computeSceneTiles(frame);
      final List<int> deltas = svc.compareSceneTiles(before, after);

      expect(deltas.length, before.length);
      expect(deltas.first, greaterThan(0),
          reason: 'the edited tile must register a change');

      final int altered = deltas
          .where((int d) => d > SecurityService.maxSceneTileHammingDistance)
          .length;
      expect(altered, lessThan(deltas.length),
          reason: 'a local edit must not invalidate every tile');
    });

    test('mismatched tile sets are not comparable', () {
      final SecurityService svc = SecurityService();
      expect(svc.compareSceneTiles(const <String>[], const <String>['a']),
          isEmpty);
      expect(
          svc.compareSceneTiles(const <String>['a'], const <String>['a', 'b']),
          isEmpty);
    });

    test('stripping the scene tiles invalidates the signature', () async {
      final SignedImage signed = await security.signAndEmbed(
        jpegBytes: _syntheticJpeg(),
        position: _position(),
        timestampUtc: DateTime.utc(2026, 3, 1, 12),
        deviceId: 'device',
      );

      // Only meaningful if the frame was large enough to tile at all.
      if (signed.envelope.sceneTiles.isEmpty) return;

      final SignedEnvelope stripped = SignedEnvelope(
        lat: signed.envelope.lat,
        lon: signed.envelope.lon,
        alt: signed.envelope.alt,
        timestampMs: signed.envelope.timestampMs,
        deviceId: signed.envelope.deviceId,
        pixelHash: signed.envelope.pixelHash,
        signature: signed.envelope.signature,
        kid: signed.envelope.kid,
        version: signed.envelope.version,
      );

      expect(stripped.sceneTiles, isEmpty);
      expect(await security.verifySignature(stripped), isFalse,
          reason: 'dropping the tiles must not escape the scene check');
      expect(await security.verifySignature(signed.envelope), isTrue);
    });
  });
}

String _hmacHex(List<int> key, String data) =>
    Hmac(sha256, key).convert(utf8.encode(data)).toString();
