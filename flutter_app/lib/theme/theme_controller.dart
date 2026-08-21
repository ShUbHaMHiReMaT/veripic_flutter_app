import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Holds the user's theme choice and persists it across launches.
///
/// [ThemeMode.system] is the default, so the app follows the device until the
/// user states a preference of their own.
class ThemeController extends ValueNotifier<ThemeMode> {
  ThemeController() : super(ThemeMode.system);

  static const String _storageKey = 'veripic_theme_mode';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  Future<void> load() async {
    try {
      final String? stored = await _storage.read(key: _storageKey);
      value = _decode(stored);
    } catch (_) {
      // Storage unavailable — fall back to following the system.
    }
  }

  /// Cycles system → light → dark → system.
  Future<void> cycle() async {
    value = switch (value) {
      ThemeMode.system => ThemeMode.light,
      ThemeMode.light => ThemeMode.dark,
      ThemeMode.dark => ThemeMode.system,
    };
    try {
      await _storage.write(key: _storageKey, value: _encode(value));
    } catch (_) {
      // Non-fatal: the choice still applies for this session.
    }
  }

  IconData get icon => switch (value) {
        ThemeMode.system => Icons.brightness_auto_outlined,
        ThemeMode.light => Icons.light_mode_outlined,
        ThemeMode.dark => Icons.dark_mode_outlined,
      };

  String get label => switch (value) {
        ThemeMode.system => 'Theme: follows device',
        ThemeMode.light => 'Theme: light',
        ThemeMode.dark => 'Theme: dark',
      };

  static ThemeMode _decode(String? s) => switch (s) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };

  static String _encode(ThemeMode m) => switch (m) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
      };
}
