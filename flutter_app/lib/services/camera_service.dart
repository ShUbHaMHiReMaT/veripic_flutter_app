import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

/// Bundle emitted by [CameraService.capture].
class CaptureResult {
  CaptureResult({
    required this.bytes,
    required this.position,
    required this.timestampUtc,
  });

  final Uint8List bytes;
  final Position position;
  final DateTime timestampUtc;
}

/// Thin wrapper around [CameraController] + [Geolocator].
///
/// The service exposes only the operations the UI needs so screens don't
/// have to reason about lifecycle bugs (double-init, dispose ordering, etc).
class CameraService {
  CameraController? _controller;
  CameraController? get controller => _controller;

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
    // Take the shot and read GPS in parallel — GPS reads can be 200-800ms.
    final Future<XFile> photoFuture = c.takePicture();
    final Future<Position> posFuture = _readPosition();

    final XFile photo = await photoFuture;
    final Position position = await posFuture;
    final Uint8List bytes = await photo.readAsBytes();

    return CaptureResult(
      bytes: bytes,
      position: position,
      timestampUtc: DateTime.now().toUtc(),
    );
  }

  Future<Position> _readPosition() async {
    final bool enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      throw StateError('Location services are disabled');
    }
    return Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.best,
        distanceFilter: 0,
      ),
    );
  }

  Future<void> _ensurePermissions() async {
    final Map<Permission, PermissionStatus> statuses =
        await <Permission>[Permission.camera, Permission.locationWhenInUse].request();
    if (statuses[Permission.camera] != PermissionStatus.granted) {
      throw StateError('Camera permission denied');
    }
    if (statuses[Permission.locationWhenInUse] != PermissionStatus.granted) {
      throw StateError('Location permission denied');
    }
  }
}
