import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import '../services/account_service.dart';
import '../services/device_service.dart';
import '../services/identity_service.dart';
import '../services/payment_service.dart';
import '../services/security_service.dart';
import '../services/update_service.dart';
import '../theme/veripic_theme.dart';
import 'camera_screen.dart';
import 'inbox_screen.dart';
import 'paywall.dart';
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
        const _UpdateBanner(),
        Text('Take a photo.\nCheck it anytime.', style: p.display),
        const SizedBox(height: Tokens.spaceSection),
        ActionButton(
          label: 'Open camera',
          icon: Icons.photo_camera_outlined,
          onPressed: () => _open(context, const CameraScreen()),
        ),
        const SizedBox(height: Tokens.spaceSection),
        const _AccountBanner(),
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
        // Only reachable with an account: a locked photo has to be addressed
        // to somebody, so there is nothing to show when signed out.
        if (AppConfig.accountsEnabled) ...<Widget>[
          const SizedBox(height: Tokens.spaceSnug),
          ValueListenableBuilder<Account?>(
            valueListenable: AccountService.current,
            builder: (BuildContext context, Account? account, _) {
              if (account == null) return const SizedBox.shrink();
              return TabCard(
                icon: Icons.inbox_outlined,
                tint: Tokens.tintCool,
                title: 'Sent to you',
                meta: const <String>['locked photos'],
                onTap: () => _open(context, const InboxScreen()),
              );
            },
          ),
        ],
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

/// Who is signed in and whether they have Pro, on the first screen.
///
/// It also has to explain *why* there is no account when accounts were not
/// configured at build time. Silently hiding the feature is what made it look
/// like sign-in had never been built.
class _AccountBanner extends StatelessWidget {
  const _AccountBanner();

  void _openSenders(BuildContext context) {
    HapticFeedback.mediumImpact();
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const SendersScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);

    if (!AppConfig.accountsEnabled) {
      return AccentPanel(
        accent: Tokens.statusWarn,
        background: p.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Google sign-in is off in this build', style: p.cardTitle),
            const SizedBox(height: Tokens.spaceTight),
            Text(
              'The app was built without a Google client id, so there is '
              'nothing to sign in to yet. Everything else works: take photos, '
              'check them, and share your code by hand.',
              style: p.body,
            ),
            const SizedBox(height: Tokens.spaceTight),
            Text(AppConfig.setupHint, style: p.dataSmall),
          ],
        ),
      );
    }

    // The gate in front of the app guarantees an account by the time this
    // builds; listening keeps the Pro badge current after a payment.
    return ValueListenableBuilder<Account?>(
      valueListenable: AccountService.current,
      builder: (BuildContext context, Account? account, _) {
        if (account == null) return const SizedBox.shrink();

        final bool pro = account.isPro;
        final String plan = account.isAdmin
            ? 'ADMIN — ALL FEATURES'
            : pro
                ? 'PRO UNTIL ${_date(account.proUntil!)}'
                : 'FREE — CHECKING PHOTOS NEEDS PRO';

        return FieldCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Semantics(
                button: true,
                label: 'Your account',
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _openSenders(context),
                  child: Row(
                    children: <Widget>[
                      const IconTile(
                          icon: Icons.person, color: Tokens.statusOk),
                      const SizedBox(width: Tokens.spaceSnug),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            Text('@${account.username ?? ''}',
                                style: p.cardTitle),
                            const SizedBox(height: Tokens.spaceHair),
                            Text(plan, style: p.dataSmall),
                          ],
                        ),
                      ),
                      StatusBadge(
                        label: pro ? 'pro' : 'free',
                        color: pro ? Tokens.accent : Tokens.tintNull,
                      ),
                    ],
                  ),
                ),
              ),
              if (!account.isAdmin) ...<Widget>[
                const SizedBox(height: Tokens.spaceSnug),
                ActionButton(
                  label: pro
                      ? 'Add ${Plans.proDays} days for Rs ${Plans.proRupees}'
                      : 'Get Pro for Rs ${Plans.proRupees}',
                  icon: Icons.lock_open_outlined,
                  color: pro ? p.surfaceInset : Tokens.accent,
                  onPressed: () => Paywall.buyPro(context),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  static String _date(DateTime d) =>
      DateFormat('ddMMMyy').format(d).toUpperCase();
}

/// Tells the user a newer GeoGuard has been published, and links to it.
///
/// Takes no space at all when the app is up to date or the check fails.
class _UpdateBanner extends StatefulWidget {
  const _UpdateBanner();

  @override
  State<_UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<_UpdateBanner> {
  late final Future<AvailableUpdate?> _future = UpdateService().check();

  Future<void> _download(AvailableUpdate update) async {
    HapticFeedback.mediumImpact();
    final bool opened =
        await launchUrl(update.url, mode: LaunchMode.externalApplication);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
            SnackBar(content: Text('Open ${update.url} to update.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);
    return FutureBuilder<AvailableUpdate?>(
      future: _future,
      builder: (BuildContext context, AsyncSnapshot<AvailableUpdate?> snap) {
        final AvailableUpdate? update = snap.data;
        if (update == null) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.only(bottom: Tokens.spaceSection),
          child: AccentPanel(
            accent: Tokens.accent,
            background: p.surface,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text('Update available', style: p.cardTitle),
                    ),
                    StatusBadge(
                      label: 'v${update.version}',
                      color: Tokens.accent,
                    ),
                  ],
                ),
                if (update.notes != null) ...<Widget>[
                  const SizedBox(height: Tokens.spaceTight),
                  Text(update.notes!, style: p.body),
                ],
                const SizedBox(height: Tokens.spaceTight),
                Text(
                  'Open the downloaded file and tap Update. Your photos and '
                  'sign-in stay.',
                  style: p.body,
                ),
                const SizedBox(height: Tokens.spaceSnug),
                ActionButton(
                  label: 'Download update',
                  icon: Icons.download_outlined,
                  onPressed: () => _download(update),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
