import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../services/frame_store.dart';
import '../services/security_service.dart';
import '../theme/veripic_theme.dart';
import 'frame_detail_screen.dart';

/// One capture, reduced to the parts the map needs.
class _Pin {
  const _Pin({
    required this.frame,
    required this.lat,
    required this.lon,
    required this.capturedAt,
  });

  final StoredFrame frame;
  final double lat;
  final double lon;
  final DateTime capturedAt;
}

/// Where every frame was taken.
///
/// The plot is drawn from the signed coordinates themselves rather than a
/// tiled basemap, so it works with no network and no map SDK.
class LocationsScreen extends StatefulWidget {
  const LocationsScreen({super.key});

  @override
  State<LocationsScreen> createState() => _LocationsScreenState();
}

class _LocationsScreenState extends State<LocationsScreen> {
  final FrameStore _store = FrameStore();
  final SecurityService _security = SecurityService();

  late Future<List<_Pin>> _future = _load();

  Future<List<_Pin>> _load() async {
    final List<StoredFrame> frames = await _store.list();
    final List<_Pin> pins = <_Pin>[];

    for (final StoredFrame f in frames) {
      try {
        final Uint8List bytes = await f.file.readAsBytes();
        final SignedEnvelope? e = _security.extractEnvelope(bytes);
        if (e == null) continue;
        if (e.lat == 0 && e.lon == 0) continue;
        pins.add(_Pin(
          frame: f,
          lat: e.lat,
          lon: e.lon,
          capturedAt: f.capturedAt,
        ));
      } catch (_) {
        // Unreadable frame — skip it rather than losing the whole map.
      }
    }
    return pins;
  }

  Future<void> _refresh() async {
    setState(() => _future = _load());
    await _future;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<_Pin>>(
      future: _future,
      builder: (BuildContext context, AsyncSnapshot<List<_Pin>> snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(Tokens.spaceBase),
            child: LoadingState(message: 'Reading capture locations'),
          );
        }

        if (snap.hasError) {
          return ErrorState(
            message: 'Capture locations could not be read. Pull down to try '
                'again.',
            actionLabel: 'Try again',
            onAction: _refresh,
          );
        }

        final List<_Pin> pins = snap.data ?? const <_Pin>[];
        if (pins.isEmpty) {
          return const EmptyState(
            icon: Icons.place_outlined,
            title: 'No locations yet',
            message: 'Every frame you capture is pinned here by the '
                'coordinates sealed into it. Take a frame to place the first '
                'pin.',
          );
        }

        return RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(
              Tokens.spaceBase,
              Tokens.spaceBase,
              Tokens.spaceBase,
              Tokens.spaceScreen,
            ),
            children: <Widget>[
              PressCard(
                padding: const EdgeInsets.all(Tokens.spaceTight),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: _PlotSurface(pins: pins),
                ),
              ),
              const SizedBox(height: Tokens.spaceBase),
              SectionHead(title: '${pins.length} pinned'),
              const SizedBox(height: Tokens.spaceSnug),
              for (final _Pin pin in pins) ...<Widget>[
                LogRow(
                  icon: Icons.place_outlined,
                  tint: Tokens.statusOk,
                  title: DateFormat('ddMMMyy HH:mm')
                      .format(pin.capturedAt)
                      .toUpperCase(),
                  lines: <String>[
                    '${pin.lat.toStringAsFixed(5)}, '
                        '${pin.lon.toStringAsFixed(5)}',
                  ],
                  onTap: () {
                    HapticFeedback.selectionClick();
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => FrameDetailScreen(frame: pin.frame),
                      ),
                    );
                  },
                ),
                const SizedBox(height: Tokens.spaceTight),
              ],
            ],
          ),
        );
      },
    );
  }
}

/// Square pins plotted on an equirectangular projection of their own bounds.
class _PlotSurface extends StatelessWidget {
  const _PlotSurface({required this.pins});

  final List<_Pin> pins;

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);

    return ClipRRect(
      borderRadius: Tokens.brControl,
      child: Container(
        decoration: BoxDecoration(
          color: p.surfaceInset,
          borderRadius: Tokens.brControl,
          border: Border.all(color: p.outline, width: Tokens.borderWidth),
        ),
        child: CustomPaint(
          painter: _PlotPainter(
            pins: pins,
            grid: p.outline.withValues(alpha: 0.12),
            pin: Tokens.statusOk,
            newest: Tokens.accent,
            outline: p.outline,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _PlotPainter extends CustomPainter {
  _PlotPainter({
    required this.pins,
    required this.grid,
    required this.pin,
    required this.newest,
    required this.outline,
  });

  final List<_Pin> pins;
  final Color grid;
  final Color pin;
  final Color newest;
  final Color outline;

  @override
  void paint(Canvas canvas, Size size) {
    // Survey grid.
    final Paint gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    const int divisions = 6;
    for (int i = 1; i < divisions; i++) {
      final double d = size.width * i / divisions;
      canvas.drawLine(Offset(d, 0), Offset(d, size.height), gridPaint);
      final double v = size.height * i / divisions;
      canvas.drawLine(Offset(0, v), Offset(size.width, v), gridPaint);
    }

    if (pins.isEmpty) return;

    double minLat = pins.first.lat, maxLat = pins.first.lat;
    double minLon = pins.first.lon, maxLon = pins.first.lon;
    for (final _Pin p in pins) {
      minLat = math.min(minLat, p.lat);
      maxLat = math.max(maxLat, p.lat);
      minLon = math.min(minLon, p.lon);
      maxLon = math.max(maxLon, p.lon);
    }

    // A single pin, or several within metres of each other, would divide by
    // ~zero — pad the window so they land sensibly instead.
    const double minSpan = 0.0009; // roughly 100 m
    double latSpan = math.max(maxLat - minLat, minSpan);
    double lonSpan = math.max(maxLon - minLon, minSpan);

    // Keep the projection square so shape is not distorted.
    final double span = math.max(latSpan, lonSpan);
    latSpan = span;
    lonSpan = span;

    final double latMid = (minLat + maxLat) / 2;
    final double lonMid = (minLon + maxLon) / 2;
    const double inset = Tokens.spaceBase;

    Offset project(_Pin p) {
      final double x = (p.lon - (lonMid - lonSpan / 2)) / lonSpan;
      // Latitude grows north, screen y grows south.
      final double y = 1 - (p.lat - (latMid - latSpan / 2)) / latSpan;
      return Offset(
        inset + x * (size.width - inset * 2),
        inset + y * (size.height - inset * 2),
      );
    }

    final Paint stroke = Paint()
      ..color = outline
      ..style = PaintingStyle.stroke
      ..strokeWidth = Tokens.borderWidth;

    // Oldest first, so the newest pin lands on top.
    for (int i = pins.length - 1; i >= 0; i--) {
      final Offset c = project(pins[i]);
      final Rect r = Rect.fromCenter(
        center: c,
        width: Tokens.spaceSnug,
        height: Tokens.spaceSnug,
      );
      canvas.drawRect(r, Paint()..color = i == 0 ? newest : pin);
      canvas.drawRect(r, stroke);
    }
  }

  @override
  bool shouldRepaint(covariant _PlotPainter old) =>
      old.pins != pins || old.pin != pin || old.grid != grid;
}
