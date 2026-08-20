import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/device_service.dart';
import '../services/security_service.dart';
import '../theme/veripic_theme.dart';
import 'camera_screen.dart';
import 'verify_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ForensicBackdrop(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
            children: <Widget>[
              const _Masthead(),
              const SizedBox(height: 26),
              _ActionCard(
                icon: Icons.camera_alt_rounded,
                accent: VP.accent,
                code: 'CAPTURE',
                title: 'Capture Signed Photo',
                subtitle:
                    'Burns a GPS + UTC stamp, then binds it with a hardware-derived '
                    'HMAC-SHA256 signature.',
                tags: const <String>['GPS', 'UTC', 'HKDF', 'dHash-64'],
                onTap: () {
                  HapticFeedback.mediumImpact();
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        builder: (_) => const CameraScreen()),
                  );
                },
              ),
              const SizedBox(height: 14),
              _ActionCard(
                icon: Icons.fingerprint_rounded,
                accent: VP.info,
                code: 'ANALYZE',
                title: 'Verify Photo',
                subtitle:
                    'Runs the four-stage forensic pipeline: payload recovery, HMAC, '
                    'perceptual drift and AI-synthesis screening.',
                tags: const <String>['EXIF/COM', 'HMAC', 'HAMMING', 'NVIDIA'],
                onTap: () {
                  HapticFeedback.mediumImpact();
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(
                        builder: (_) => const VerifyScreen()),
                  );
                },
              ),
              const SizedBox(height: 22),
              const _IdentityPanel(),
              const SizedBox(height: 18),
              Center(
                child: Text(
                  'VeriPic v1.0  ·  HKDF-SHA256  ·  HMAC-SHA256  ·  dHash-64',
                  style: VP.eyebrow.copyWith(letterSpacing: 1.0),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Masthead extends StatelessWidget {
  const _Masthead();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: <Color>[VP.accent, VP.accentDim],
                ),
                boxShadow: VP.glow(VP.accent, strength: 0.8),
              ),
              child: const Icon(Icons.verified_user_rounded,
                  color: Color(0xFF00110B), size: 25),
            ),
            const SizedBox(width: 13),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text('VeriPic', style: VP.display),
                  const SizedBox(height: 2),
                  Text('Tamper-evident geotagged imaging',
                      style: VP.body.copyWith(fontSize: 13)),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        const Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            StatusChip(
                label: 'CHAIN OF CUSTODY',
                icon: Icons.link_rounded,
                dense: true),
            StatusChip(
                label: 'HARDWARE BOUND',
                icon: Icons.memory_rounded,
                color: VP.info,
                dense: true),
            StatusChip(
                label: 'OFFLINE CAPABLE',
                icon: Icons.cloud_off_rounded,
                color: VP.textSecondary,
                dense: true),
          ],
        ),
      ],
    );
  }
}

class _ActionCard extends StatefulWidget {
  const _ActionCard({
    required this.icon,
    required this.accent,
    required this.code,
    required this.title,
    required this.subtitle,
    required this.tags,
    required this.onTap,
  });

  final IconData icon;
  final Color accent;
  final String code;
  final String title;
  final String subtitle;
  final List<String> tags;
  final VoidCallback onTap;

  @override
  State<_ActionCard> createState() => _ActionCardState();
}

class _ActionCardState extends State<_ActionCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _pressed = true),
      onTapCancel: () => setState(() => _pressed = false),
      onTapUp: (_) => setState(() => _pressed = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _pressed ? 0.975 : 1,
        duration: const Duration(milliseconds: 130),
        curve: Curves.easeOut,
        child: GlassPanel(
          padding: const EdgeInsets.all(18),
          borderColor: widget.accent.withValues(alpha: _pressed ? 0.55 : 0.22),
          glowColor: _pressed ? widget.accent : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: widget.accent.withValues(alpha: 0.13),
                      borderRadius: BorderRadius.circular(14),
                      border:
                          Border.all(color: widget.accent.withValues(alpha: 0.3)),
                    ),
                    child: Icon(widget.icon, color: widget.accent, size: 23),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(widget.code,
                            style: VP.eyebrow
                                .copyWith(color: widget.accent.withValues(alpha: 0.8))),
                        const SizedBox(height: 3),
                        Text(widget.title, style: VP.title),
                      ],
                    ),
                  ),
                  Icon(Icons.arrow_outward_rounded,
                      color: widget.accent.withValues(alpha: 0.7), size: 19),
                ],
              ),
              const SizedBox(height: 12),
              Text(widget.subtitle, style: VP.body),
              const SizedBox(height: 14),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: widget.tags
                    .map((String t) => Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.04),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: VP.hairline),
                          ),
                          child: Text(t,
                              style: const TextStyle(
                                fontFamily: VP.mono,
                                fontSize: 10,
                                color: VP.textSecondary,
                                letterSpacing: 0.5,
                              )),
                        ))
                    .toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shows the hardware identity this device signs with, and — on expand — the
/// full attribute set plus HKDF parameters.
class _IdentityPanel extends StatefulWidget {
  const _IdentityPanel();

  @override
  State<_IdentityPanel> createState() => _IdentityPanelState();
}

class _IdentityPanelState extends State<_IdentityPanel> {
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
        final bool loading = !snap.hasData && !snap.hasError;

        return GlassPanel(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  const Icon(Icons.memory_rounded,
                      size: 15, color: VP.textFaint),
                  const SizedBox(width: 7),
                  const Text('DEVICE IDENTITY', style: VP.eyebrow),
                  const Spacer(),
                  if (loading)
                    const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(
                          strokeWidth: 1.6, color: VP.textFaint),
                    )
                  else if (id != null)
                    StatusChip(
                      label: id.fingerprint.usedFallback ? 'FALLBACK' : 'BOUND',
                      color:
                          id.fingerprint.usedFallback ? VP.warn : VP.accent,
                      dense: true,
                    ),
                ],
              ),
              const SizedBox(height: 12),
              if (snap.hasError)
                Text('Identity unavailable: ${snap.error}',
                    style: VP.body.copyWith(color: VP.warn))
              else if (id != null) ...<Widget>[
                Text(id.fingerprint.label,
                    style: VP.title.copyWith(fontSize: 14.5)),
                const SizedBox(height: 8),
                _KeyLine(
                    label: 'Device hash', value: '${id.fingerprint.shortId}…'),
                _KeyLine(
                    label: 'Signing key',
                    value: id.keys['Active key id'] ?? '—',
                    color: VP.accent),
                AnimatedCrossFade(
                  duration: const Duration(milliseconds: 220),
                  crossFadeState: _expanded
                      ? CrossFadeState.showSecond
                      : CrossFadeState.showFirst,
                  firstChild: const SizedBox(width: double.infinity),
                  secondChild: Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Divider(color: VP.hairline, height: 18),
                        for (final MapEntry<String, String> e
                            in id.fingerprint.attributes.entries)
                          DataRow2(label: e.key, value: e.value),
                        const Divider(color: VP.hairline, height: 18),
                        for (final MapEntry<String, String> e
                            in id.keys.entries)
                          DataRow2(label: e.key, value: e.value),
                      ],
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () {
                      HapticFeedback.selectionClick();
                      setState(() => _expanded = !_expanded);
                    },
                    style: TextButton.styleFrom(
                      foregroundColor: VP.textSecondary,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      minimumSize: const Size(0, 34),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    icon: Icon(
                        _expanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        size: 18),
                    label: Text(_expanded ? 'Hide details' : 'Show details',
                        style: const TextStyle(fontSize: 12.5)),
                  ),
                ),
              ] else
                const Text('Resolving hardware fingerprint…', style: VP.body),
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

class _KeyLine extends StatelessWidget {
  const _KeyLine({required this.label, required this.value, this.color});
  final String label;
  final String value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 92,
            child: Text(label,
                style: const TextStyle(color: VP.textFaint, fontSize: 12)),
          ),
          Expanded(
            child: Text(value,
                style: VP.monoSmall.copyWith(color: color ?? VP.textPrimary),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }
}
