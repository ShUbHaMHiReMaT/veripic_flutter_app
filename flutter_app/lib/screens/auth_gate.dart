import 'package:flutter/material.dart';

import '../config.dart';
import '../services/account_service.dart';
import '../theme/theme_controller.dart';
import '../theme/veripic_theme.dart';
import 'app_shell.dart';
import 'login_screen.dart';

/// Decides what the app opens on: the login page, the username picker, or
/// the app itself.
///
/// Follows [AccountService.current], so signing in, picking a username,
/// signing out or a session the server rejects all move the user to the right
/// screen without any caller having to navigate.
class AuthGate extends StatefulWidget {
  const AuthGate({super.key, required this.themeController});

  final ThemeController themeController;

  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  late final Future<Account?> _restore =
      AccountService().restore().catchError((Object _) => null);

  @override
  void initState() {
    super.initState();
    AccountService.current.addListener(_onAccountChanged);
  }

  @override
  void dispose() {
    AccountService.current.removeListener(_onAccountChanged);
    super.dispose();
  }

  /// Signing out from a screen pushed over the shell — Senders, say — would
  /// otherwise swap the login page in *underneath* it. Clearing the stack
  /// puts the login page in front.
  void _onAccountChanged() {
    if (AccountService.current.value != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).popUntil((Route<dynamic> r) => r.isFirst);
    });
  }

  @override
  Widget build(BuildContext context) {
    final Widget shell = AppShell(themeController: widget.themeController);

    // Built without a server or a Google client id: there is nothing to sign
    // in to, so the app runs offline exactly as it did before accounts.
    if (!AppConfig.accountsEnabled) return shell;

    return FutureBuilder<Account?>(
      future: _restore,
      builder: (BuildContext context, AsyncSnapshot<Account?> snap) {
        // A cached account is shown the moment it is read, so this only
        // lingers on a first launch or a phone with nothing cached.
        if (snap.connectionState != ConnectionState.done &&
            AccountService.current.value == null) {
          return const Scaffold(
            body: Padding(
              padding: EdgeInsets.all(Tokens.spaceBase),
              child: Center(child: LoadingState(message: 'Signing you in')),
            ),
          );
        }

        return ValueListenableBuilder<Account?>(
          valueListenable: AccountService.current,
          builder: (BuildContext context, Account? account, _) {
            if (account == null) return const LoginScreen();
            if (account.needsUsername) return const UsernameScreen();
            return shell;
          },
        );
      },
    );
  }
}
