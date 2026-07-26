import 'dart:io';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:gal/gal.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

import 'device_service.dart';
import 'overlay_service.dart';
import 'security_service.dart';

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
        '${tempDir.path}/veripic_${timestamp.millisecondsSinceEpoch}.png';
    final File finalFile = await File(tempPath).writeAsBytes(finalBytes);

    await Gal.putImage(finalFile.path, album: 'VeriPic');

    return CaptureResult(
      bytes: finalBytes,
      position: position,
      timestampUtc: timestamp,
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