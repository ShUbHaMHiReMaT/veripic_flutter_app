import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:permission_handler/permission_handler.dart';

import '../main.dart' show cameras;
import '../services/camera_service.dart';
import '../services/security_service.dart';
import '../theme/veripic_theme.dart';

/// Accuracy worse than this reads as a weak fix in the status readout.
const double _weakFixMetres = 15;

/// A fix older than this is stale and no longer trustworthy for a stamp.
const Duration _staleFixAge = Duration(seconds: 30);

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
  DateTime _now = DateTime.now();

  bool _initializing = true;
  bool _capturing = false;
  String? _error;
  PermissionRequiredException? _permissionError;

  int _cameraIndex = 0;
  bool _torchOn = false;

  /// Reverse-geocoded site name for the stamp card. Resolved on first fix and
  /// again only after the operator has actually moved.
  String? _siteName;
  Position? _siteResolvedAt;
  bool _resolvingSite = false;

  /// Shown when the shutter is tapped while it is disabled — a camera that
  /// silently refuses is worse than one that says why.
  String? _blockedReason;
  Timer? _blockedTimer;

  /// Most recent capture — backs the thumbnail in the control row.
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
        throw StateError('No camera on this device');
      }
      _cameraIndex = _cameraIndex.clamp(0, cameras.length - 1);
      await _camera.initialize(cameras[_cameraIndex]);

      _clockTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _now = DateTime.now());
      });
      _positionSub ??= Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
          distanceFilter: 1,
        ),
      ).listen(
        (Position p) {
          if (!mounted) return;
          setState(() => _livePosition = p);
          unawaited(_maybeResolveSite(p));
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

  /// Resolves the site name on first fix, then only after a 50 m move.
  Future<void> _maybeResolveSite(Position p) async {
    if (_resolvingSite) return;
    final Position? last = _siteResolvedAt;
    if (last != null) {
      final double moved = Geolocator.distanceBetween(
          last.latitude, last.longitude, p.latitude, p.longitude);
      if (moved < 50) return;
    }

    _resolvingSite = true;
    try {
      final List<Placemark> marks =
          await placemarkFromCoordinates(p.latitude, p.longitude);
      if (!mounted || marks.isEmpty) return;
      final Placemark m = marks.first;
      final String name = <String?>[
        m.subLocality,
        m.locality,
        m.administrativeArea,
      ].firstWhere((String? s) => s != null && s.isNotEmpty,
              orElse: () => null) ??
          'Unnamed site';
      setState(() {
        _siteName = name;
        _siteResolvedAt = p;
      });
    } catch (_) {
      // Geocoder unavailable — the stamp card falls back to coordinates only.
    } finally {
      _resolvingSite = false;
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
    _blockedTimer?.cancel();
    _reticle.dispose();
    _camera.dispose();
    super.dispose();
  }

  // ---- Fix quality ---------------------------------------------------

  bool get _fixIsStale {
    final Position? p = _livePosition;
    if (p == null) return true;
    return DateTime.now().difference(p.timestamp) > _staleFixAge;
  }

  bool get _fixIsUsable {
    final Position? p = _livePosition;
    return p != null && !_fixIsStale;
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

  void _showBlocked(String reason) {
    HapticFeedback.selectionClick();
    _blockedTimer?.cancel();
    setState(() => _blockedReason = reason);
    _blockedTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _blockedReason = null);
    });
  }

  Future<void> _capture() async {
    if (_capturing) return;

    if (!_fixIsUsable) {
      _showBlocked(_livePosition == null
          ? 'No GPS fix yet. Move away from walls and try again.'
          : 'GPS fix is stale. Wait for it to refresh.');
      return;
    }

    HapticFeedback.mediumImpact();
    setState(() {
      _capturing = true;
      _blockedReason = null;
    });

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
          content: Text('Frame stamped, signed, and saved.'),
        ));
    } catch (e) {
      HapticFeedback.vibrate();
      if (mounted) _showBlocked('Capture failed. $e');
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  void _openLastShot() {
    final Uint8List? bytes = _lastThumb;
    if (bytes == null) {
      _showBlocked('No frames in this session yet.');
      return;
    }
    HapticFeedback.selectionClick();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => _LastFramePage(bytes: bytes, envelope: _lastEnvelope),
      ),
    );
  }

  // ---- Build ---------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_permissionError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Viewfinder')),
        body: _PermissionGate(error: _permissionError!, onRetry: _boot),
      );
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Viewfinder')),
        body: _FatalError(message: _error!, onRetry: _boot),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _StatusReadout(
              position: _livePosition,
              stale: _fixIsStale,
              torchOn: _torchOn,
              onBack: () => Navigator.of(context).maybePop(),
              onTorch: _toggleTorch,
            ),
            Expanded(child: _buildFeed()),
            _StampCard(
              site: _siteName,
              position: _livePosition,
              now: _now,
            ),
            if (_blockedReason != null)
              AccentPanel(
                accent: Tokens.statusAlert,
                background: Tokens.canvas,
                padding: const EdgeInsets.fromLTRB(
                    Tokens.spaceSnug, Tokens.spaceTight, Tokens.spaceSnug, Tokens.spaceTight),
                child: Text(_blockedReason!,
                    style: Tokens.body),
              ),
            _ControlRow(
              thumb: _lastThumb,
              capturing: _capturing,
              enabled: _fixIsUsable && !_initializing,
              canFlip: cameras.length > 1,
              onThumb: _openLastShot,
              onShutter: _capture,
              onFlip: _flipCamera,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFeed() {
    final CameraController? controller = _camera.controller;
    if (_initializing || controller == null || !controller.value.isInitialized) {
      return const ColoredBox(
        color: Tokens.surfaceInset,
        child: Center(child: Text('Starting camera', style: Tokens.dataSmall)),
      );
    }

    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final Size area =
                  Size(constraints.maxWidth, constraints.maxHeight);
              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (TapDownDetails d) =>
                    _handleFocusTap(d.localPosition, area),
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
              );
            },
          ),
          if (_focusPoint != null)
            AnimatedBuilder(
              animation: _reticle,
              builder: (BuildContext context, Widget? child) {
                final double t =
                    Curves.easeOut.transform(_reticle.value.clamp(0.0, 1.0));
                return Positioned(
                  left: _focusPoint!.dx - 24,
                  top: _focusPoint!.dy - 24,
                  child: Opacity(opacity: 1 - (t * 0.4), child: child),
                );
              },
              child: Container(
                width: Tokens.touchMin,
                height: Tokens.touchMin,
                decoration: BoxDecoration(
                  border: Border.all(color: Tokens.statusAlert, width: 2),
                  borderRadius: Tokens.brControl,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// =======================================================================
// Status readout
// =======================================================================

/// Top of the viewfinder. Never hidden — a camera that silently loses GPS is
/// worse than one that says so.
class _StatusReadout extends StatelessWidget {
  const _StatusReadout({
    required this.position,
    required this.stale,
    required this.torchOn,
    required this.onBack,
    required this.onTorch,
  });

  final Position? position;
  final bool stale;
  final bool torchOn;
  final VoidCallback onBack;
  final VoidCallback onTorch;

  @override
  Widget build(BuildContext context) {
    final Position? p = position;

    final String text;
    final Color color;
    if (p == null) {
      text = 'NO FIX — SEARCHING';
      color = Tokens.statusAlert;
    } else if (stale) {
      text = 'FIX ±${p.accuracy.round()}M — STALE';
      color = Tokens.statusAlert;
    } else if (p.accuracy > _weakFixMetres) {
      text = 'FIX ±${p.accuracy.round()}M — WEAK';
      color = Tokens.statusAlert;
    } else {
      text = 'FIX ±${p.accuracy.round()}M';
      color = Tokens.textPrimary;
    }

    return Container(
      height: Tokens.touchMin,
      padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceHair),
      decoration: const BoxDecoration(
        color: Tokens.canvas,
        border: Border(bottom: Tokens.sideOutline),
      ),
      child: Row(
        children: <Widget>[
          IconButton(
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back, size: Tokens.iconBase),
            color: Tokens.textPrimary,
            tooltip: 'Back',
          ),
          Expanded(child: StatusText(text: text, color: color)),
          IconButton(
            onPressed: onTorch,
            icon: Icon(
              torchOn ? Icons.wb_sunny : Icons.wb_sunny_outlined,
              size: Tokens.iconBase,
            ),
            color: torchOn ? Tokens.statusAlert : Tokens.textSecondary,
            tooltip: 'Torch',
          ),
        ],
      ),
    );
  }
}

// =======================================================================
// Stamp card
// =======================================================================

/// Shows the values that will be burned into the next frame.
class _StampCard extends StatelessWidget {
  const _StampCard({
    required this.site,
    required this.position,
    required this.now,
  });

  final String? site;
  final Position? position;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final Position? p = position;

    return AccentPanel(
      accent: Tokens.statusAlert,
      padding: const EdgeInsets.all(Tokens.spaceSnug),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            (site ?? 'Locating site').toUpperCase(),
            style: Tokens.label.copyWith(color: Tokens.textPrimary),
          ),
          const SizedBox(height: Tokens.spaceHair),
          Text(
            p == null
                ? '——.——————, ——.——————'
                : '${p.latitude.toStringAsFixed(6)}, '
                    '${p.longitude.toStringAsFixed(6)}  ${p.altitude.round()}M',
            style: Tokens.dataStamp,
          ),
          const SizedBox(height: Tokens.spaceHair),
          Text(
            DateFormat('ddMMMyy HH:mm').format(now).toUpperCase(),
            style: Tokens.dataStamp,
          ),
        ],
      ),
    );
  }
}

// =======================================================================
// Control row
// =======================================================================

class _ControlRow extends StatelessWidget {
  const _ControlRow({
    required this.thumb,
    required this.capturing,
    required this.enabled,
    required this.canFlip,
    required this.onThumb,
    required this.onShutter,
    required this.onFlip,
  });

  final Uint8List? thumb;
  final bool capturing;
  final bool enabled;
  final bool canFlip;
  final VoidCallback onThumb;
  final VoidCallback onShutter;
  final VoidCallback onFlip;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: Tokens.spaceBase, vertical: Tokens.spaceSnug),
      decoration: const BoxDecoration(
        color: Tokens.canvas,
        border: Border(top: Tokens.sideOutline),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          _FrameThumb(thumb: thumb, onTap: onThumb),
          _Shutter(
            enabled: enabled,
            busy: capturing,
            onTap: onShutter,
          ),
          _IconSquare(
            icon: Icons.cameraswitch_outlined,
            onTap: canFlip ? onFlip : null,
            tooltip: 'Switch camera',
          ),
        ],
      ),
    );
  }
}

/// 44dp square shutter. Disabled state still accepts taps so it can explain
/// itself rather than doing nothing.
class _Shutter extends StatefulWidget {
  const _Shutter({
    required this.enabled,
    required this.busy,
    required this.onTap,
  });

  final bool enabled;
  final bool busy;
  final VoidCallback onTap;

  @override
  State<_Shutter> createState() => _ShutterState();
}

class _ShutterState extends State<_Shutter> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final bool live = widget.enabled && !widget.busy;

    return Semantics(
      button: true,
      enabled: live,
      label: 'Capture frame',
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: widget.busy ? null : widget.onTap,
        // Touch target stays 48dp even though the control reads as 44dp.
        child: SizedBox(
          width: Tokens.touchMin + Tokens.spaceBase,
          height: Tokens.touchMin + Tokens.spaceBase,
          child: Center(
            child: AnimatedScale(
              scale: _pressed && live ? 0.96 : 1,
              duration: const Duration(milliseconds: 90),
              child: Container(
                width: Tokens.shutterSize,
                height: Tokens.shutterSize,
                decoration: BoxDecoration(
                  color: !live
                      ? Tokens.surfaceInset
                      : (_pressed ? Tokens.accentPressed : Tokens.textPrimary),
                  borderRadius: Tokens.brControl,
                ),
                child: widget.busy
                    ? const Padding(
                        padding: EdgeInsets.all(Tokens.spaceSnug),
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Tokens.surface),
                      )
                    : Icon(
                        Icons.circle,
                        size: Tokens.iconSmall,
                        color: live ? Tokens.surface : Tokens.textSecondary,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Thumbnail of the last frame — the way out to review what was just shot.
class _FrameThumb extends StatelessWidget {
  const _FrameThumb({required this.thumb, required this.onTap});

  final Uint8List? thumb;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Uint8List? bytes = thumb;

    return Semantics(
      button: true,
      label: 'Review last frame',
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: Tokens.touchMin + Tokens.spaceBase,
          height: Tokens.touchMin + Tokens.spaceBase,
          child: Center(
            child: Container(
              width: Tokens.thumbSize,
              height: Tokens.thumbSize,
              decoration: BoxDecoration(
                color: Tokens.surfaceInset,
                border: Border.all(color: Tokens.outline),
                borderRadius: Tokens.brControl,
              ),
              clipBehavior: Clip.antiAlias,
              child: bytes == null
                  ? const Icon(Icons.photo_outlined,
                      size: 20, color: Tokens.textSecondary)
                  : Image.memory(bytes,
                      fit: BoxFit.cover, gaplessPlayback: true),
            ),
          ),
        ),
      ),
    );
  }
}

class _IconSquare extends StatelessWidget {
  const _IconSquare({required this.icon, this.onTap, this.tooltip});

  final IconData icon;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip ?? '',
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: Tokens.touchMin + Tokens.spaceBase,
          height: Tokens.touchMin + Tokens.spaceBase,
          child: Center(
            child: Container(
              width: Tokens.shutterSize,
              height: Tokens.shutterSize,
              decoration: BoxDecoration(
                color: Tokens.surface,
                border: Border.all(color: Tokens.outline),
                borderRadius: Tokens.brControl,
              ),
              child: Icon(icon,
                  size: Tokens.iconBase, color: onTap == null ? Tokens.outline : Tokens.textPrimary),
            ),
          ),
        ),
      ),
    );
  }
}

// =======================================================================
// Last frame review
// =======================================================================

class _LastFramePage extends StatelessWidget {
  const _LastFramePage({required this.bytes, required this.envelope});

  final Uint8List bytes;
  final SignedEnvelope? envelope;

  @override
  Widget build(BuildContext context) {
    final SignedEnvelope? e = envelope;

    return Scaffold(
      appBar: AppBar(title: const Text('Last frame')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Tokens.spaceBase, Tokens.spaceTight, Tokens.spaceBase, Tokens.spaceScreen),
        children: <Widget>[
          Container(
            decoration: BoxDecoration(border: Border.all(color: Tokens.outline)),
            child: ColoredBox(
              color: Tokens.surfaceInset,
              child: InteractiveViewer(
                maxScale: Tokens.zoomMaxScale,
                child: Image.memory(bytes, fit: BoxFit.contain),
              ),
            ),
          ),
          const SizedBox(height: Tokens.spaceSection),
          const SectionHead(title: 'Signed payload'),
          const SizedBox(height: Tokens.spaceSnug),
          if (e != null)
            FieldCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  DataLine(
                    label: 'Coordinates',
                    value: '${e.lat.toStringAsFixed(6)}, '
                        '${e.lon.toStringAsFixed(6)}',
                  ),
                  DataLine(
                      label: 'Altitude',
                      value: '${e.alt.toStringAsFixed(1)} m'),
                  DataLine(
                    label: 'Captured',
                    value: '${DateFormat('ddMMMyy HH:mm:ss').format(
                      DateTime.fromMillisecondsSinceEpoch(e.timestampMs,
                          isUtc: true),
                    ).toUpperCase()} UTC',
                  ),
                  DataLine(label: 'Device', value: e.deviceId),
                  DataLine(label: 'Signing key', value: e.kid ?? '—'),
                  DataLine(label: 'Banner hash', value: e.pixelHash),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// =======================================================================
// Blocking states
// =======================================================================

class _PermissionGate extends StatelessWidget {
  const _PermissionGate({required this.error, required this.onRetry});

  final PermissionRequiredException error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(Tokens.spaceBase),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AccentPanel(
            accent: Tokens.statusAlert,
            child: Text(
              error.permanentlyDenied
                  ? '${error.permissionName} access is turned off. Enable it in '
                      'system settings to capture frames.'
                  : '${error.permissionName} access is needed to stamp and sign '
                      'frames.',
              style: Tokens.body,
            ),
          ),
          const SizedBox(height: Tokens.spaceSection),
          if (error.permanentlyDenied)
            const FilledButton(
              onPressed: openAppSettings,
              child: Text('Open settings'),
            )
          else
            FilledButton(
              onPressed: onRetry,
              child: Text('Allow ${error.permissionName.toLowerCase()}'),
            ),
        ],
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
    return Padding(
      padding: const EdgeInsets.all(Tokens.spaceBase),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AccentPanel(
            accent: Tokens.statusAlert,
            child: Text('The camera did not start. $message', style: Tokens.body),
          ),
          const SizedBox(height: Tokens.spaceSection),
          FilledButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    );
  }
}
