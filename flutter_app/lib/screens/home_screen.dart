import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/device_service.dart';
import '../services/identity_service.dart';
import '../services/security_service.dart';
import '../theme/veripic_theme.dart';
import 'camera_screen.dart';
import 'senders_screen.dart';
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
        Text('Take a photo.\nCheck it anytime.', style: p.display),
        const SizedBox(height: Tokens.spaceSection),
        ActionButton(
          label: 'Open camera',
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
                  icon: Icons.fact_check_outlined,
                  tint: Tokens.tintInfo,
                  title: 'Check a photo',
                  meta: const <String>['4 checks'],
                  onTap: () => _open(context, const VerifyScreen()),
                ),
              ),
              const SizedBox(width: Tokens.spaceSnug),
              Expanded(
                child: TabCard(
                  icon: Icons.people_outline,
                  tint: Tokens.statusOk,
                  title: 'Senders',
                  meta: const <String>['share code'],
                  onTap: () => _open(context, const SendersScreen()),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Tokens.spaceBase),
        const SectionHead(title: 'This phone'),
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
  final IdentityService _identity = IdentityService();

  late final Future<_Identity> _future = _load();
  bool _expanded = false;

  Future<_Identity> _load() async {
    final DeviceFingerprint fp = await _device.resolve();
    final Map<String, String> keys = await _security.keyDiagnostics();
    final PortableIdentity id = await _identity.identity();
    return _Identity(fp, keys, id);
  }

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);
    return FutureBuilder<_Identity>(
      future: _future,
      builder: (BuildContext context, AsyncSnapshot<_Identity> snap) {
        if (snap.hasError) {
          return const ErrorState(
            message: 'Your phone details could not be read. Restart the app '
                'to try again.',
          );
        }

        final _Identity? id = snap.data;
        if (id == null) {
          return const LoadingState(message: 'Reading phone details');
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
                    label: fallback ? 'backup' : 'secure',
                    color: fallback ? Tokens.statusWarn : Tokens.statusOk,
                  ),
                ],
              ),
              const SizedBox(height: Tokens.spaceBase),
              DataLine(label: 'Phone', value: id.fingerprint.shortId),
              DataLine(
                label: 'Your sharing code',
                value: id.portable.readableFingerprint,
              ),
              DataLine(
                label: 'Old local key',
                value: id.keys['Key id'] ?? '—',
              ),
              if (fallback) ...<Widget>[
                const SizedBox(height: Tokens.spaceSnug),
                AccentPanel(
                  accent: Tokens.statusWarn,
                  background: p.canvas,
                  child: Text(
                    'This phone has no ID we can use, so a backup key is saved '
                    'instead. Photos signed here stay valid only while the app '
                    'stays installed.',
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
  const _Identity(this.fingerprint, this.keys, this.portable);
  final DeviceFingerprint fingerprint;
  final Map<String, String> keys;

  /// The keypair that actually signs photos now, and whose public half every
  /// capture carries so other phones can check it.
  final PortableIdentity portable;
}
