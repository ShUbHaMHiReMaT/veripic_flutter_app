import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:gal/gal.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'overlay_service.dart';

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

    // Capture photo and current GPS location simultaneously
    final Future<XFile> photoFuture = c.takePicture();
    final Future<Position> posFuture = _readPosition();

    final XFile rawPhoto = await photoFuture;
    final Position position = await posFuture;
    final Uint8List rawBytes = await rawPhoto.readAsBytes();

    // 1. Burn GPS & Address Stamp onto the photo canvas
    final Uint8List stampedBytes = await OverlayService.applyGpsStamp(
      imageBytes: rawBytes,
      position: position,
    );

    // 2. Save stamped photo to a temporary file
    final Directory tempDir = await getTemporaryDirectory();
    final String tempPath = '${tempDir.path}/veripic_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final File stampedFile = await File(tempPath).writeAsBytes(stampedBytes);

    // 3. Export to Public Device Gallery
    await Gal.putImage(stampedFile.path, album: 'VeriPic');

    return CaptureResult(
      bytes: stampedBytes,
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
      desiredAccuracy: LocationAccuracy.best,
    );
  }

  Future<void> _ensurePermissions() async {
    final Map<Permission, PermissionStatus> statuses = await <Permission>[
      Permission.camera,
      Permission.locationWhenInUse,
      Permission.location,
    ].request();

    if (statuses[Permission.camera] != PermissionStatus.granted) {
      throw StateError('Camera permission denied');
    }
    if (statuses[Permission.locationWhenInUse] != PermissionStatus.granted &&
        statuses[Permission.location] != PermissionStatus.granted) {
      throw StateError('Location permission denied');
    }
  }
}