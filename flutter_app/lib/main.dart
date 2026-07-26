import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'screens/home_screen.dart';

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
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF00E5A8),
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: 'VeriPic',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFF0A0F14),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0A0F14),
          elevation: 0,
        ),
      ),
      home: const HomeScreen(),
    );
  }
}
