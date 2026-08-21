import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/device_service.dart';
import '../services/security_service.dart';
import '../theme/veripic_theme.dart';
import 'camera_screen.dart';
import 'verify_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
          children: <Widget>[
            const _Masthead(),
            const SizedBox(height: 26),
            const SectionHeader(icon: Icons.grid_view_rounded, title: 'Tools'),
            const SizedBox(height: 14),
            TileGroup(
              children: <Widget>[
                TintTile(
                  icon: Icons.photo_camera_outlined,
                  label: 'Capture signed photo',
                  supporting:
                      'Stamps GPS and UTC time, then seals it with a device-bound signature.',
                  tint: VP.primarySoft,
                  onTap: () {
                    HapticFeedback.mediumImpact();
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => const CameraScreen()),
                    );
                  },
                ),
                TintTile(
                  icon: Icons.fact_check_outlined,
                  label: 'Verify a photo',
                  supporting:
                      'Checks the signature, the stamp, and screens for AI generation.',
                  tint: VP.successSoft,
                  iconColor: VP.success,
                  onTap: () {
                    HapticFeedback.mediumImpact();
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                          builder: (_) => const VerifyScreen()),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 28),
            const SectionHeader(
                icon: Icons.smartphone_outlined, title: 'This device'),
            const SizedBox(height: 14),
            const _DeviceCard(),
          ],
        ),
      ),
    );
  }
}

class _Masthead extends StatelessWidget {
  const _Masthead();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: VP.primary,
            borderRadius: BorderRadius.circular(12),
          ),
          child: const Icon(Icons.verified_outlined,
              color: Colors.white, size: 24),
        ),
        const SizedBox(width: 14),
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('VeriPic', style: VP.h1),
              SizedBox(height: 2),
              Text(
                'Tamper-evident photo capture',
                style: TextStyle(fontSize: 13.5, color: VP.inkMuted),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Shows the hardware identity and the active signing key, with the full
/// attribute set available behind a disclosure.
class _DeviceCard extends StatefulWidget {
  const _DeviceCard();

  @override
  State<_DeviceCard> createState() => _DeviceCardState();
}

class _DeviceCardState extends State<_DeviceCard> {
  final DeviceService _device = DeviceService();
  final SecurityService _security = SecurityService();

  late final Future<_Identity> _future = _load();
  bool _expanded = false;

  Future<_Identity> _load() async {
    final DeviceFingerprint fp = await _device.resolve();
    final Map<String, String> keys = await _security.keyDiagnostics();
    return _Identity(fp, keys);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_Identity>(
      future: _future,
      builder: (BuildContext context, AsyncSnapshot<_Identity> snap) {
        final _Identity? id = snap.data;

        if (snap.hasError) {
          return AppCard(
            child: Text('Device identity unavailable: ${snap.error}',
                style: VP.body.copyWith(color: VP.warn)),
          );
        }

        if (id == null) {
          return const AppCard(
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 15,
                  height: 15,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: VP.inkFaint),
                ),
                SizedBox(width: 12),
                Text('Reading hardware identity…', style: VP.body),
              ],
            ),
          );
        }

        return AppCard(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(child: Text(id.fingerprint.label, style: VP.h2)),
                  Pill(
                    label: id.fingerprint.usedFallback ? 'Fallback' : 'Bound',
                    color:
                        id.fingerprint.usedFallback ? VP.warn : VP.success,
                    icon: id.fingerprint.usedFallback
                        ? Icons.info_outline_rounded
                        : Icons.lock_outline_rounded,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              KvRow(
                  label: 'Device hash',
                  value: id.fingerprint.shortId,
                  labelWidth: 96),
              KvRow(
                label: 'Signing key',
                value: id.keys['Active key id'] ?? '—',
                valueColor: VP.primaryInk,
                labelWidth: 96,
              ),
              AnimatedCrossFade(
                duration: const Duration(milliseconds: 200),
                crossFadeState: _expanded
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                firstChild: const SizedBox(width: double.infinity),
                secondChild: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Divider(height: 18, color: VP.divider),
                      for (final MapEntry<String, String> e
                          in id.fingerprint.attributes.entries)
                        KvRow(label: e.key, value: e.value),
                      const Divider(height: 18, color: VP.divider),
                      for (final MapEntry<String, String> e in id.keys.entries)
                        KvRow(label: e.key, value: e.value),
                    ],
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    setState(() => _expanded = !_expanded);
                  },
                  style: TextButton.styleFrom(
                    foregroundColor: VP.primary,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    minimumSize: const Size(0, 36),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(_expanded ? 'Hide details' : 'Show details',
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Identity {
  const _Identity(this.fingerprint, this.keys);
  final DeviceFingerprint fingerprint;
  final Map<String, String> keys;
}
