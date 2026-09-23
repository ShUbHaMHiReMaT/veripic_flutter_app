import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config.dart';
import '../services/account_service.dart';
import '../services/payment_service.dart';
import '../theme/veripic_theme.dart';

/// One place that decides whether a paid feature may run.
///
/// Every gate goes through here so the rule is stated once: the server is the
/// only thing that grants an entitlement, and a build with no server grants
/// everything rather than locking the user out of an app they cannot pay in.
class Paywall {
  const Paywall._();

  static const Map<String, ({String title, String blurb, int rupees})> _copy =
      <String, ({String title, String blurb, int rupees})>{
    Plans.verify: (
      title: 'Checking photos',
      blurb: 'Check whether any photo is real — its signature, its stamp and '
          'the picture itself.',
      rupees: 1,
    ),
    Plans.certificate: (
      title: 'Evidence certificate',
      blurb: 'Export a check as a signed PDF report, laid out to follow '
          'section 63(4) of the Bharatiya Sakshya Adhiniyam, 2023.',
      rupees: 1,
    ),
    Plans.sharing: (
      title: 'Sending photos',
      blurb: 'Send a photo straight to another GeoGuard user, locked so only '
          'they can open it and the proof inside survives the trip.',
      rupees: 1,
    ),
  };

  /// Returns true when [plan] may be used now.
  ///
  /// Shows the payment sheet if it is not already paid for. Returns false when
  /// the user backs out or the payment does not complete.
  static Future<bool> require(BuildContext context, String plan) async {
    // No account system in this build means no way to take a payment, and no
    // way to check one. Charging here would only break the app.
    if (!AppConfig.accountsEnabled) return true;
    if (PaymentService.has(plan)) return true;

    final PaymentService payments = PaymentService();

    // Ask the server before asking for money — the user may already own it on
    // another install, or have paid and closed the app mid-redirect.
    await payments.refresh();
    if (PaymentService.has(plan)) return true;
    if (!context.mounted) return false;

    if (AccountService.current.value == null) {
      await _tell(
        context,
        'Sign in first',
        'This is a paid feature, so it needs an account. Sign in from the '
            'home screen, then try again.',
      );
      return false;
    }

    final bool? go = await _offer(context, plan);
    if (go != true || !context.mounted) return false;

    try {
      final bool ok = await payments.purchase(plan);
      if (!ok && context.mounted) {
        await _tell(
          context,
          'Not unlocked',
          'The payment did not complete, so nothing was unlocked. You have '
              'not been charged for an incomplete payment.',
        );
      }
      return ok;
    } catch (e) {
      if (context.mounted) {
        await _tell(
          context,
          'Payment problem',
          e is AccountException ? e.message : '$e',
        );
      }
      return false;
    }
  }

  static Future<bool?> _offer(BuildContext context, String plan) {
    final ({String title, String blurb, int rupees}) copy =
        _copy[plan] ?? (title: 'Unlock', blurb: '', rupees: 1);

    return showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        final Palette p = Palette.of(context);
        return Dialog(
          backgroundColor: p.surface,
          shape:
              RoundedRectangleBorder(borderRadius: Tokens.brCard, side: p.side),
          child: Padding(
            padding: const EdgeInsets.all(Tokens.spaceBase),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SectionHead(title: copy.title),
                const SizedBox(height: Tokens.spaceSnug),
                Text(copy.blurb, style: p.body),
                const SizedBox(height: Tokens.spaceSnug),
                Text(
                  'One payment, and it stays unlocked on this account.',
                  style: p.dataSmall,
                ),
                const SizedBox(height: Tokens.spaceBase),
                ActionButton(
                  label: 'Pay Rs ${copy.rupees}',
                  icon: Icons.lock_open_outlined,
                  onPressed: () {
                    HapticFeedback.mediumImpact();
                    Navigator.of(context).pop(true);
                  },
                ),
                const SizedBox(height: Tokens.spaceSnug),
                ActionButton(
                  label: 'Not now',
                  color: p.surfaceInset,
                  onPressed: () => Navigator.of(context).pop(false),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static Future<void> _tell(
    BuildContext context,
    String title,
    String message,
  ) {
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) {
        final Palette p = Palette.of(context);
        return Dialog(
          backgroundColor: p.surface,
          shape:
              RoundedRectangleBorder(borderRadius: Tokens.brCard, side: p.side),
          child: Padding(
            padding: const EdgeInsets.all(Tokens.spaceBase),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SectionHead(title: title),
                const SizedBox(height: Tokens.spaceSnug),
                Text(message, style: p.body),
                const SizedBox(height: Tokens.spaceBase),
                ActionButton(
                  label: 'OK',
                  color: p.surfaceInset,
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
