import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image/image.dart' as img;
import 'package:geoguard/services/security_service.dart';
import 'package:geoguard/services/verification_service.dart';

void _installFakeSecureStore() {
  final Map<String, String> values = <String, String>{};
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (MethodCall call) async {
    final Map<Object?, Object?> args =
        (call.arguments as Map<Object?, Object?>?) ?? <Object?, Object?>{};
    final String? key = args['key'] as String?;
    switch (call.method) {
      case 'read':
        return values[key];
      case 'write':
        values[key!] = args['value'] as String;
        return null;
      case 'containsKey':
        return values.containsKey(key);
      case 'readAll':
        return values;
    }
    return null;
  });
}

Position _position() => Position(
      latitude: 15.8497,
      longitude: 74.4977,
      timestamp: DateTime.utc(2026, 3, 1, 12),
      accuracy: 4.2,
      altitude: 751.3,
      altitudeAccuracy: 2.0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );

/// Brightness falls left to right everywhere, so the stamp's dHash is the same
/// at any size — only the scene check can tell a resized copy apart.
Uint8List _gradientJpeg() {
  final img.Image image = img.Image(width: 320, height: 240);
  for (int y = 0; y < image.height; y++) {
    for (int x = 0; x < image.width; x++) {
      final int v = 255 - (x * 255 ~/ image.width);
      image.setPixelRgb(x, y, v, (v + y) % 256, v);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 95));
}

/// Shrinks the picture and re-attaches the original envelope tail.
Uint8List _shrinkKeepingEnvelope(Uint8List signed, int width) {
  final img.Image small =
      img.copyResize(img.decodeJpg(signed)!, width: width);
  final Uint8List encoded = Uint8List.fromList(img.encodeJpg(small));
  final String text = String.fromCharCodes(signed);
  final int tail = text.lastIndexOf('VPIC_PAYLOAD:');
  return Uint8List.fromList(<int>[...encoded, ...signed.sublist(tail)]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(_installFakeSecureStore);

  test('an untouched photo is real', () async {
    final SignedImage signed = await SecurityService().signAndEmbed(
      jpegBytes: _gradientJpeg(),
      position: _position(),
      timestampUtc: DateTime.utc(2026, 3, 1, 12),
      deviceId: 'a' * 64,
    );
    final VerificationReport report =
        await VerificationService().verify(signed.pngBytes);
    expect(report.verdict, VerificationVerdict.authentic);
  });

  test('a photo shrunk until its scene cannot be compared is not real',
      () async {
    final SignedImage signed = await SecurityService().signAndEmbed(
      jpegBytes: _gradientJpeg(),
      position: _position(),
      timestampUtc: DateTime.utc(2026, 3, 1, 12),
      deviceId: 'a' * 64,
    );
    expect(signed.envelope.protectsScene, isTrue);

    // Too small to cut into a 4x4 grid of 8-pixel tiles, so the scene could
    // not be checked at all. That used to pass as "Real photo".
    final VerificationReport report = await VerificationService()
        .verify(_shrinkKeepingEnvelope(signed.pngBytes, 30));

    expect(report.verdict, isNot(VerificationVerdict.authentic));
  });
}
