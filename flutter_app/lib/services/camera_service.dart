import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:camera/camera.dart';
import 'package:gal/gal.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'device_service.dart';
import 'overlay_service.dart';
import 'security_service.dart';

/// Thrown when a required permission is missing, carrying enough context
/// for the UI to show a helpful prompt instead of a raw error string.
class PermissionRequiredException implements Exception {
  PermissionRequiredException(this.permissionName, {required this.permanentlyDenied});
  final String permissionName;
  final bool permanentlyDenied;

  @override
  String toString() => '$permissionName permission is required';
}

/// Thrown when the OS reports the fix came from a mock location provider.
///
/// Signing a spoofed coordinate would let GeoGuard vouch for a lie, so capture
/// is refused outright rather than recording the fix with a caveat.
class MockLocationException implements Exception {
  const MockLocationException();

  @override
  String toString() => 'Location is being faked by another app';
}

class CaptureResult {
  CaptureResult({
    required this.bytes,
    required this.position,
    required this.timestampUtc,
    required this.envelope,
    required this.savedPath,
    this.signingKeyId,
  });

  /// Final signed JPEG bytes — already stamped, signed and embedded.
  /// Callers must NOT re-sign these; doing so appends a second payload.
  final Uint8List bytes;
  final Position position;
  final DateTime timestampUtc;

  /// The envelope that was embedded, for immediate display in the UI.
  final SignedEnvelope envelope;

  /// Temp-file path of the exported image (also copied into the gallery).
  final String savedPath;

  /// Key id that produced the signature.
  final String? signingKeyId;
}

class CameraService {
  CameraController? _controller;
  CameraController? get controller => _controller;

  final SecurityService _securityService = SecurityService();
  final DeviceService _deviceService = DeviceService();

  Future<void> initialize(CameraDescription description) async {
    await _ensurePermissions();
    final CameraController controller = CameraController(
      description,
      ResolutionPreset.high,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );
    await controller.initialize();
    _controller = controller;
  }

  Future<void> dispose() async {
    await _controller?.dispose();
    _controller = null;
  }

  Future<CaptureResult> capture() async {
    final CameraController? c = _controller;
    if (c == null || !c.value.isInitialized) {
      throw StateError('Camera not initialized');
    }

    final DateTime timestamp = DateTime.now().toUtc();
    final Future<XFile> photoFuture = c.takePicture();
    final Future<Position> posFuture = _readPosition();
    final Future<String> deviceIdFuture = _deviceService.getDeviceId();

    final XFile rawPhoto = await photoFuture;
    final Position position = await posFuture;
    final String deviceId = await deviceIdFuture;
    final Uint8List rawBytes = await rawPhoto.readAsBytes();

    // 1. Burn GPS Stamp onto raw photo
    final Uint8List stampedBytes = await OverlayService.applyGpsStamp(
      imageBytes: rawBytes,
      position: position,
      timestamp: timestamp,
    );

    // 2. Sign and Embed Cryptographic Payload on final stamped image
    final SignedImage signedImage = await _securityService.signAndEmbed(
      jpegBytes: stampedBytes,
      position: position,
      timestampUtc: timestamp,
      deviceId: deviceId,
    );

    final Uint8List finalBytes = signedImage.pngBytes;

    // 3. Save to Temp File & Export to Gallery
    final Directory tempDir = await getTemporaryDirectory();
    final String tempPath =
        '${tempDir.path}/geoguard_${timestamp.millisecondsSinceEpoch}.png';
    final File finalFile = await File(tempPath).writeAsBytes(finalBytes);

    await Gal.putImage(finalFile.path, album: 'GeoGuard');

    return CaptureResult(
      bytes: finalBytes,
      position: position,
      timestampUtc: timestamp,
      envelope: signedImage.envelope,
      savedPath: finalFile.path,
      signingKeyId: signedImage.signingKey?.kid,
    );
  }

  /// Drives tap-to-focus. Silently ignored on devices without focus-point
  /// support so the UI reticle still feels responsive.
  Future<void> focusAt(Offset normalized) async {
    final CameraController? c = _controller;
    if (c == null || !c.value.isInitialized) return;
    try {
      await c.setFocusPoint(normalized);
      await c.setExposurePoint(normalized);
    } catch (_) {
      // Not supported on this sensor — harmless.
    }
  }

  Future<void> setFlashMode(FlashMode mode) async {
    final CameraController? c = _controller;
    if (c == null || !c.value.isInitialized) return;
    try {
      await c.setFlashMode(mode);
    } catch (_) {
      // Some devices reject torch while the preview is warming up.
    }
  }

  Future<Position> _readPosition() async {
    final bool enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      throw StateError('Location services are disabled');
    }
    final Position position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.best,
    );

    // Android reports when a fix came from a mock provider. Refuse to sign it.
    if (position.isMocked) throw const MockLocationException();

    return position;
  }

  Future<void> _ensurePermissions() async {
    final Map<Permission, PermissionStatus> statuses = await <Permission>[
      Permission.camera,
      Permission.locationWhenInUse,
      Permission.location,
    ].request();

    final PermissionStatus camera = statuses[Permission.camera]!;
    if (camera != PermissionStatus.granted) {
      throw PermissionRequiredException(
        'Camera',
        permanentlyDenied: camera == PermissionStatus.permanentlyDenied,
      );
    }

    final PermissionStatus whenInUse = statuses[Permission.locationWhenInUse]!;
    final PermissionStatus location = statuses[Permission.location]!;
    if (whenInUse != PermissionStatus.granted && location != PermissionStatus.granted) {
      throw PermissionRequiredException(
        'Location',
        permanentlyDenied: whenInUse == PermissionStatus.permanentlyDenied ||
            location == PermissionStatus.permanentlyDenied,
      );
    }
  }
}