import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import '../main.dart' show cameras;
import '../services/camera_service.dart';
import '../services/device_service.dart';
import '../services/security_service.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  final CameraService _camera = CameraService();
  final SecurityService _security = SecurityService();
  final DeviceService _device = DeviceService();

  Position? _livePosition;
  StreamSubscription<Position>? _positionSub;
  Timer? _clockTimer;
  DateTime _nowUtc = DateTime.now().toUtc();

  bool _initializing = true;
  bool _capturing = false;
  String? _error;
  String? _lastSavedPath;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    try {
      if (cameras.isEmpty) throw StateError('No camera available on this device');
      await _camera.initialize(cameras.first);
      _clockTimer = Timer.periodic(const Duration(seconds: 1),
          (_) => setState(() => _nowUtc = DateTime.now().toUtc()));
      _positionSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 1,
        ),
      ).listen((Position p) => setState(() => _livePosition = p));
      setState(() => _initializing = false);
    } catch (e) {
      setState(() {
        _initializing = false;
        _error = e.toString();
      });
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _clockTimer?.cancel();
    _camera.dispose();
    super.dispose();
  }

  Future<void> _capture() async {
    if (_capturing) return;
    setState(() => _capturing = true);
    try {
      final CaptureResult shot = await _camera.capture();
      final String deviceId = await _device.fingerprint();
      final SignedImage signed = await _security.signAndEmbed(
        jpegBytes: shot.bytes,
        position: shot.position,
        timestampUtc: shot.timestampUtc,
        deviceId: deviceId,
      );

      final Directory dir = await getApplicationDocumentsDirectory();
      final String path =
          '${dir.path}/veripic_${shot.timestampUtc.millisecondsSinceEpoch}.png';
      await File(path).writeAsBytes(signed.pngBytes, flush: true);

      setState(() => _lastSavedPath = path);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Signed photo saved: $path')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Capture failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Signed Capture')),
      body: _initializing
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(_error!, textAlign: TextAlign.center),
                  ),
                )
              : _buildCamera(),
    );
  }

  Widget _buildCamera() {
    final CameraController? controller = _camera.controller;
    if (controller == null || !controller.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        CameraPreview(controller),
        Positioned(
          top: 16, left: 16, right: 16,
          child: _HudCard(
            position: _livePosition,
            nowUtc: _nowUtc,
          ),
        ),
        Positioned(
          bottom: 32, left: 0, right: 0,
          child: Column(
            children: <Widget>[
              if (_lastSavedPath != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text('Last saved: ${_lastSavedPath!.split('/').last}',
                      style: const TextStyle(color: Colors.white)),
                ),
              GestureDetector(
                onTap: _capture,
                child: Container(
                  width: 82, height: 82,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 4),
                    color: _capturing
                        ? Colors.white24
                        : const Color(0xFF00E5A8).withOpacity(0.9),
                  ),
                  child: _capturing
                      ? const Padding(
                          padding: EdgeInsets.all(20),
                          child: CircularProgressIndicator(color: Colors.white))
                      : const Icon(Icons.fingerprint, color: Colors.black, size: 34),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _HudCard extends StatelessWidget {
  const _HudCard({required this.position, required this.nowUtc});
  final Position? position;
  final DateTime nowUtc;

  @override
  Widget build(BuildContext context) {
    final DateFormat fmt = DateFormat('yyyy-MM-dd HH:mm:ss');
    final String utc = '${fmt.format(nowUtc)} UTC';
    final String coords = position == null
        ? 'Acquiring GPS…'
        : '${position!.latitude.toStringAsFixed(6)}, ${position!.longitude.toStringAsFixed(6)}';
    final String acc = position == null
        ? ''
        : '± ${position!.accuracy.toStringAsFixed(1)} m · alt ${position!.altitude.toStringAsFixed(1)} m';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF00E5A8).withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(children: <Widget>[
            const Icon(Icons.schedule, size: 16, color: Color(0xFF00E5A8)),
            const SizedBox(width: 6),
            Text(utc, style: const TextStyle(color: Colors.white, fontFamily: 'monospace')),
          ]),
          const SizedBox(height: 4),
          Row(children: <Widget>[
            const Icon(Icons.place, size: 16, color: Color(0xFF00E5A8)),
            const SizedBox(width: 6),
            Expanded(
              child: Text(coords,
                  style: const TextStyle(color: Colors.white, fontFamily: 'monospace')),
            ),
          ]),
          if (acc.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 22),
              child: Text(acc, style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ),
        ],
      ),
    );
  }
}
