import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/frame_store.dart';
import '../theme/theme_controller.dart';
import '../theme/veripic_theme.dart';
import 'frames_screen.dart';
import 'home_screen.dart';
import 'locations_screen.dart';

/// Bottom-tab shell: Home, Frames, Locations.
class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.themeController});

  final ThemeController themeController;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A capture taken while the shell was backgrounded (the camera is pushed
    // over it) has to show up when the user comes back.
    if (state == AppLifecycleState.resumed) FrameStore.notifyChanged();
  }

  /// Re-reads the store whenever a listing tab is opened.
  ///
  /// The capture pipeline already signals a change, but this screen must not
  /// depend on a single in-process notification arriving: anything that writes
  /// a frame while these tabs are alive is picked up here regardless.
  void _select(int index) {
    if (index != 0) FrameStore.notifyChanged();
    setState(() => _index = index);
  }

  static const List<String> _titles = <String>[
    'GeoGuard',
    'Photos',
    'Locations'
  ];

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_titles[_index]),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: Tokens.spaceBase),
            child: ValueListenableBuilder<ThemeMode>(
              valueListenable: widget.themeController,
              builder: (BuildContext context, ThemeMode mode, _) =>
                  IconButtonTile(
                icon: widget.themeController.icon,
                semanticLabel: widget.themeController.label,
                onPressed: () {
                  HapticFeedback.selectionClick();
                  widget.themeController.cycle();
                },
              ),
            ),
          ),
        ],
      ),
      body: IndexedStack(
        index: _index,
        children: const <Widget>[
          HomeScreen(),
          FramesScreen(),
          LocationsScreen(),
        ],
      ),
      bottomNavigationBar: DecoratedBox(
        decoration: BoxDecoration(
          color: p.surface,
          border: Border(top: p.side),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Tokens.spaceSnug,
              vertical: Tokens.spaceTight,
            ),
            child: Row(
              children: <Widget>[
                _NavTab(
                  icon: Icons.grid_view_outlined,
                  label: 'Home',
                  selected: _index == 0,
                  tint: Tokens.accent,
                  onTap: () => _select(0),
                ),
                const SizedBox(width: Tokens.spaceTight),
                _NavTab(
                  icon: Icons.photo_library_outlined,
                  label: 'Photos',
                  selected: _index == 1,
                  tint: Tokens.tintInfo,
                  onTap: () => _select(1),
                ),
                const SizedBox(width: Tokens.spaceTight),
                _NavTab(
                  icon: Icons.place_outlined,
                  label: 'Locations',
                  selected: _index == 2,
                  tint: Tokens.statusOk,
                  onTap: () => _select(2),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavTab extends StatelessWidget {
  const _NavTab({
    required this.icon,
    required this.label,
    required this.selected,
    required this.tint,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final Color tint;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);

    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: label,
        child: PressCard(
          onTap: () {
            HapticFeedback.selectionClick();
            onTap();
          },
          color: selected ? tint : p.surface,
          borderRadius: Tokens.brControl,
          shadow: selected,
          padding: const EdgeInsets.symmetric(vertical: Tokens.spaceTight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                icon,
                size: Tokens.iconBase,
                color: selected ? Tokens.onIdentity : p.textSecondary,
              ),
              const SizedBox(height: Tokens.spaceHair),
              Text(
                label,
                style: Tokens.dataSmall.copyWith(
                  color: selected ? Tokens.onIdentity : p.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
