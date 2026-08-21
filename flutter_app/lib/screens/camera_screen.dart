import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';

import '../main.dart' show cameras;
import '../services/camera_service.dart';
import '../services/security_service.dart';
import '../theme/veripic_theme.dart';

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  final CameraService _camera = CameraService();

  Position? _livePosition;
  StreamSubscription<Position>? _positionSub;
  Timer? _clockTimer;
  DateTime _nowUtc = DateTime.now().toUtc();

  bool _initializing = true;
  bool _capturing = false;
  String? _error;
  PermissionRequiredException? _permissionError;

  int _cameraIndex = 0;
  bool _torchOn = false;

  /// Most recent capture — backs the gallery thumbnail in the control bar.
  Uint8List? _lastThumb;
  SignedEnvelope? _lastEnvelope;

  // Tap-to-focus reticle.
  Offset? _focusPoint;
  late final AnimationController _reticle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 700),
  );
  Timer? _reticleTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  Future<void> _boot() async {
    setState(() {
      _initializing = true;
      _error = null;
      _permissionError = null;
    });
    try {
      if (cameras.isEmpty) {
        throw StateError('No camera available on this device');
      }
      _cameraIndex = _cameraIndex.clamp(0, cameras.length - 1);
      await _camera.initialize(cameras[_cameraIndex]);

      _clockTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _nowUtc = DateTime.now().toUtc());
      });
      _positionSub ??= Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 1,
        ),
      ).listen(
        (Position p) {
          if (mounted) setState(() => _livePosition = p);
        },
        onError: (Object _) {},
      );

      if (mounted) setState(() => _initializing = false);
    } on PermissionRequiredException catch (e) {
      if (mounted) {
        setState(() {
          _initializing = false;
          _permissionError = e;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _initializing = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? c = _camera.controller;
    if (c == null || !c.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _camera.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _boot();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _positionSub?.cancel();
    _clockTimer?.cancel();
    _reticleTimer?.cancel();
    _reticle.dispose();
    _camera.dispose();
    super.dispose();
  }

  // ---- Interactions --------------------------------------------------

  Future<void> _handleFocusTap(Offset local, Size area) async {
    if (area.width == 0 || area.height == 0) return;
    HapticFeedback.selectionClick();
    setState(() => _focusPoint = local);
    _reticle.forward(from: 0);
    _reticleTimer?.cancel();
    _reticleTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _focusPoint = null);
    });
    await _camera.focusAt(Offset(
      (local.dx / area.width).clamp(0.0, 1.0),
      (local.dy / area.height).clamp(0.0, 1.0),
    ));
  }

  Future<void> _toggleTorch() async {
    HapticFeedback.selectionClick();
    final bool next = !_torchOn;
    await _camera.setFlashMode(next ? FlashMode.torch : FlashMode.off);
    if (mounted) setState(() => _torchOn = next);
  }

  Future<void> _flipCamera() async {
    if (cameras.length < 2 || _capturing) return;
    HapticFeedback.selectionClick();
    setState(() {
      _initializing = true;
      _torchOn = false;
      _cameraIndex = (_cameraIndex + 1) % cameras.length;
    });
    await _camera.dispose();
    await _boot();
  }

  Future<void> _capture() async {
    if (_capturing) return;
    HapticFeedback.mediumImpact();
    setState(() => _capturing = true);

    try {
      // CameraService already stamps, signs, embeds and exports to the
      // gallery — the bytes it returns are final and must not be re-signed.
      final CaptureResult shot = await _camera.capture();

      if (!mounted) return;
      setState(() {
        _lastThumb = shot.bytes;
        _lastEnvelope = shot.envelope;
      });
      HapticFeedback.heavyImpact();

      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(
          duration: Duration(seconds: 2),
          content: Text('Signed and saved to the VeriPic album'),
        ));
    } catch (e) {
      HapticFeedback.vibrate();
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            backgroundColor: VP.danger,
            content: Text('Capture failed: $e'),
          ));
      }
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  void _openLastShot() {
    final Uint8List? bytes = _lastThumb;
    if (bytes == null) return;
    HapticFeedback.selectionClick();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _LastShotPage(bytes: bytes, envelope: _lastEnvelope),
      ),
    );
  }

  // ---- Build ---------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final Widget body;
    if (_initializing) {
      body = const _Booting();
    } else if (_permissionError != null) {
      body = _PermissionGate(error: _permissionError!, onRetry: _boot);
    } else if (_error != null) {
      body = _FatalError(message: _error!, onRetry: _boot);
    } else {
      body = _buildViewfinder();
    }

    return Scaffold(
      backgroundColor: VP.bg,
      body: SafeArea(
        top: false,
        child: Column(
          children: <Widget>[
            Expanded(child: body),
            _ControlBar(
              thumb: _lastThumb,
              capturing: _capturing,
              canFlip: cameras.length > 1,
              onGallery: _openLastShot,
              onShutter:
                  _initializing || _error != null || _permissionError != null
                      ? null
                      : _capture,
              onFlip: _flipCamera,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildViewfinder() {
    final CameraController? controller = _camera.controller;
    if (controller == null || !controller.value.isInitialized) {
      return const _Booting();
    }

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ColoredBox(
          color: Colors.black,
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final Size area =
                  Size(constraints.maxWidth, constraints.maxHeight);
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (TapDownDetails d) =>
                    _handleFocusTap(d.localPosition, area),
                child: ClipRect(
                  child: OverflowBox(
                    maxWidth: double.infinity,
                    maxHeight: double.infinity,
                    child: FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox(
                        width: area.width,
                        height: area.width * controller.value.aspectRatio,
                        child: CameraPreview(controller),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),

        // Focus reticle.
        if (_focusPoint != null)
          AnimatedBuilder(
            animation: _reticle,
            builder: (BuildContext context, Widget? child) {
              final double t = Curves.easeOut.transform(
                  _reticle.value.clamp(0.0, 1.0));
              return Positioned(
                left: _focusPoint!.dx - 38,
                top: _focusPoint!.dy - 38,
                child: Opacity(
                  opacity: 1.0 - (t * 0.35),
                  child: Transform.scale(scale: 1.25 - (t * 0.25), child: child),
                ),
              );
            },
            child: Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 1.5),
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          ),

        // Top chrome: back + torch.
        Positioned(
          top: MediaQuery.of(context).padding.top + 6,
          left: 10,
          right: 10,
          child: Row(
            children: <Widget>[
              _GlyphButton(
                icon: Icons.arrow_back_rounded,
                onTap: () => Navigator.of(context).maybePop(),
              ),
              const Spacer(),
              _GlyphButton(
                icon: _torchOn
                    ? Icons.flashlight_on_rounded
                    : Icons.flashlight_off_rounded,
                active: _torchOn,
                onTap: _toggleTorch,
              ),
            ],
          ),
        ),

        // Live capture data.
        Positioned(
          left: 12,
          right: 12,
          bottom: 12,
          child: _LiveReadout(position: _livePosition, nowUtc: _nowUtc),
        ),
      ],
    );
  }
}

// =======================================================================
// Control bar
// =======================================================================

class _ControlBar extends StatelessWidget {
  const _ControlBar({
    required this.thumb,
    required this.capturing,
    required this.canFlip,
    required this.onGallery,
    required this.onShutter,
    required this.onFlip,
  });

  final Uint8List? thumb;
  final bool capturing;
  final bool canFlip;
  final VoidCallback onGallery;
  final VoidCallback? onShutter;
  final VoidCallback onFlip;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 132,
      width: double.infinity,
      color: VP.surface,
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          _GalleryButton(thumb: thumb, onTap: onGallery),
          _ShutterButton(busy: capturing, onTap: onShutter),
          Opacity(
            opacity: canFlip ? 1 : 0.3,
            child: _SquareButton(
              icon: Icons.flip_camera_ios_outlined,
              onTap: canFlip ? onFlip : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// Bottom-left thumbnail of the last shot, like a stock camera app.
class _GalleryButton extends StatelessWidget {
  const _GalleryButton({required this.thumb, required this.onTap});

  final Uint8List? thumb;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Uint8List? bytes = thumb;

    return GestureDetector(
      onTap: bytes == null ? null : onTap,
      child: Container(
        width: 54,
        height: 54,
        decoration: BoxDecoration(
          color: VP.neutralSoft,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: VP.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: bytes == null
            ? const Icon(Icons.photo_library_outlined,
                size: 20, color: VP.inkFaint)
            : Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
      ),
    );
  }
}

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({required this.busy, required this.onTap});

  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: busy ? null : onTap,
      child: SizedBox(
        width: 78,
        height: 78,
        child: Stack(
          alignment: Alignment.center,
          children: <Widget>[
            Container(
              width: 78,
              height: 78,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: VP.border, width: 3),
              ),
            ),
            AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: busy ? 44 : 62,
              height: busy ? 44 : 62,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: onTap == null ? VP.inkFaint : VP.primary,
              ),
            ),
            if (busy)
              const SizedBox(
                width: 66,
                height: 66,
                child: CircularProgressIndicator(
                    strokeWidth: 2.5, color: VP.primary),
              ),
          ],
        ),
      ),
    );
  }
}

class _SquareButton extends StatelessWidget {
  const _SquareButton({required this.icon, this.onTap});

  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 54,
        height: 54,
        decoration: BoxDecoration(
          color: VP.neutralSoft,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: VP.border),
        ),
        child: Icon(icon, size: 22, color: VP.ink),
      ),
    );
  }
}

/// Round translucent button used over the live preview.
class _GlyphButton extends StatelessWidget {
  const _GlyphButton({
    required this.icon,
    required this.onTap,
    this.active = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: active ? Colors.white : Colors.black.withValues(alpha: 0.35),
        ),
        child: Icon(icon, size: 19, color: active ? VP.ink : Colors.white),
      ),
    );
  }
}

// =======================================================================
// Live readout
// =======================================================================

class _LiveReadout extends StatelessWidget {
  const _LiveReadout({required this.position, required this.nowUtc});

  final Position? position;
  final DateTime nowUtc;

  @override
  Widget build(BuildContext context) {
    final Position? p = position;
    final bool locked = p != null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.42),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            locked ? Icons.gps_fixed_rounded : Icons.gps_not_fixed_rounded,
            size: 15,
            color: locked ? const Color(0xFF4ADE80) : Colors.white70,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              locked
                  ? '${p.latitude.toStringAsFixed(5)}, '
                      '${p.longitude.toStringAsFixed(5)}   '
                      '${p.altitude.toStringAsFixed(0)} m'
                  : 'Acquiring GPS…',
              style: const TextStyle(
                fontFamily: VP.mono,
                fontSize: 11.5,
                color: Colors.white,
              ),
            ),
          ),
          Text(
            '${DateFormat('HH:mm:ss').format(nowUtc)} UTC',
            style: const TextStyle(
              fontFamily: VP.mono,
              fontSize: 11.5,
              color: Colors.white70,
            ),
          ),
        ],
      ),
    );
  }
}

// =======================================================================
// Last shot preview
// =======================================================================

class _LastShotPage extends StatelessWidget {
  const _LastShotPage({required this.bytes, required this.envelope});

  final Uint8List bytes;
  final SignedEnvelope? envelope;

  @override
  Widget build(BuildContext context) {
    final SignedEnvelope? e = envelope;

    return Scaffold(
      appBar: AppBar(title: const Text('Last capture')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        children: <Widget>[
          ClipRRect(
            borderRadius: VP.br,
            child: ColoredBox(
              color: Colors.black,
              child: InteractiveViewer(
                maxScale: 5,
                child: Image.memory(bytes, fit: BoxFit.contain),
              ),
            ),
          ),
          const SizedBox(height: 20),
          if (e != null)
            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Row(
                    children: <Widget>[
                      Expanded(child: Text('Signed payload', style: VP.h2)),
                      Pill(
                        label: 'Sealed',
                        color: VP.success,
                        icon: Icons.lock_outline_rounded,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  KvRow(
                    label: 'Coordinates',
                    value: '${e.lat.toStringAsFixed(6)}, '
                        '${e.lon.toStringAsFixed(6)}',
                  ),
                  KvRow(
                      label: 'Altitude',
                      value: '${e.alt.toStringAsFixed(1)} m'),
                  KvRow(
                    label: 'Captured',
                    value: '${DateFormat('yyyy-MM-dd HH:mm:ss').format(
                      DateTime.fromMillisecondsSinceEpoch(e.timestampMs,
                          isUtc: true),
                    )} UTC',
                  ),
                  KvRow(label: 'Device', value: e.deviceId),
                  KvRow(label: 'Signing key', value: e.kid ?? '—'),
                  KvRow(label: 'Banner hash', value: e.pixelHash),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// =======================================================================
// States
// =======================================================================

class _Booting extends StatelessWidget {
  const _Booting();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Colors.black,
      child: Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
        ),
      ),
    );
  }
}

class _PermissionGate extends StatelessWidget {
  const _PermissionGate({required this.error, required this.onRetry});

  final PermissionRequiredException error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: AppCard(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Icon(Icons.lock_outline_rounded,
                  size: 28, color: VP.primary),
              const SizedBox(height: 14),
              Text('${error.permissionName} access needed', style: VP.h2),
              const SizedBox(height: 8),
              Text(
                error.permanentlyDenied
                    ? 'This permission was permanently denied. Enable it in system '
                        'settings, then come back.'
                    : 'VeriPic needs this permission to stamp and sign photos.',
                style: VP.body,
              ),
              const SizedBox(height: 18),
              Row(
                children: <Widget>[
                  if (error.permanentlyDenied)
                    const FilledButton(
                      onPressed: openAppSettings,
                      child: Text('Open settings'),
                    )
                  else
                    FilledButton(
                      onPressed: onRetry,
                      child: const Text('Grant access'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FatalError extends StatelessWidget {
  const _FatalError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: AppCard(
          padding: const EdgeInsets.all(22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Icon(Icons.error_outline_rounded,
                  size: 28, color: VP.danger),
              const SizedBox(height: 14),
              const Text('Camera unavailable', style: VP.h2),
              const SizedBox(height: 8),
              Text(message, style: VP.body),
              const SizedBox(height: 18),
              FilledButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ),
        ),
      ),
    );
  }
}
