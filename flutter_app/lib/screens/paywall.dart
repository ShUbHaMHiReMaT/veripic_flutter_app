import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../config.dart';
import '../services/account_service.dart';
import '../services/payment_service.dart';
import '../theme/veripic_theme.dart';

/// One place that decides whether a Pro feature may run.
///
/// Every gate goes through here so the rule is stated once: the server is the
/// only thing that grants Pro, and a build with no server grants everything
/// rather than locking the user out of an app they cannot pay in.
class Paywall {
  const Paywall._();

  /// Returns true when Pro features may be used now.
  ///
  /// Shows the payment sheet if the account is not Pro. Returns false when
  /// the user backs out or the payment does not complete.
  static Future<bool> requirePro(BuildContext context) async {
    // No account system in this build means no way to take a payment, and no
    // way to check one. Charging here would only break the app.
    if (!AppConfig.accountsEnabled) return true;
    if (PaymentService.isPro) return true;

    // Ask the server before asking for money — the user may have paid on
    // another phone, or paid and closed the app mid-redirect.
    if (await PaymentService().refresh()) return true;
    if (!context.mounted) return false;

    return buyPro(context);
  }

  /// Offers Pro, or another period on top of the current one, and runs the
  /// payment if the user accepts. Returns true when the account is Pro after.
  static Future<bool> buyPro(BuildContext context) async {
    if (AccountService.current.value == null) {
      await _tell(
        context,
        'Sign in first',
        'Pro belongs to an account. Sign in, then try again.',
      );
      return false;
    }

    final bool? go = await _offer(context);
    if (go != true || !context.mounted) return false;

    try {
      final bool ok = await PaymentService().purchasePro();
      if (!ok && context.mounted) {
        await _tell(
          context,
          'Pro not started',
          'The payment did not complete, so nothing was unlocked and you '
              'have not been charged.',
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

  static Future<bool?> _offer(BuildContext context) {
    final DateTime? until = AccountService.current.value?.proUntil;
    final bool renewing = PaymentService.isPro && until != null;

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
                const Row(
                  children: <Widget>[
                    Expanded(child: SectionHead(title: 'GeoGuard Pro')),
                    StatusBadge(label: 'pro', color: Tokens.accent),
                  ],
                ),
                const SizedBox(height: Tokens.spaceSnug),
                Text(
                  'Check whether any photo is real — its signature, its '
                  'stamp and the picture itself — and download the PDF report '
                  'of every check.',
                  style: p.body,
                ),
                const SizedBox(height: Tokens.spaceSnug),
                Text(
                  renewing
                      ? 'PRO UNTIL ${_date(until)} — PAYING ADDS '
                          '${Plans.proDays} MORE DAYS'
                      : 'RS ${Plans.proRupees} FOR ${Plans.proDays} DAYS',
                  style: p.dataSmall,
                ),
                const SizedBox(height: Tokens.spaceBase),
                ActionButton(
                  label: 'Pay Rs ${Plans.proRupees}',
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

  /// `25OCT26`, the same date format as the rest of the app.
  static String _date(DateTime d) =>
      DateFormat('ddMMMyy').format(d).toUpperCase();

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
                  label: 'Close',
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
