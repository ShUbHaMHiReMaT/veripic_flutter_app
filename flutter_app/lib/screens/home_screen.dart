import 'package:flutter/material.dart';

import '../services/device_service.dart';
import 'camera_screen.dart';
import 'verify_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final DeviceService _deviceService = DeviceService();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const SizedBox(height: 24),
              const Text('VeriPic',
                  style: TextStyle(fontSize: 34, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
              const SizedBox(height: 4),
              Text('Tamper-proof geotagged camera',
                  style: TextStyle(color: Colors.white.withOpacity(0.6))),
              const Spacer(),
              _Tile(
                icon: Icons.camera_alt_rounded,
                title: 'Capture Signed Photo',
                subtitle: 'GPS + UTC + HMAC + Steganography',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const CameraScreen()),
                ),
              ),
              const SizedBox(height: 16),
              _Tile(
                icon: Icons.verified_user_rounded,
                title: 'Verify Photo',
                subtitle: 'Check integrity & deepfake score',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(builder: (_) => const VerifyScreen()),
                ),
              ),
              const Spacer(),
              Center(
                child: Text('v1.0 · HMAC-SHA256 · LSB · NVIDIA Vision',
                    style: TextStyle(color: Colors.white.withOpacity(0.35), fontSize: 12)),
              ),
              const SizedBox(height: 6),
              Center(
                child: FutureBuilder<String>(
                  future: _deviceService.fingerprint(),
                  builder: (BuildContext context, AsyncSnapshot<String> snap) {
                    final String id = snap.data == null
                        ? 'resolving device hash…'
                        : 'device hash · ${snap.data!.substring(0, 16)}';
                    return Text(id,
                        style: TextStyle(
                            color: Colors.white.withOpacity(0.3),
                            fontSize: 11,
                            fontFamily: 'monospace'));
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.icon, required this.title, required this.subtitle, required this.onTap});
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF121A22),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: <Widget>[
              Container(
                width: 52, height: 52,
                decoration: BoxDecoration(
                  color: const Color(0xFF00E5A8).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: const Color(0xFF00E5A8)),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(subtitle, style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 13)),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: Colors.white54),
            ],
          ),
        ),
      ),
    );
  }
}
