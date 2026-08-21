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
import '../theme/veripic_theme.dart';
import 'frames_screen.dart';

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

  /// Shown when the shutter is tapped while disabled — a camera that silently
  /// refuses is worse than one that says why.
  String? _blockedReason;
  Timer? _blockedTimer;

  /// Thumbnail of the most recent capture, for the frames button.
  Uint8List? _lastThumb;
  int _sessionCount = 0;

  // Tap-to-focus reticle.
  Offset? _focusPoint;
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
    _camera.dispose();
    super.dispose();
  }

  // ---- Fix quality ---------------------------------------------------

  bool get _fixIsStale {
    final Position? p = _livePosition;
    if (p == null) return true;
    return DateTime.now().difference(p.timestamp) > _staleFixAge;
  }

  bool get _fixIsUsable => _livePosition != null && !_fixIsStale;

  // ---- Interactions --------------------------------------------------

  Future<void> _handleFocusTap(Offset local, Size area) async {
    if (area.width == 0 || area.height == 0) return;
    HapticFeedback.selectionClick();
    setState(() => _focusPoint = local);
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
        _sessionCount++;
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

  void _openFrames() {
    HapticFeedback.selectionClick();
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const FramesScreen()),
    );
  }

  // ---- Build ---------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (_permissionError != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Viewfinder')),
        body: Padding(
          padding: const EdgeInsets.all(Tokens.spaceBase),
          child: ErrorState(
            message: _permissionError!.permanentlyDenied
                ? '${_permissionError!.permissionName} access is turned off. '
                    'Enable it in system settings to capture frames.'
                : '${_permissionError!.permissionName} access is needed to '
                    'stamp and sign frames.',
            actionLabel: _permissionError!.permanentlyDenied
                ? 'Open settings'
                : 'Allow ${_permissionError!.permissionName.toLowerCase()}',
            onAction:
                _permissionError!.permanentlyDenied ? openAppSettings : _boot,
          ),
        ),
      );
    }

    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Viewfinder')),
        body: Padding(
          padding: const EdgeInsets.all(Tokens.spaceBase),
          child: ErrorState(
            message: 'The camera did not start. ${_error!}',
            actionLabel: 'Try again',
            onAction: _boot,
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Viewfinder'),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: Tokens.spaceBase),
            child: IconButtonTile(
              icon: _torchOn ? Icons.wb_sunny : Icons.wb_sunny_outlined,
              semanticLabel: 'Torch',
              color: _torchOn ? Tokens.accent : null,
              onPressed: _toggleTorch,
            ),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Tokens.spaceBase),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _StatusReadout(position: _livePosition, stale: _fixIsStale),
              const SizedBox(height: Tokens.spaceSnug),
              Expanded(child: _buildFeed()),
              const SizedBox(height: Tokens.spaceSnug),
              _StampCard(
                site: _siteName,
                position: _livePosition,
                now: _now,
              ),
              if (_blockedReason != null) ...<Widget>[
                const SizedBox(height: Tokens.spaceSnug),
                ErrorState(message: _blockedReason!),
              ],
              const SizedBox(height: Tokens.spaceSnug),
              _ControlRow(
                thumb: _lastThumb,
                count: _sessionCount,
                capturing: _capturing,
                enabled: _fixIsUsable && !_initializing,
                canFlip: cameras.length > 1,
                onFrames: _openFrames,
                onShutter: _capture,
                onFlip: _flipCamera,
              ),
              const SizedBox(height: Tokens.spaceBase),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFeed() {
    final Palette p = Palette.of(context);
    final CameraController? controller = _camera.controller;

    return PressCard(
      padding: const EdgeInsets.all(Tokens.spaceTight),
      child: ClipRRect(
        borderRadius: Tokens.brControl,
        child: ColoredBox(
          color: p.surfaceInset,
          child: (_initializing ||
                  controller == null ||
                  !controller.value.isInitialized)
              ? Center(child: Text('Starting camera', style: p.dataSmall))
              : Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    LayoutBuilder(
                      builder:
                          (BuildContext context, BoxConstraints constraints) {
                        final Size area = Size(
                            constraints.maxWidth, constraints.maxHeight);
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
                                height: area.width *
                                    controller.value.aspectRatio,
                                child: CameraPreview(controller),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                    if (_focusPoint != null)
                      Positioned(
                        left: _focusPoint!.dx - Tokens.markSize,
                        top: _focusPoint!.dy - Tokens.markSize,
                        child: Container(
                          width: Tokens.touchMin,
                          height: Tokens.touchMin,
                          decoration: BoxDecoration(
                            border: Border.all(
                              color: Tokens.accent,
                              width: Tokens.borderWidth,
                            ),
                            borderRadius: Tokens.brControl,
                          ),
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

// =======================================================================
// Status readout
// =======================================================================

/// Never hidden — a camera that silently loses GPS is worse than one that
/// says so.
class _StatusReadout extends StatelessWidget {
  const _StatusReadout({required this.position, required this.stale});

  final Position? position;
  final bool stale;

  @override
  Widget build(BuildContext context) {
    final Position? p = position;

    final String text;
    final Color tint;
    if (p == null) {
      text = 'no fix — searching';
      tint = Tokens.statusAlert;
    } else if (stale) {
      text = 'fix ±${p.accuracy.round()}m — stale';
      tint = Tokens.statusAlert;
    } else if (p.accuracy > _weakFixMetres) {
      text = 'fix ±${p.accuracy.round()}m — weak';
      tint = Tokens.statusAlert;
    } else {
      text = 'fix ±${p.accuracy.round()}m';
      tint = Tokens.statusOk;
    }

    return Semantics(
      liveRegion: true,
      child: Align(
        alignment: Alignment.centerLeft,
        child: StatusBadge(label: text, color: tint),
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
    final Palette p = Palette.of(context);
    final Position? pos = position;

    return AccentPanel(
      accent: Tokens.accent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(site ?? 'Locating site', style: p.cardTitle),
          const SizedBox(height: Tokens.spaceHair),
          Text(
            pos == null
                ? '——.——————, ——.——————'
                : '${pos.latitude.toStringAsFixed(6)}, '
                    '${pos.longitude.toStringAsFixed(6)}  '
                    '${pos.altitude.round()}M',
            style: p.dataStamp,
          ),
          const SizedBox(height: Tokens.spaceHair),
          Text(
            DateFormat('ddMMMyy HH:mm').format(now).toUpperCase(),
            style: p.dataStamp,
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
    required this.count,
    required this.capturing,
    required this.enabled,
    required this.canFlip,
    required this.onFrames,
    required this.onShutter,
    required this.onFlip,
  });

  final Uint8List? thumb;
  final int count;
  final bool capturing;
  final bool enabled;
  final bool canFlip;
  final VoidCallback onFrames;
  final VoidCallback onShutter;
  final VoidCallback onFlip;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        _FramesButton(thumb: thumb, count: count, onTap: onFrames),
        _Shutter(enabled: enabled, busy: capturing, onTap: onShutter),
        IconButtonTile(
          icon: Icons.cameraswitch_outlined,
          semanticLabel: 'Switch camera',
          onPressed: canFlip ? onFlip : null,
        ),
      ],
    );
  }
}

/// Opens the scrollable gallery of frames this app captured.
class _FramesButton extends StatelessWidget {
  const _FramesButton({
    required this.thumb,
    required this.count,
    required this.onTap,
  });

  final Uint8List? thumb;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);
    final Uint8List? bytes = thumb;

    return SizedBox(
      width: Tokens.thumbSize,
      height: Tokens.thumbSize,
      child: PressCard(
        onTap: onTap,
        borderRadius: Tokens.brControl,
        padding: EdgeInsets.zero,
        color: p.surfaceInset,
        semanticLabel: 'Frames. $count captured this session',
        child: ClipRRect(
          borderRadius: Tokens.brControl,
          child: bytes == null
              ? Icon(Icons.photo_outlined,
                  size: Tokens.iconBase, color: p.textSecondary)
              : Image.memory(bytes, fit: BoxFit.cover, gaplessPlayback: true),
        ),
      ),
    );
  }
}

/// Square shutter. Disabled still accepts taps so it can explain itself.
class _Shutter extends StatelessWidget {
  const _Shutter({
    required this.enabled,
    required this.busy,
    required this.onTap,
  });

  final bool enabled;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);
    final bool live = enabled && !busy;

    return SizedBox(
      width: Tokens.shutterSize,
      height: Tokens.shutterSize,
      child: PressCard(
        onTap: busy ? null : onTap,
        color: live ? Tokens.accent : p.surfaceInset,
        borderRadius: Tokens.brControl,
        padding: EdgeInsets.zero,
        semanticLabel: 'Capture frame',
        child: busy
            ? const Padding(
                padding: EdgeInsets.all(Tokens.spaceBase),
                child: CircularProgressIndicator(
                  strokeWidth: Tokens.borderWidth,
                  color: Tokens.onIdentity,
                ),
              )
            : Icon(
                Icons.circle,
                size: Tokens.iconTile,
                color: live ? Tokens.onIdentity : p.textSecondary,
              ),
      ),
    );
  }
}
