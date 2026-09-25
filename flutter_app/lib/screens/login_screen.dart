import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/account_service.dart';
import '../theme/veripic_theme.dart';

/// First screen for anyone who is not signed in.
///
/// Everyone signs in with Google. Below that, folded away, is the password
/// form for the single admin account the server is configured with.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final AccountService _account = AccountService();
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();

  bool _busy = false;
  bool _showPassword = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  /// Runs a sign-in, showing its message instead of throwing at the user.
  ///
  /// On success there is nothing to do here: the account notifier changes and
  /// the gate above this screen swaps in the next one.
  Future<void> _run(Future<void> Function() signIn) async {
    HapticFeedback.mediumImpact();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await signIn();
    } on AccountException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _google() => _run(() => _account.signIn());

  void _withPassword() {
    if (_username.text.trim().isEmpty || _password.text.isEmpty) {
      setState(() => _error = 'Enter the username and the password.');
      return;
    }
    _run(() => _account.signInWithPassword(
          username: _username.text,
          password: _password.text,
        ));
  }

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);

    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            Tokens.spaceBase,
            Tokens.spaceScreen,
            Tokens.spaceBase,
            Tokens.spaceScreen,
          ),
          children: <Widget>[
            const Row(
              children: <Widget>[
                IconTile(icon: Icons.verified_outlined, color: Tokens.accent),
                SizedBox(width: Tokens.spaceSnug),
                Expanded(child: SectionHead(title: 'GeoGuard')),
              ],
            ),
            const SizedBox(height: Tokens.spaceSection),
            Text('Take a photo.\nCheck it anytime.', style: p.display),
            const SizedBox(height: Tokens.spaceSnug),
            Text(
              'Sign in to get a username, so friends can find you and send you '
              'photos that keep their proof.',
              style: p.body,
            ),
            const SizedBox(height: Tokens.spaceSection),
            if (_error != null) ...<Widget>[
              ErrorState(message: _error!),
              const SizedBox(height: Tokens.spaceSnug),
            ],
            ActionButton(
              label: _busy && !_showPassword
                  ? 'Signing in'
                  : 'Sign in with Google',
              icon: Icons.login,
              onPressed: _busy ? null : _google,
            ),
            const SizedBox(height: Tokens.spaceSection),
            FieldCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Semantics(
                    button: true,
                    expanded: _showPassword,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        HapticFeedback.selectionClick();
                        setState(() => _showPassword = !_showPassword);
                      },
                      child: ConstrainedBox(
                        constraints:
                            const BoxConstraints(minHeight: Tokens.touchMin),
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                'Sign in with a password',
                                style: p.cardTitle,
                              ),
                            ),
                            Icon(
                              _showPassword
                                  ? Icons.expand_less
                                  : Icons.expand_more,
                              size: Tokens.iconBase,
                              color: p.textPrimary,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  if (_showPassword) ...<Widget>[
                    const SizedBox(height: Tokens.spaceSnug),
                    Text(
                      'For the admin account only. Everyone else signs in '
                      'with Google.',
                      style: p.body,
                    ),
                    const SizedBox(height: Tokens.spaceBase),
                    Text('Username', style: p.label),
                    const SizedBox(height: Tokens.spaceHair),
                    GeoInput(
                      controller: _username,
                      prefix: '@',
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: Tokens.spaceSnug),
                    Text('Password', style: p.label),
                    const SizedBox(height: Tokens.spaceHair),
                    GeoInput(
                      controller: _password,
                      obscure: true,
                      onSubmitted: (_) => _withPassword(),
                    ),
                    const SizedBox(height: Tokens.spaceBase),
                    ActionButton(
                      label: _busy ? 'Signing in' : 'Sign in',
                      icon: Icons.key_outlined,
                      color: Tokens.tintInfo,
                      onPressed: _busy ? null : _withPassword,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Second step for a new account: pick the username friends will search for.
///
/// Checks availability while typing, but only as a hint — the server's unique
/// index decides who actually gets a name, so a race between two people is
/// still answered correctly when they press save.
class UsernameScreen extends StatefulWidget {
  const UsernameScreen({super.key});

  @override
  State<UsernameScreen> createState() => _UsernameScreenState();
}

enum _NameState { empty, checking, free, problem }

class _UsernameScreenState extends State<UsernameScreen> {
  final AccountService _account = AccountService();
  final TextEditingController _controller = TextEditingController();

  static final RegExp _valid = RegExp(r'^[a-z0-9_]{3,20}$');

  Timer? _debounce;
  _NameState _state = _NameState.empty;
  String? _problem;
  bool _saving = false;

  /// Guards against an older check landing after a newer one.
  int _checkId = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    final String name = value.trim().toLowerCase();

    if (name.isEmpty) {
      setState(() {
        _state = _NameState.empty;
        _problem = null;
      });
      return;
    }
    if (!_valid.hasMatch(name)) {
      setState(() {
        _state = _NameState.problem;
        _problem = name.length < 3
            ? 'At least 3 characters.'
            : 'Letters, numbers and underscore only.';
      });
      return;
    }

    setState(() {
      _state = _NameState.checking;
      _problem = null;
    });
    _debounce = Timer(const Duration(milliseconds: 400), () => _check(name));
  }

  Future<void> _check(String name) async {
    final int id = ++_checkId;
    try {
      final String? problem = await _account.usernameProblem(name);
      if (!mounted || id != _checkId) return;
      setState(() {
        _state = problem == null ? _NameState.free : _NameState.problem;
        _problem = problem;
      });
    } on AccountException catch (e) {
      if (!mounted || id != _checkId) return;
      setState(() {
        _state = _NameState.problem;
        _problem = e.message;
      });
    }
  }

  Future<void> _save() async {
    HapticFeedback.mediumImpact();
    setState(() => _saving = true);
    try {
      // On success the account now has a username, and the gate moves on.
      await _account.claimUsername(_controller.text.trim().toLowerCase());
    } on AccountException catch (e) {
      if (mounted) {
        setState(() {
          _state = _NameState.problem;
          _problem = e.message;
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);
    final Account? account = AccountService.current.value;

    final (String status, Color tint) = switch (_state) {
      _NameState.empty => ('3 to 20 characters', Tokens.tintNull),
      _NameState.checking => ('checking', Tokens.tintNull),
      _NameState.free => ('available', Tokens.statusOk),
      _NameState.problem => ('not available', Tokens.statusAlert),
    };

    return Scaffold(
      appBar: AppBar(title: const Text('Pick a username')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          Tokens.spaceBase,
          Tokens.spaceTight,
          Tokens.spaceBase,
          Tokens.spaceScreen,
        ),
        children: <Widget>[
          Text(
            'This is how friends find you and send you photos. Nobody else '
            'can have the same one, and it cannot be changed later.',
            style: p.body,
          ),
          if (account?.email != null) ...<Widget>[
            const SizedBox(height: Tokens.spaceSnug),
            DataLine(label: 'Signed in as', value: account!.email!),
          ],
          const SizedBox(height: Tokens.spaceSection),
          GeoInput(
            controller: _controller,
            prefix: '@',
            autofocus: true,
            formatters: <TextInputFormatter>[
              FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9_]')),
              LengthLimitingTextInputFormatter(20),
            ],
            onChanged: _onChanged,
            onSubmitted: (_) {
              if (_state == _NameState.free && !_saving) _save();
            },
          ),
          const SizedBox(height: Tokens.spaceSnug),
          Row(
            children: <Widget>[
              StatusBadge(label: status, color: tint),
              if (_problem != null) ...<Widget>[
                const SizedBox(width: Tokens.spaceTight),
                Expanded(child: Text(_problem!, style: p.dataSmall)),
              ],
            ],
          ),
          const SizedBox(height: Tokens.spaceSection),
          ActionButton(
            label: _saving ? 'Saving' : 'Save username',
            icon: Icons.alternate_email,
            onPressed: _state == _NameState.free && !_saving ? _save : null,
          ),
          const SizedBox(height: Tokens.spaceSnug),
          ActionButton(
            label: 'Use a different account',
            color: p.surfaceInset,
            onPressed: _saving ? null : () => _account.signOut(),
          ),
        ],
      ),
    );
  }
}

/// Text input in the design system's style: inset fill, outline, accent
/// outline on focus.
class GeoInput extends StatelessWidget {
  const GeoInput({
    super.key,
    required this.controller,
    this.prefix,
    this.obscure = false,
    this.autofocus = false,
    this.formatters,
    this.textInputAction,
    this.onChanged,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final String? prefix;
  final bool obscure;
  final bool autofocus;
  final List<TextInputFormatter>? formatters;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);

    return TextField(
      controller: controller,
      obscureText: obscure,
      autofocus: autofocus,
      autocorrect: false,
      enableSuggestions: !obscure,
      style: p.body,
      cursorColor: p.textPrimary,
      inputFormatters: formatters,
      textInputAction: textInputAction,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(
        prefixText: prefix,
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
    );
  }
}
