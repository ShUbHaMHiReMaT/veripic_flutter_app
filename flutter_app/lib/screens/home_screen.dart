import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/device_service.dart';
import '../services/security_service.dart';
import '../theme/veripic_theme.dart';
import 'camera_screen.dart';
import 'verify_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  void _open(BuildContext context, Widget screen) {
    HapticFeedback.mediumImpact();
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => screen),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        Tokens.spaceBase,
        Tokens.spaceTight,
        Tokens.spaceBase,
        Tokens.spaceSection,
      ),
      children: <Widget>[
        Text('Capture now.\nVerify anytime.', style: p.display),
        const SizedBox(height: Tokens.spaceSection),
        ActionButton(
          label: 'Open viewfinder',
          icon: Icons.photo_camera_outlined,
          onPressed: () => _open(context, const CameraScreen()),
        ),
        const SizedBox(height: Tokens.spaceSection),
        const SectionHead(title: 'Tools'),
        const SizedBox(height: Tokens.spaceSnug),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Expanded(
                child: TabCard(
                  icon: Icons.center_focus_strong_outlined,
                  tint: Tokens.statusOk,
                  title: 'Viewfinder',
                  meta: const <String>['stamp + sign'],
                  onTap: () => _open(context, const CameraScreen()),
                ),
              ),
              const SizedBox(width: Tokens.spaceSnug),
              Expanded(
                child: TabCard(
                  icon: Icons.fact_check_outlined,
                  tint: Tokens.tintInfo,
                  title: 'Check a frame',
                  meta: const <String>['4 checks'],
                  onTap: () => _open(context, const VerifyScreen()),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Tokens.spaceBase),
        const SectionHead(title: 'This device'),
        const SizedBox(height: Tokens.spaceSnug),
        const _DeviceCard(),
      ],
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
    final Palette p = Palette.of(context);
    return FutureBuilder<_Identity>(
      future: _future,
      builder: (BuildContext context, AsyncSnapshot<_Identity> snap) {
        if (snap.hasError) {
          return const ErrorState(
            message: 'Device identity could not be read. Restart the app to '
                'try again.',
          );
        }

        final _Identity? id = snap.data;
        if (id == null) {
          return const LoadingState(message: 'Reading hardware identity');
        }

        final bool fallback = id.fingerprint.usedFallback;

        return FieldCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  IconTile(
                    icon:
                        fallback ? Icons.key_off_outlined : Icons.key_outlined,
                    color: fallback ? Tokens.statusWarn : Tokens.statusOk,
                  ),
                  const SizedBox(width: Tokens.spaceSnug),
                  Expanded(
                    child: Text(
                      id.fingerprint.label,
                      style: p.cardTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  StatusBadge(
                    label: fallback ? 'fallback' : 'bound',
                    color: fallback ? Tokens.statusWarn : Tokens.statusOk,
                  ),
                ],
              ),
              const SizedBox(height: Tokens.spaceBase),
              DataLine(label: 'Device', value: id.fingerprint.shortId),
              DataLine(
                label: 'Signing key',
                value: id.keys['Active key id'] ?? '—',
              ),
              if (fallback) ...<Widget>[
                const SizedBox(height: Tokens.spaceSnug),
                AccentPanel(
                  accent: Tokens.statusWarn,
                  background: p.canvas,
                  child: Text(
                    'No hardware identifier available, so the key is bound to a '
                    'stored fallback. Frames signed here stay valid on this '
                    'install only.',
                    style: p.body,
                  ),
                ),
              ],
              AnimatedCrossFade(
                duration: Tokens.motion(context, Tokens.motionBase),
                crossFadeState: _expanded
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                firstChild: const SizedBox(width: double.infinity),
                secondChild: Padding(
                  padding: const EdgeInsets.only(top: Tokens.spaceSnug),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      for (final MapEntry<String, String> e
                          in id.fingerprint.attributes.entries)
                        DataLine(label: e.key, value: e.value),
                      for (final MapEntry<String, String> e in id.keys.entries)
                        DataLine(label: e.key, value: e.value),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: Tokens.spaceSnug),
              ActionButton(
                label: _expanded ? 'Hide details' : 'Show details',
                color: p.surfaceInset,
                expand: false,
                onPressed: () {
                  HapticFeedback.selectionClick();
                  setState(() => _expanded = !_expanded);
                },
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
