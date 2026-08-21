import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'screens/home_screen.dart';
import 'theme/veripic_theme.dart';

List<CameraDescription> cameras = <CameraDescription>[];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {
    // .env is optional at runtime; services fall back to safe defaults.
  }
  try {
    cameras = await availableCameras();
  } catch (e) {
    debugPrint('Camera enumeration failed: $e');
  }
  runApp(const VeriPicApp());
}

class VeriPicApp extends StatelessWidget {
  const VeriPicApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VeriPic',
      debugShowCheckedModeBanner: false,
      theme: Tokens.light(),
      darkTheme: Tokens.dark(),
      // Follow the system. Light remains the default when the system expresses
      // no preference, because the app is used outdoors.
      themeMode: ThemeMode.system,
      home: const HomeScreen(),
    );
  }
}
