import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../config.dart';
import '../services/account_service.dart';
import '../services/identity_service.dart';
import '../theme/veripic_theme.dart';

/// This phone's sharing identity, the senders the user has saved, and the
/// optional online directory that finds people by username.
///
/// Everything except the directory works with no account and no network. The
/// account only makes finding somebody easier — it never becomes the thing
/// that decides whether a photo is real.
class SendersScreen extends StatefulWidget {
  const SendersScreen({super.key});

  @override
  State<SendersScreen> createState() => _SendersScreenState();
}

class _SendersScreenState extends State<SendersScreen> {
  final IdentityService _identity = IdentityService();
  final AccountService _account = AccountService();

  late Future<_SenderData> _future = _load();
  bool _busy = false;
  String? _error;

  Future<_SenderData> _load() async {
    final PortableIdentity me = await _identity.identity();
    final List<TrustedContact> contacts = await _identity.contacts();
    // A failed restore must not stop the offline half of the screen loading.
    Account? account;
    try {
      account = await _account.restore();
    } catch (_) {
      account = null;
    }
    return _SenderData(me, contacts, account);
  }

  Future<void> _reload() async {
    setState(() => _future = _load());
    await _future;
  }

  /// Runs [action], showing its message instead of throwing at the user.
  Future<void> _guard(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on AccountException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _signIn() => _guard(() async {
        await _account.signIn();
        await _reload();
      });

  Future<void> _signOut() => _guard(() async {
        await _account.signOut();
        await _reload();
      });

  Future<void> _claimUsername() async {
    final String? name = await showDialog<String>(
      context: context,
      builder: (_) => const _UsernameDialog(),
    );
    if (name == null || name.trim().isEmpty) return;
    await _guard(() async {
      await _account.claimUsername(name);
      await _reload();
    });
  }

  Future<void> _publishCode() => _guard(() async {
        await _account.publishSharingCode();
        await _reload();
      });

  Future<void> _shareMyKey(PortableIdentity me, Account? account) async {
    HapticFeedback.selectionClick();
    final String who = account?.username != null
        ? 'My GeoGuard username is @${account!.username}.\n\n'
        : '';
    await SharePlus.instance.share(
      ShareParams(
        subject: 'My GeoGuard code',
        text: '${who}This is my GeoGuard code. Photos I take carry it, so your '
            'app can confirm they came from me and have not been edited.\n\n'
            '${me.readableFingerprint}',
      ),
    );
  }

  Future<void> _rename(TrustedContact contact) async {
    final String? name = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(
        title: 'Rename sender',
        initial: contact.name,
        fingerprint: contact.readableFingerprint,
      ),
    );
    if (name == null) return;
    await _identity.saveContact(publicKeyB64: contact.publicKey, name: name);
    await _reload();
  }

  Future<void> _remove(TrustedContact contact) async {
    HapticFeedback.mediumImpact();
    await _identity.removeContact(contact.fingerprint);
    await _reload();
  }

  Future<void> _findPeople() async {
    final DirectoryUser? picked = await showModalBottomSheet<DirectoryUser>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _SearchSheet(account: _account),
    );
    if (picked == null || !mounted) return;

    // The directory is a convenience, not an authority. If it hands back a key
    // that disagrees with one already saved under that name, say so instead of
    // quietly replacing it — silently accepting a swapped key is exactly how
    // an impostor gets through.
    final TrustedContact? clash = await _account.conflictFor(picked);
    if (clash != null && mounted) {
      final bool replace = await _confirmKeyChange(clash, picked) ?? false;
      if (!replace) return;
      await _identity.removeContact(clash.fingerprint);
    }

    await _guard(() async {
      await _account.saveFromDirectory(picked);
      await _reload();
    });
  }

  Future<bool?> _confirmKeyChange(TrustedContact saved, DirectoryUser found) {
    final Palette p = Palette.of(context);
    return showDialog<bool>(
      context: context,
      builder: (BuildContext context) => Dialog(
        backgroundColor: p.surface,
        shape: RoundedRectangleBorder(borderRadius: Tokens.brCard, side: p.side),
        child: Padding(
          padding: const EdgeInsets.all(Tokens.spaceBase),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const SectionHead(title: 'This code has changed'),
              const SizedBox(height: Tokens.spaceSnug),
              Text(
                'You already saved ${saved.name} with a different code. That '
                'happens when they reinstall the app — but it is also what it '
                'would look like if somebody were pretending to be them.\n\n'
                'Check the new code with them before you replace it.',
                style: p.body,
              ),
              const SizedBox(height: Tokens.spaceSnug),
              DataLine(label: 'Saved', value: saved.readableFingerprint),
              DataLine(label: 'Found', value: found.fingerprint.toUpperCase()),
              const SizedBox(height: Tokens.spaceBase),
              ActionButton(
                label: 'Replace it',
                color: Tokens.statusAlert,
                onPressed: () => Navigator.of(context).pop(true),
              ),
              const SizedBox(height: Tokens.spaceSnug),
              ActionButton(
                label: 'Keep the saved one',
                color: p.surfaceInset,
                onPressed: () => Navigator.of(context).pop(false),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Senders')),
      body: FutureBuilder<_SenderData>(
        future: _future,
        builder: (BuildContext context, AsyncSnapshot<_SenderData> snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Padding(
              padding: EdgeInsets.all(Tokens.spaceBase),
              child: LoadingState(message: 'Reading your code'),
            );
          }
          if (snap.hasError || snap.data == null) {
            return ErrorState(
              message: 'Your sharing code could not be read. Try again.',
              actionLabel: 'Try again',
              onAction: _reload,
            );
          }

          final _SenderData data = snap.data!;

          return ListView(
            padding: const EdgeInsets.fromLTRB(
              Tokens.spaceBase,
              Tokens.spaceTight,
              Tokens.spaceBase,
              Tokens.spaceScreen,
            ),
            children: <Widget>[
              if (_error != null) ...<Widget>[
                ErrorState(message: _error!),
                const SizedBox(height: Tokens.spaceSnug),
              ],
              const SectionHead(title: 'Your code'),
              const SizedBox(height: Tokens.spaceSnug),
              _MyCodeCard(
                identity: data.identity,
                account: data.account,
                busy: _busy,
                onShare: () => _shareMyKey(data.identity, data.account),
                onSignIn: _signIn,
                onSignOut: _signOut,
                onClaimUsername: _claimUsername,
                onPublish: _publishCode,
              ),
              const SizedBox(height: Tokens.spaceSection),
              SectionHead(title: '${data.contacts.length} saved'),
              const SizedBox(height: Tokens.spaceSnug),
              if (data.account != null) ...<Widget>[
                ActionButton(
                  label: 'Find someone by username',
                  icon: Icons.search,
                  color: Tokens.tintInfo,
                  onPressed: _busy ? null : _findPeople,
                ),
                const SizedBox(height: Tokens.spaceSnug),
              ],
              if (data.contacts.isEmpty)
                AccentPanel(
                  accent: Tokens.tintInfo,
                  background: p.canvas,
                  child: Text(
                    data.account == null
                        ? 'You have not saved anyone yet. Check a photo a '
                            'friend sent you, and the app will offer to save '
                            'them by name.'
                        : 'You have not saved anyone yet. Search for their '
                            'username above, or check a photo they sent you.',
                    style: p.body,
                  ),
                )
              else
                for (final TrustedContact c in data.contacts) ...<Widget>[
                  _ContactCard(
                    contact: c,
                    onRename: () => _rename(c),
                    onRemove: () => _remove(c),
                  ),
                  const SizedBox(height: Tokens.spaceSnug),
                ],
            ],
          );
        },
      ),
    );
  }
}

class _SenderData {
  const _SenderData(this.identity, this.contacts, this.account);
  final PortableIdentity identity;
  final List<TrustedContact> contacts;
  final Account? account;
}

// =======================================================================
// My code
// =======================================================================

class _MyCodeCard extends StatelessWidget {
  const _MyCodeCard({
    required this.identity,
    required this.account,
    required this.busy,
    required this.onShare,
    required this.onSignIn,
    required this.onSignOut,
    required this.onClaimUsername,
    required this.onPublish,
  });

  final PortableIdentity identity;
  final Account? account;
  final bool busy;
  final VoidCallback onShare;
  final VoidCallback onSignIn;
  final VoidCallback onSignOut;
  final VoidCallback onClaimUsername;
  final VoidCallback onPublish;

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);
    final Account? acc = account;
    final bool published = acc?.matchesLocalKey(identity.publicKeyB64) ?? false;

    return FieldCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const IconTile(icon: Icons.badge_outlined, color: Tokens.accent),
              const SizedBox(width: Tokens.spaceSnug),
              Expanded(
                child: Text(
                  acc?.username != null ? '@${acc!.username}' : 'This phone',
                  style: p.cardTitle,
                ),
              ),
              if (acc != null)
                StatusBadge(
                  label: published ? 'online' : 'not shared',
                  color: published ? Tokens.statusOk : Tokens.statusWarn,
                ),
            ],
          ),
          const SizedBox(height: Tokens.spaceBase),
          Text(
            'Every photo you take carries this code. Send it to a friend so '
            'they can be sure a photo really came from you.',
            style: p.body,
          ),
          const SizedBox(height: Tokens.spaceSnug),
          DataLine(label: 'Your code', value: identity.readableFingerprint),
          if (acc?.email != null)
            DataLine(label: 'Signed in as', value: acc!.email!),
          const SizedBox(height: Tokens.spaceSnug),
          ActionButton(
            label: 'Share my code',
            icon: Icons.ios_share,
            expand: false,
            onPressed: onShare,
          ),
          const SizedBox(height: Tokens.spaceSection),
          _AccountSection(
            account: acc,
            published: published,
            busy: busy,
            onSignIn: onSignIn,
            onSignOut: onSignOut,
            onClaimUsername: onClaimUsername,
            onPublish: onPublish,
          ),
        ],
      ),
    );
  }
}

/// The optional half: signing in so other people can find this code by name.
class _AccountSection extends StatelessWidget {
  const _AccountSection({
    required this.account,
    required this.published,
    required this.busy,
    required this.onSignIn,
    required this.onSignOut,
    required this.onClaimUsername,
    required this.onPublish,
  });

  final Account? account;
  final bool published;
  final bool busy;
  final VoidCallback onSignIn;
  final VoidCallback onSignOut;
  final VoidCallback onClaimUsername;
  final VoidCallback onPublish;

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);

    // Accounts were not configured at build time. Say so plainly instead of
    // showing a button that can only fail.
    if (!AppConfig.accountsEnabled) {
      return AccentPanel(
        accent: Tokens.tintNull,
        background: p.canvas,
        child: Text(
          'Accounts are switched off in this build, so nobody can look you up '
          'by name yet. Sharing your code by hand works exactly the same.',
          style: p.body,
        ),
      );
    }

    final Account? acc = account;
    if (acc == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Sign in to let friends find you by a username instead of reading '
            'this code out.',
            style: p.body,
          ),
          const SizedBox(height: Tokens.spaceSnug),
          ActionButton(
            label: busy ? 'Signing in' : 'Sign in with Google',
            icon: Icons.login,
            onPressed: busy ? null : onSignIn,
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (acc.needsUsername) ...<Widget>[
          Text(
            'Pick a username so people can find you.',
            style: p.body,
          ),
          const SizedBox(height: Tokens.spaceSnug),
          ActionButton(
            label: 'Pick a username',
            icon: Icons.alternate_email,
            onPressed: busy ? null : onClaimUsername,
          ),
          const SizedBox(height: Tokens.spaceSnug),
        ] else if (!published) ...<Widget>[
          AccentPanel(
            accent: Tokens.statusWarn,
            background: p.canvas,
            child: Text(
              'Your saved code is out of date — that happens after a '
              'reinstall. Share it again so people can still check your '
              'photos.',
              style: p.body,
            ),
          ),
          const SizedBox(height: Tokens.spaceSnug),
          ActionButton(
            label: 'Share my code online',
            icon: Icons.cloud_upload_outlined,
            onPressed: busy ? null : onPublish,
          ),
          const SizedBox(height: Tokens.spaceSnug),
        ],
        ActionButton(
          label: 'Sign out',
          color: p.surfaceInset,
          expand: false,
          onPressed: busy ? null : onSignOut,
        ),
      ],
    );
  }
}

// =======================================================================
// Search
// =======================================================================

class _SearchSheet extends StatefulWidget {
  const _SearchSheet({required this.account});

  final AccountService account;

  @override
  State<_SearchSheet> createState() => _SearchSheetState();
}

class _SearchSheetState extends State<_SearchSheet> {
  final TextEditingController _controller = TextEditingController();

  Timer? _debounce;
  List<DirectoryUser> _results = const <DirectoryUser>[];
  bool _searching = false;
  String? _error;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// Waits for a pause in typing before asking the server.
  ///
  /// A request per keystroke would hammer the rate limiter and return results
  /// out of order.
  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _run(value));
  }

  Future<void> _run(String query) async {
    if (query.trim().length < 2) {
      setState(() {
        _results = const <DirectoryUser>[];
        _error = null;
      });
      return;
    }

    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final List<DirectoryUser> found = await widget.account.search(query);
      if (mounted) setState(() => _results = found);
    } on AccountException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: p.surface,
          border: Border(top: p.side, left: p.side, right: p.side),
          borderRadius: const BorderRadius.vertical(
            top: Radius.circular(Tokens.radiusCard),
          ),
        ),
        child: SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(Tokens.spaceBase),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const SectionHead(title: 'Find someone'),
                const SizedBox(height: Tokens.spaceSnug),
                TextField(
                  controller: _controller,
                  autofocus: true,
                  style: p.body,
                  cursorColor: p.textPrimary,
                  onChanged: _onChanged,
                  decoration: InputDecoration(
                    hintText: 'username',
                    prefixText: '@',
                    isDense: true,
                    filled: true,
                    fillColor: p.surfaceInset,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: Tokens.spaceSnug,
                      vertical: Tokens.spaceSnug,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: Tokens.brControl,
                      borderSide: p.side,
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: Tokens.brControl,
                      borderSide: p.side,
                    ),
                    focusedBorder: const OutlineInputBorder(
                      borderRadius: Tokens.brControl,
                      borderSide: BorderSide(
                        color: Tokens.accent,
                        width: Tokens.borderWidth,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: Tokens.spaceBase),
                if (_error != null)
                  ErrorState(message: _error!)
                else if (_searching)
                  const LoadingState(message: 'Searching')
                else if (_results.isEmpty)
                  Text(
                    _controller.text.trim().length < 2
                        ? 'Type at least two letters.'
                        : 'Nobody found with that username.',
                    style: p.body,
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 320),
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: _results.length,
                      separatorBuilder: (_, __) =>
                          const SizedBox(height: Tokens.spaceTight),
                      itemBuilder: (BuildContext context, int i) {
                        final DirectoryUser u = _results[i];
                        return PressCard(
                          onTap: () => Navigator.of(context).pop(u),
                          padding: const EdgeInsets.all(Tokens.spaceSnug),
                          child: Row(
                            children: <Widget>[
                              const IconTile(
                                icon: Icons.person_outline,
                                color: Tokens.statusOk,
                                size: Tokens.tileSize - Tokens.spaceSnug,
                              ),
                              const SizedBox(width: Tokens.spaceSnug),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: <Widget>[
                                    Text('@${u.username}',
                                        style: p.cardTitle),
                                    const SizedBox(height: Tokens.spaceHair),
                                    Text(
                                      u.fingerprint.toUpperCase(),
                                      style: p.dataSmall,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                const SizedBox(height: Tokens.spaceBase),
                Text(
                  'Check the code shown here against the one in their app '
                  'before you trust it.',
                  style: p.dataSmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// =======================================================================
// Contacts
// =======================================================================

class _ContactCard extends StatelessWidget {
  const _ContactCard({
    required this.contact,
    required this.onRename,
    required this.onRemove,
  });

  final TrustedContact contact;
  final VoidCallback onRename;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);

    return FieldCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const IconTile(
                icon: Icons.person_outline,
                color: Tokens.statusOk,
              ),
              const SizedBox(width: Tokens.spaceSnug),
              Expanded(child: Text(contact.name, style: p.cardTitle)),
            ],
          ),
          const SizedBox(height: Tokens.spaceBase),
          DataLine(label: 'Their code', value: contact.readableFingerprint),
          const SizedBox(height: Tokens.spaceSnug),
          Row(
            children: <Widget>[
              ActionButton(
                label: 'Rename',
                color: p.surfaceInset,
                expand: false,
                onPressed: onRename,
              ),
              const SizedBox(width: Tokens.spaceSnug),
              ActionButton(
                label: 'Remove',
                color: Tokens.statusAlert,
                expand: false,
                onPressed: onRemove,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// =======================================================================
// Dialogs
// =======================================================================

class _UsernameDialog extends StatefulWidget {
  const _UsernameDialog();

  @override
  State<_UsernameDialog> createState() => _UsernameDialogState();
}

class _UsernameDialogState extends State<_UsernameDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);

    return Dialog(
      backgroundColor: p.surface,
      shape: RoundedRectangleBorder(borderRadius: Tokens.brCard, side: p.side),
      child: Padding(
        padding: const EdgeInsets.all(Tokens.spaceBase),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const SectionHead(title: 'Pick a username'),
            const SizedBox(height: Tokens.spaceSnug),
            Text(
              'This is how friends find you. 3 to 20 characters: letters, '
              'numbers and underscore.',
              style: p.body,
            ),
            const SizedBox(height: Tokens.spaceBase),
            TextField(
              controller: _controller,
              autofocus: true,
              style: p.body,
              cursorColor: p.textPrimary,
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9_]')),
                LengthLimitingTextInputFormatter(20),
              ],
              onSubmitted: (String v) => Navigator.of(context).pop(v),
              decoration: InputDecoration(
                prefixText: '@',
                isDense: true,
                filled: true,
                fillColor: p.surfaceInset,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: Tokens.spaceSnug,
                  vertical: Tokens.spaceSnug,
                ),
                border: OutlineInputBorder(
                  borderRadius: Tokens.brControl,
                  borderSide: p.side,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: Tokens.brControl,
                  borderSide: p.side,
                ),
                focusedBorder: const OutlineInputBorder(
                  borderRadius: Tokens.brControl,
                  borderSide: BorderSide(
                    color: Tokens.accent,
                    width: Tokens.borderWidth,
                  ),
                ),
              ),
            ),
            const SizedBox(height: Tokens.spaceBase),
            ActionButton(
              label: 'Save',
              icon: Icons.check,
              onPressed: () => Navigator.of(context).pop(_controller.text),
            ),
            const SizedBox(height: Tokens.spaceSnug),
            ActionButton(
              label: 'Cancel',
              color: p.surfaceInset,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}

/// Asks for the name to file a sender under.
class _NameDialog extends StatefulWidget {
  const _NameDialog({
    required this.title,
    required this.fingerprint,
    this.initial = '',
  });

  final String title;
  final String fingerprint;
  final String initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);

    return Dialog(
      backgroundColor: p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: Tokens.brCard,
        side: p.side,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(Tokens.spaceBase),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SectionHead(title: widget.title),
            const SizedBox(height: Tokens.spaceSnug),
            Text(
              'Check this code matches the one your friend shows you in their '
              'app, then give them a name.',
              style: p.body,
            ),
            const SizedBox(height: Tokens.spaceSnug),
            DataLine(label: 'Their code', value: widget.fingerprint),
            const SizedBox(height: Tokens.spaceBase),
            Text('Name', style: p.label),
            const SizedBox(height: Tokens.spaceHair),
            TextField(
              controller: _controller,
              style: p.body,
              autofocus: true,
              cursorColor: p.textPrimary,
              textCapitalization: TextCapitalization.words,
              onSubmitted: (String v) => Navigator.of(context).pop(v),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: p.surfaceInset,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: Tokens.spaceSnug,
                  vertical: Tokens.spaceSnug,
                ),
                border: OutlineInputBorder(
                  borderRadius: Tokens.brControl,
                  borderSide: p.side,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: Tokens.brControl,
                  borderSide: p.side,
                ),
                focusedBorder: const OutlineInputBorder(
                  borderRadius: Tokens.brControl,
                  borderSide: BorderSide(
                    color: Tokens.accent,
                    width: Tokens.borderWidth,
                  ),
                ),
              ),
            ),
            const SizedBox(height: Tokens.spaceBase),
            ActionButton(
              label: 'Save',
              icon: Icons.person_add_alt,
              onPressed: () => Navigator.of(context).pop(_controller.text),
            ),
            const SizedBox(height: Tokens.spaceSnug),
            ActionButton(
              label: 'Cancel',
              color: p.surfaceInset,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
    );
  }
}

/// Shown from the check screen when a valid photo arrives from a key this
/// phone has never seen.
Future<TrustedContact?> promptSaveSender(
  BuildContext context, {
  required String publicKeyB64,
}) async {
  final String fingerprint = TrustedContact(
    fingerprint: IdentityService.fingerprintOf(publicKeyB64),
    name: '',
    publicKey: publicKeyB64,
    savedAtMs: 0,
  ).readableFingerprint;

  final String? name = await showDialog<String>(
    context: context,
    builder: (_) => _NameDialog(
      title: 'Save this sender',
      fingerprint: fingerprint,
    ),
  );
  if (name == null) return null;

  return IdentityService().saveContact(
    publicKeyB64: publicKeyB64,
    name: name,
  );
}
