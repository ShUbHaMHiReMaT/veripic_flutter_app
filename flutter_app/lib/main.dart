import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import 'screens/app_shell.dart';
import 'theme/theme_controller.dart';
import 'theme/veripic_theme.dart';

List<CameraDescription> cameras = <CameraDescription>[];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint('Camera enumeration failed: $e');
  }
  final ThemeController themeController = ThemeController();
  await themeController.load();

  runApp(GeoGuardApp(themeController: themeController));
}

class GeoGuardApp extends StatelessWidget {
  const GeoGuardApp({super.key, required this.themeController});

  final ThemeController themeController;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeController,
      builder: (BuildContext context, ThemeMode mode, _) => MaterialApp(
        title: 'GeoGuard',
        debugShowCheckedModeBanner: false,
        theme: Tokens.light(),
        darkTheme: Tokens.dark(),
        // Defaults to following the device; the toggle in the app bar lets the
        // user pin light or dark instead.
        themeMode: mode,
        home: AppShell(themeController: themeController),
      ),
    );
  }
}
