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
          padding: const EdgeInsets.fromLTRB(VP.s16, VP.s24, VP.s16, VP.s32),
          children: <Widget>[
            const Text('VeriPic', style: VP.screenTitle),
            const SizedBox(height: VP.s4),
            const Text(
              'Every frame is stamped, signed, and checkable.',
              style: VP.body,
            ),
            const SizedBox(height: VP.s32),
            const SectionHead(title: 'Capture'),
            const SizedBox(height: VP.s12),
            LogRow(
              title: 'Open viewfinder',
              lines: const <String>['STAMP + SIGN + LOG'],
              onTap: () {
                HapticFeedback.mediumImpact();
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                      builder: (_) => const CameraScreen()),
                );
              },
            ),
            const SizedBox(height: VP.s8),
            LogRow(
              title: 'Check a frame',
              lines: const <String>['PAYLOAD + HMAC + DRIFT + AI'],
              onTap: () {
                HapticFeedback.mediumImpact();
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                      builder: (_) => const VerifyScreen()),
                );
              },
            ),
            const SizedBox(height: VP.s32),
            const SectionHead(title: 'This device'),
            const SizedBox(height: VP.s12),
            const _DeviceCard(),
          ],
        ),
      ),
    );
  }
}

/// Hardware identity and the active signing key, with the full attribute set
/// behind a disclosure.
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
          return const AccentPanel(
            accent: VP.signal,
            child: Text(
              'Device identity could not be read. Restart the app to retry.',
              style: VP.body,
            ),
          );
        }

        if (id == null) {
          return const FieldCard(
            child: Text('Reading hardware identity', style: VP.body),
          );
        }

        final bool fallback = id.fingerprint.usedFallback;

        return FieldCard(
          padding: const EdgeInsets.fromLTRB(VP.s16, VP.s16, VP.s16, VP.s8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(id.fingerprint.label.toUpperCase(),
                        style: VP.label.copyWith(color: VP.ink)),
                  ),
                  StatusText(
                    text: fallback ? 'KEY FALLBACK' : 'KEY BOUND',
                    color: fallback ? VP.signal : VP.forest,
                  ),
                ],
              ),
              const SizedBox(height: VP.s12),
              DataLine(label: 'Device', value: id.fingerprint.shortId),
              DataLine(
                label: 'Signing key',
                value: id.keys['Active key id'] ?? '—',
              ),
              if (fallback) ...<Widget>[
                const SizedBox(height: VP.s8),
                AccentPanel(
                  accent: VP.signal,
                  background: VP.sand,
                  child: Text(
                    'No hardware identifier available, so the key is bound to a '
                    'stored fallback. Frames signed here stay valid on this '
                    'install only.',
                    style: VP.body.copyWith(fontSize: 13),
                  ),
                ),
              ],
              AnimatedCrossFade(
                duration: const Duration(milliseconds: 180),
                crossFadeState: _expanded
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                firstChild: const SizedBox(width: double.infinity),
                secondChild: Padding(
                  padding: const EdgeInsets.only(top: VP.s8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Divider(height: VP.s16, color: VP.rule),
                      for (final MapEntry<String, String> e
                          in id.fingerprint.attributes.entries)
                        DataLine(label: e.key, value: e.value),
                      const Divider(height: VP.s16, color: VP.rule),
                      for (final MapEntry<String, String> e in id.keys.entries)
                        DataLine(label: e.key, value: e.value),
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
                    foregroundColor: VP.forest,
                    padding: const EdgeInsets.symmetric(horizontal: VP.s4),
                    minimumSize: const Size(0, VP.minTouch),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    _expanded ? 'Hide details' : 'Show details',
                    style: VP.label.copyWith(color: VP.forest),
                  ),
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
