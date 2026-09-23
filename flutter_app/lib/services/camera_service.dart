import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' show Offset;

import 'package:camera/camera.dart';
import 'package:gal/gal.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import 'device_service.dart';
import 'frame_store.dart';
import 'identity_service.dart';
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
    this.galleryError,
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

  /// Why the camera-roll export failed, when it did. The signed frame is saved
  /// either way — the gallery copy is a convenience, not the system of record.
  final String? galleryError;
}

class CameraService {
  CameraController? _controller;
  CameraController? get controller => _controller;

  final DeviceService _deviceService = DeviceService();
  final IdentityService _identityService = IdentityService();

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

  /// Takes, stamps, signs and stores one frame.
  ///
  /// [livePosition] and [addressText] come from the viewfinder, which already
  /// holds a validated fix and a resolved place name. Passing them in is what
  /// keeps the shutter quick: the old path requested a *fresh* best-accuracy
  /// fix and reverse-geocoded over the network after the shutter was pressed,
  /// which is seconds of waiting for data the screen was already showing.
  Future<CaptureResult> capture({
    Position? livePosition,
    String? addressText,
  }) async {
    final CameraController? c = _controller;
    if (c == null || !c.value.isInitialized) {
      throw StateError('Camera not initialized');
    }

    final DateTime timestamp = DateTime.now().toUtc();
    final Future<XFile> photoFuture = c.takePicture();

    // Reuse the viewfinder's fix when it is fresh; only fall back to asking
    // the OS for a new one, which is the slow path.
    final Future<Position> posFuture = livePosition != null
        ? Future<Position>.value(_checkNotMocked(livePosition))
        : _readPosition();

    final Future<String> deviceIdFuture = _deviceService.getDeviceId();
    final Future<PortableIdentity> identityFuture = _identityService.identity();

    final XFile rawPhoto = await photoFuture;
    final Position position = await posFuture;
    final String deviceId = await deviceIdFuture;
    final PortableIdentity identity = await identityFuture;
    final Uint8List rawBytes = await rawPhoto.readAsBytes();

    final CaptureJob job = CaptureJob(
      rawJpeg: rawBytes,
      latitude: position.latitude,
      longitude: position.longitude,
      altitude: position.altitude,
      timestampUtc: timestamp,
      deviceId: deviceId,
      addressText: addressText ?? OverlayService.fallbackAddress,
      privateKeyBytes: identity.privateKeyBytes,
      publicKeyB64: identity.publicKeyB64,
    );

    final SignedImage signedImage = await _composeOffThread(job);

    final Uint8List finalBytes = signedImage.pngBytes;

    // Store in the app's documents directory, not temp: the OS reclaims temp
    // space under pressure, which silently deleted captures.
    final Directory dir = await FrameStore.framesDirectory();
    final String path =
        '${dir.path}/geoguard_${timestamp.millisecondsSinceEpoch}.jpg';
    final File finalFile = await File(path).writeAsBytes(finalBytes);

    // Exporting to the camera roll is a convenience, not the system of record.
    // A refused or unavailable gallery must not lose a signed capture.
    String? galleryError;
    try {
      await Gal.putImage(finalFile.path, album: 'GeoGuard');
    } catch (e) {
      galleryError = e.toString();
    }

    // Tell the Frames and Locations tabs to reload.
    FrameStore.notifyChanged();

    return CaptureResult(
      bytes: finalBytes,
      position: position,
      timestampUtc: timestamp,
      envelope: signedImage.envelope,
      savedPath: finalFile.path,
      signingKeyId: signedImage.envelope.kid,
      galleryError: galleryError,
    );
  }

  /// Stamps, hashes, signs and encodes off the UI isolate.
  ///
  /// Deliberately `static`. An `Isolate.run` closure captures its enclosing
  /// scope, and inside an instance method that scope includes `this` — which
  /// holds a live `CameraController`. A controller cannot cross an isolate
  /// boundary, so the send fails with "Illegal argument in isolate message"
  /// and the capture is lost before anything reaches disk. A static context
  /// has no `this` to capture, so only [job] can travel.
  ///
  /// If the isolate cannot be spawned at all (low memory, a platform that
  /// refuses), the work runs inline instead. Slower and it blocks the UI, but
  /// a frozen second beats losing the photo.
  static Future<SignedImage> _composeOffThread(CaptureJob job) async {
    try {
      return await Isolate.run(() => composeSignedFrame(job));
    } catch (_) {
      return composeSignedFrame(job);
    }
  }

  Position _checkNotMocked(Position p) {
    if (p.isMocked) throw const MockLocationException();
    return p;
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