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

  // Last successful capture, shown as a receipt strip.
  Uint8List? _lastThumb;
  SignedEnvelope? _lastEnvelope;

  // Tap-to-focus reticle.
  Offset? _focusPoint;
  late final AnimationController _reticle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  Timer? _reticleTimer;

  late final AnimationController _scan = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

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
    _scan.dispose();
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
    _reticleTimer = Timer(const Duration(milliseconds: 1400), () {
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
    _scan.repeat();

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
        ..showSnackBar(SnackBar(
          content: Row(
            children: <Widget>[
              const Icon(Icons.verified_rounded, color: VP.accent, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Signed & saved to VeriPic album'
                  '${shot.signingKeyId != null ? ' · key ${shot.signingKeyId}' : ''}',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ],
          ),
        ));
    } catch (e) {
      HapticFeedback.vibrate();
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(
            backgroundColor: VP.danger.withValues(alpha: 0.9),
            content: Text('Capture failed: $e',
                style: const TextStyle(fontSize: 13, color: Colors.white)),
          ));
      }
    } finally {
      _scan.stop();
      if (mounted) setState(() => _capturing = false);
    }
  }

  // ---- Build ---------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      body: _initializing
          ? const _Booting()
          : _permissionError != null
              ? ForensicBackdrop(
                  child: _PermissionGate(
                    error: _permissionError!,
                    onRetry: _boot,
                  ),
                )
              : _error != null
                  ? ForensicBackdrop(
                      child: _FatalError(message: _error!, onRetry: _boot))
                  : _buildCamera(),
    );
  }

  Widget _buildCamera() {
    final CameraController? controller = _camera.controller;
    if (controller == null || !controller.value.isInitialized) {
      return const _Booting();
    }

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // --- Live preview, cover-fitted, tap to focus ---
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final Size area = Size(constraints.maxWidth, constraints.maxHeight);
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

        // --- Vignette so HUD chrome stays legible over bright scenes ---
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: <double>[0.0, 0.28, 0.66, 1.0],
                colors: <Color>[
                  Color(0xCC000000),
                  Color(0x33000000),
                  Color(0x44000000),
                  Color(0xE6000000),
                ],
              ),
            ),
          ),
        ),

        // --- Framing brackets ---
        const IgnorePointer(child: _FramingBrackets()),

        // --- Focus reticle ---
        if (_focusPoint != null)
          AnimatedBuilder(
            animation: _reticle,
            builder: (BuildContext context, _) {
              final double t = Curves.easeOutBack.transform(
                  _reticle.value.clamp(0.0, 1.0));
              return Positioned(
                left: _focusPoint!.dx - 42,
                top: _focusPoint!.dy - 42,
                child: IgnorePointer(
                  child: Opacity(
                    opacity: (1.0 - (_reticle.value - 0.7).clamp(0.0, 0.3) / 0.3)
                        .clamp(0.0, 1.0),
                    child: Transform.scale(
                      scale: 0.7 + 0.3 * t,
                      child: const _Reticle(),
                    ),
                  ),
                ),
              );
            },
          ),

        // --- Signing sweep while the crypto pipeline runs ---
        if (_capturing)
          IgnorePointer(
            child: AnimatedBuilder(
              animation: _scan,
              builder: (BuildContext context, _) =>
                  CustomPaint(painter: _ScanPainter(_scan.value)),
            ),
          ),

        // --- Top HUD ---
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
            child: Column(
              children: <Widget>[
                Row(
                  children: <Widget>[
                    _GlassIconButton(
                      icon: Icons.arrow_back_rounded,
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                    const Spacer(),
                    _GlassIconButton(
                      icon: _torchOn
                          ? Icons.flashlight_on_rounded
                          : Icons.flashlight_off_rounded,
                      active: _torchOn,
                      onTap: _toggleTorch,
                    ),
                    const SizedBox(width: 8),
                    if (cameras.length > 1)
                      _GlassIconButton(
                        icon: Icons.cameraswitch_rounded,
                        onTap: _flipCamera,
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                _TelemetryHud(position: _livePosition, nowUtc: _nowUtc),
              ],
            ),
          ),
        ),

        // --- Bottom control deck ---
        SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (_lastEnvelope != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: _CaptureReceipt(
                        thumb: _lastThumb,
                        envelope: _lastEnvelope!,
                      ),
                    ),
                  _ShutterBar(
                    capturing: _capturing,
                    gpsLocked: _livePosition != null,
                    onCapture: _capture,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// =======================================================================
// HUD pieces
// =======================================================================

class _TelemetryHud extends StatelessWidget {
  const _TelemetryHud({required this.position, required this.nowUtc});

  final Position? position;
  final DateTime nowUtc;

  @override
  Widget build(BuildContext context) {
    final Position? p = position;
    final bool locked = p != null;
    final Color lockColor = locked ? VP.accent : VP.warn;

    return GlassPanel(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      blur: 12,
      opacity: 0.42,
      tint: Colors.black,
      borderColor: lockColor.withValues(alpha: 0.28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              _PulseDot(color: lockColor, active: locked),
              const SizedBox(width: 8),
              Text(locked ? 'GPS LOCK' : 'ACQUIRING GPS',
                  style: VP.eyebrow.copyWith(color: lockColor)),
              const Spacer(),
              Text(
                '${DateFormat('HH:mm:ss').format(nowUtc)} UTC',
                style: VP.monoSmall.copyWith(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: VP.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              Expanded(
                child: _Metric(
                  label: 'LAT',
                  value: locked ? p.latitude.toStringAsFixed(6) : '——.——————',
                ),
              ),
              Expanded(
                child: _Metric(
                  label: 'LON',
                  value: locked ? p.longitude.toStringAsFixed(6) : '——.——————',
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(
                child: _Metric(
                  label: 'ALT',
                  value: locked ? '${p.altitude.toStringAsFixed(1)} m' : '—',
                ),
              ),
              Expanded(
                child: _Metric(
                  label: 'ACCURACY',
                  value: locked ? '± ${p.accuracy.toStringAsFixed(1)} m' : '—',
                  valueColor: locked && p.accuracy > 25 ? VP.warn : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            DateFormat('EEE, dd MMM yyyy').format(nowUtc),
            style: const TextStyle(fontSize: 11, color: VP.textFaint),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value, this.valueColor});
  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: VP.eyebrow.copyWith(fontSize: 9.5)),
        const SizedBox(height: 2),
        Text(value,
            style: VP.monoSmall.copyWith(
              fontSize: 13,
              color: valueColor ?? VP.textPrimary,
            )),
      ],
    );
  }
}

class _PulseDot extends StatefulWidget {
  const _PulseDot({required this.color, required this.active});
  final Color color;
  final bool active;

  @override
  State<_PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<_PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (BuildContext context, _) {
        final double v = widget.active ? _c.value : 1.0;
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color,
            boxShadow: <BoxShadow>[
              BoxShadow(
                color: widget.color.withValues(alpha: 0.25 + 0.45 * v),
                blurRadius: 5 + 6 * v,
                spreadRadius: 1 * v,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ShutterBar extends StatelessWidget {
  const _ShutterBar({
    required this.capturing,
    required this.gpsLocked,
    required this.onCapture,
  });

  final bool capturing;
  final bool gpsLocked;
  final VoidCallback onCapture;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AnimatedOpacity(
          opacity: capturing ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text('STAMPING · HASHING · SIGNING',
                style: VP.eyebrow.copyWith(color: VP.accent)),
          ),
        ),
        GestureDetector(
          onTap: capturing ? null : onCapture,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: capturing
                    ? VP.accent.withValues(alpha: 0.5)
                    : Colors.white.withValues(alpha: 0.85),
                width: 3.5,
              ),
              color: capturing
                  ? Colors.white.withValues(alpha: 0.08)
                  : VP.accent.withValues(alpha: gpsLocked ? 0.92 : 0.45),
              boxShadow: capturing || !gpsLocked
                  ? null
                  : VP.glow(VP.accent, strength: 1.1),
            ),
            child: capturing
                ? const Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(
                        strokeWidth: 2.4, color: VP.accent),
                  )
                : const Icon(Icons.fingerprint_rounded,
                    color: Color(0xFF00110B), size: 36),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          gpsLocked
              ? 'Tap to capture a signed frame'
              : 'Waiting for a GPS fix…',
          style: TextStyle(
              fontSize: 11.5,
              color: gpsLocked ? VP.textSecondary : VP.warn),
        ),
      ],
    );
  }
}

/// Slide-in confirmation showing what was just signed.
class _CaptureReceipt extends StatelessWidget {
  const _CaptureReceipt({required this.thumb, required this.envelope});

  final Uint8List? thumb;
  final SignedEnvelope envelope;

  @override
  Widget build(BuildContext context) {
    final DateTime ts =
        DateTime.fromMillisecondsSinceEpoch(envelope.timestampMs, isUtc: true);
    return GlassPanel(
      padding: const EdgeInsets.all(10),
      blur: 14,
      tint: Colors.black,
      opacity: 0.45,
      borderColor: VP.accent.withValues(alpha: 0.3),
      child: Row(
        children: <Widget>[
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 46,
              height: 46,
              child: thumb == null
                  ? const ColoredBox(color: VP.surfaceHigh)
                  : Image.memory(thumb!,
                      fit: BoxFit.cover, gaplessPlayback: true),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    const Icon(Icons.check_circle_rounded,
                        size: 13, color: VP.accent),
                    const SizedBox(width: 5),
                    Text('SIGNED',
                        style: VP.eyebrow.copyWith(color: VP.accent)),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '${envelope.lat.toStringAsFixed(5)}, '
                  '${envelope.lon.toStringAsFixed(5)}  ·  '
                  '${DateFormat('HH:mm:ss').format(ts)}Z',
                  style: VP.monoSmall.copyWith(fontSize: 11),
                  overflow: TextOverflow.ellipsis,
                ),
                Text('dHash ${envelope.pixelHash}',
                    style: VP.monoSmall
                        .copyWith(fontSize: 10, color: VP.textFaint),
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GlassIconButton extends StatelessWidget {
  const _GlassIconButton({
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
      child: GlassPanel(
        padding: const EdgeInsets.all(10),
        borderRadius: BorderRadius.circular(13),
        blur: 10,
        tint: Colors.black,
        opacity: 0.4,
        borderColor: active ? VP.accent.withValues(alpha: 0.5) : VP.hairline,
        child: Icon(icon,
            size: 20, color: active ? VP.accent : Colors.white),
      ),
    );
  }
}

class _Reticle extends StatelessWidget {
  const _Reticle();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 84,
      height: 84,
      child: CustomPaint(painter: _ReticlePainter()),
    );
  }
}

class _ReticlePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Paint stroke = Paint()
      ..color = VP.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6;

    final Rect r = Offset.zero & size;
    const double corner = 16;

    // Four corner brackets.
    for (final List<Offset> seg in <List<Offset>>[
      <Offset>[r.topLeft + const Offset(0, corner), r.topLeft, r.topLeft + const Offset(corner, 0)],
      <Offset>[r.topRight + const Offset(-corner, 0), r.topRight, r.topRight + const Offset(0, corner)],
      <Offset>[r.bottomRight + const Offset(0, -corner), r.bottomRight, r.bottomRight + const Offset(-corner, 0)],
      <Offset>[r.bottomLeft + const Offset(corner, 0), r.bottomLeft, r.bottomLeft + const Offset(0, -corner)],
    ]) {
      canvas.drawPath(
        Path()
          ..moveTo(seg[0].dx, seg[0].dy)
          ..lineTo(seg[1].dx, seg[1].dy)
          ..lineTo(seg[2].dx, seg[2].dy),
        stroke,
      );
    }

    // Center crosshair.
    final Offset c = r.center;
    final Paint thin = Paint()
      ..color = VP.accent.withValues(alpha: 0.75)
      ..strokeWidth = 1.2;
    canvas.drawLine(c + const Offset(-7, 0), c + const Offset(7, 0), thin);
    canvas.drawLine(c + const Offset(0, -7), c + const Offset(0, 7), thin);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _FramingBrackets extends StatelessWidget {
  const _FramingBrackets();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(size: Size.infinite, painter: _FramingPainter());
  }
}

class _FramingPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final Paint p = Paint()
      ..color = Colors.white.withValues(alpha: 0.22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4;

    final Rect r = Rect.fromLTRB(
      26,
      size.height * 0.26,
      size.width - 26,
      size.height * 0.72,
    );
    const double len = 26;

    void bracket(Offset a, Offset b, Offset c) {
      canvas.drawPath(
        Path()
          ..moveTo(a.dx, a.dy)
          ..lineTo(b.dx, b.dy)
          ..lineTo(c.dx, c.dy),
        p,
      );
    }

    bracket(r.topLeft + const Offset(0, len), r.topLeft,
        r.topLeft + const Offset(len, 0));
    bracket(r.topRight + const Offset(-len, 0), r.topRight,
        r.topRight + const Offset(0, len));
    bracket(r.bottomRight + const Offset(0, -len), r.bottomRight,
        r.bottomRight + const Offset(-len, 0));
    bracket(r.bottomLeft + const Offset(len, 0), r.bottomLeft,
        r.bottomLeft + const Offset(0, -len));
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ScanPainter extends CustomPainter {
  _ScanPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final double y = size.height * t;
    canvas.drawRect(
      Rect.fromLTWH(0, y - 60, size.width, 120),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[
            Colors.transparent,
            VP.accent.withValues(alpha: 0.22),
            Colors.transparent,
          ],
        ).createShader(Rect.fromLTWH(0, y - 60, size.width, 120)),
    );
    canvas.drawLine(
      Offset(0, y),
      Offset(size.width, y),
      Paint()
        ..color = VP.accent.withValues(alpha: 0.75)
        ..strokeWidth = 1.4,
    );
  }

  @override
  bool shouldRepaint(covariant _ScanPainter old) => old.t != t;
}

// =======================================================================
// Non-camera states
// =======================================================================

class _Booting extends StatelessWidget {
  const _Booting();

  @override
  Widget build(BuildContext context) {
    return const ForensicBackdrop(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2, color: VP.accent),
            ),
            SizedBox(height: 18),
            Text('INITIALISING SENSOR ARRAY', style: VP.eyebrow),
          ],
        ),
      ),
    );
  }
}

class _PermissionGate extends StatelessWidget {
  const _PermissionGate({required this.error, required this.onRetry});

  final PermissionRequiredException error;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: GlassPanel(
            padding: const EdgeInsets.all(24),
            borderColor: VP.warn.withValues(alpha: 0.3),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: VP.warn.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(
                    error.permissionName == 'Camera'
                        ? Icons.no_photography_rounded
                        : Icons.location_disabled_rounded,
                    color: VP.warn,
                    size: 27,
                  ),
                ),
                const SizedBox(height: 18),
                Text('${error.permissionName} access required',
                    style: VP.title.copyWith(fontSize: 18),
                    textAlign: TextAlign.center),
                const SizedBox(height: 8),
                Text(
                  error.permanentlyDenied
                      ? '${error.permissionName} permission was denied. Enable it in '
                          'system settings to capture signed photos.'
                      : 'VeriPic needs ${error.permissionName.toLowerCase()} access to '
                          'embed a verifiable geotag in every photo.',
                  textAlign: TextAlign.center,
                  style: VP.body,
                ),
                const SizedBox(height: 22),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () async {
                      HapticFeedback.selectionClick();
                      if (error.permanentlyDenied) {
                        await openAppSettings();
                      } else {
                        await onRetry();
                      }
                    },
                    child: Text(error.permanentlyDenied
                        ? 'Open Settings'
                        : 'Grant Access'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FatalError extends StatelessWidget {
  const _FatalError({required this.message, required this.onRetry});

  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: GlassPanel(
            padding: const EdgeInsets.all(24),
            borderColor: VP.danger.withValues(alpha: 0.3),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Icon(Icons.sensors_off_rounded,
                    color: VP.danger, size: 40),
                const SizedBox(height: 16),
                Text('Sensor unavailable',
                    style: VP.title.copyWith(fontSize: 17)),
                const SizedBox(height: 8),
                Text(message, textAlign: TextAlign.center, style: VP.body),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: () => onRetry(),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
