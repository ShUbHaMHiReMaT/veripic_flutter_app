import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';

import '../services/frame_store.dart';
import '../services/security_service.dart';
import '../theme/veripic_theme.dart';
import 'frame_detail_screen.dart';

/// One capture, reduced to the parts the map needs.
class _Pin {
  const _Pin({
    required this.frame,
    required this.point,
    required this.capturedAt,
  });

  final StoredFrame frame;
  final LatLng point;
  final DateTime capturedAt;
}

/// Where every frame was taken, on a real slippy map.
///
/// Tiles come from OpenStreetMap, which needs no API key and no billing
/// account. Markers are drawn by the app, so they follow the design system
/// rather than the tile provider's styling.
class LocationsScreen extends StatefulWidget {
  const LocationsScreen({super.key});

  @override
  State<LocationsScreen> createState() => _LocationsScreenState();
}

class _LocationsScreenState extends State<LocationsScreen>
    with TickerProviderStateMixin {
  final FrameStore _store = FrameStore();
  final SecurityService _security = SecurityService();
  final MapController _map = MapController();

  late Future<List<_Pin>> _future = _load();

  /// Index of the pin currently centred, so the list and the map agree.
  int _selected = 0;

  static const double _focusZoom = 16;

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
          point: LatLng(e.lat, e.lon),
          capturedAt: f.capturedAt,
        ));
      } catch (_) {
        // Unreadable frame — skip it rather than losing the whole map.
      }
    }
    return pins;
  }

  Future<void> _refresh() async {
    setState(() {
      _future = _load();
      _selected = 0;
    });
    await _future;
  }

  /// Glides the map to [pin] instead of teleporting, so the operator keeps
  /// their sense of where the new location sits relative to the old one.
  void _focus(int index, _Pin pin) {
    HapticFeedback.selectionClick();
    setState(() => _selected = index);

    final LatLng from = _map.camera.center;
    final double fromZoom = _map.camera.zoom;

    final AnimationController controller = AnimationController(
      vsync: this,
      duration: Tokens.motion(context, Tokens.motionBase),
    );
    final Animation<double> curve =
        CurvedAnimation(parent: controller, curve: Curves.easeOut);

    controller.addListener(() {
      final double t = curve.value;
      _map.move(
        LatLng(
          from.latitude + (pin.point.latitude - from.latitude) * t,
          from.longitude + (pin.point.longitude - from.longitude) * t,
        ),
        fromZoom + (_focusZoom - fromZoom) * t,
      );
    });
    controller.addStatusListener((AnimationStatus s) {
      if (s == AnimationStatus.completed) controller.dispose();
    });
    controller.forward();
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
            message: 'Capture locations could not be read. Try again.',
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

        final int selected = _selected.clamp(0, pins.length - 1);

        return Column(
          children: <Widget>[
            Expanded(
              flex: 3,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  Tokens.spaceBase,
                  Tokens.spaceBase,
                  Tokens.spaceBase,
                  Tokens.spaceSnug,
                ),
                child: _MapPanel(
                  controller: _map,
                  pins: pins,
                  selected: selected,
                  onPinTap: _focus,
                ),
              ),
            ),
            Expanded(
              flex: 2,
              child: _PinList(
                pins: pins,
                selected: selected,
                onTap: _focus,
                onRefresh: _refresh,
              ),
            ),
          ],
        );
      },
    );
  }
}

// =======================================================================
// Map
// =======================================================================

class _MapPanel extends StatelessWidget {
  const _MapPanel({
    required this.controller,
    required this.pins,
    required this.selected,
    required this.onPinTap,
  });

  final MapController controller;
  final List<_Pin> pins;
  final int selected;
  final void Function(int, _Pin) onPinTap;

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);
    final bool dark = Theme.of(context).brightness == Brightness.dark;

    return PressCard(
      padding: const EdgeInsets.all(Tokens.spaceTight),
      child: ClipRRect(
        borderRadius: Tokens.brControl,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: p.outline, width: Tokens.borderWidth),
            borderRadius: Tokens.brControl,
          ),
          child: ClipRRect(
            borderRadius: Tokens.brControl,
            child: Stack(
              children: <Widget>[
                FlutterMap(
                  mapController: controller,
                  options: MapOptions(
                    initialCenter: pins[selected].point,
                    initialZoom: 15,
                    minZoom: 2,
                    maxZoom: 18,
                    backgroundColor: p.surfaceInset,
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.pinchZoom |
                          InteractiveFlag.drag |
                          InteractiveFlag.doubleTapZoom |
                          InteractiveFlag.flingAnimation,
                    ),
                  ),
                  children: <Widget>[
                    // Desaturate and, in dark mode, invert the basemap so it
                    // sits under the palette instead of fighting it.
                    ColorFiltered(
                      colorFilter: dark
                          ? const ColorFilter.matrix(<double>[
                              -0.6, -0.3, -0.1, 0, 235, //
                              -0.2, -0.7, -0.1, 0, 235, //
                              -0.2, -0.3, -0.5, 0, 235, //
                              0, 0, 0, 1, 0,
                            ])
                          : const ColorFilter.matrix(<double>[
                              0.45, 0.45, 0.1, 0, 40, //
                              0.35, 0.55, 0.1, 0, 40, //
                              0.3, 0.4, 0.3, 0, 40, //
                              0, 0, 0, 1, 0,
                            ]),
                      child: TileLayer(
                        urlTemplate:
                            'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                        userAgentPackageName: 'com.example.veripic',
                        maxNativeZoom: 19,
                      ),
                    ),
                    MarkerLayer(
                      markers: <Marker>[
                        for (int i = 0; i < pins.length; i++)
                          Marker(
                            point: pins[i].point,
                            width: Tokens.touchMin,
                            height: Tokens.touchMin,
                            alignment: Alignment.center,
                            child: _MapPin(
                              active: i == selected,
                              onTap: () => onPinTap(i, pins[i]),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
                // OSM requires visible attribution.
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Tokens.spaceHair,
                      vertical: 1,
                    ),
                    color: p.surface,
                    child: Text('© OpenStreetMap', style: p.dataSmall),
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

/// Square outlined pin, matching the icon-tile vernacular of the rest of the
/// app rather than the tile provider's own marker style.
class _MapPin extends StatelessWidget {
  const _MapPin({required this.active, required this.onTap});

  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);
    final double size = active ? Tokens.spaceSection : Tokens.spaceBase;

    return Semantics(
      button: true,
      selected: active,
      label: 'Capture location',
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Center(
          child: AnimatedContainer(
            duration: Tokens.motion(context, Tokens.motionFast),
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: active ? Tokens.accent : Tokens.statusOk,
              borderRadius: BorderRadius.circular(Tokens.spaceHair),
              border: Border.all(color: p.outline, width: Tokens.borderWidth),
            ),
            child: active
                ? const Icon(Icons.center_focus_strong,
                    size: Tokens.iconSmall, color: Tokens.onIdentity)
                : null,
          ),
        ),
      ),
    );
  }
}

// =======================================================================
// Pin list
// =======================================================================

class _PinList extends StatelessWidget {
  const _PinList({
    required this.pins,
    required this.selected,
    required this.onTap,
    required this.onRefresh,
  });

  final List<_Pin> pins;
  final int selected;
  final void Function(int, _Pin) onTap;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(
          Tokens.spaceBase,
          0,
          Tokens.spaceBase,
          Tokens.spaceBase,
        ),
        itemCount: pins.length + 1,
        separatorBuilder: (_, __) =>
            const SizedBox(height: Tokens.spaceTight),
        itemBuilder: (BuildContext context, int i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: Tokens.spaceHair),
              child: SectionHead(title: '${pins.length} pinned'),
            );
          }

          final int index = i - 1;
          final _Pin pin = pins[index];
          final bool active = index == selected;

          return PressCard(
            onTap: () => onTap(index, pin),
            color: active ? Tokens.accent : p.surface,
            padding: const EdgeInsets.all(Tokens.spaceSnug),
            semanticLabel: 'Capture at '
                '${pin.point.latitude.toStringAsFixed(5)}, '
                '${pin.point.longitude.toStringAsFixed(5)}',
            child: Row(
              children: <Widget>[
                IconTile(
                  icon: Icons.place_outlined,
                  color: active ? p.surface : Tokens.statusOk,
                  size: Tokens.tileSize - Tokens.spaceSnug,
                ),
                const SizedBox(width: Tokens.spaceSnug),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        DateFormat('ddMMMyy HH:mm')
                            .format(pin.capturedAt)
                            .toUpperCase(),
                        style: active
                            ? p.cardTitle.copyWith(color: Tokens.onIdentity)
                            : p.cardTitle,
                      ),
                      const SizedBox(height: Tokens.spaceHair),
                      Text(
                        '${pin.point.latitude.toStringAsFixed(5)}, '
                        '${pin.point.longitude.toStringAsFixed(5)}',
                        style: active
                            ? Tokens.dataSmall
                                .copyWith(color: Tokens.onIdentity)
                            : p.dataSmall,
                      ),
                    ],
                  ),
                ),
                IconButtonTile(
                  icon: Icons.open_in_full,
                  semanticLabel: 'Open frame',
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => FrameDetailScreen(frame: pin.frame),
                      ),
                    );
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
