import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image/image.dart' as img;
import 'package:veripic/services/security_service.dart';

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
}

String _hmacHex(List<int> key, String data) =>
    Hmac(sha256, key).convert(utf8.encode(data)).toString();
