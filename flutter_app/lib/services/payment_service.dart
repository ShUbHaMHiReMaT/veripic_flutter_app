import 'dart:async';

import 'package:razorpay_flutter/razorpay_flutter.dart';

import 'account_service.dart';

/// What a user can buy. Names match the server's `PLANS`.
class Plans {
  const Plans._();

  /// Checking whether a photo is real, and downloading the PDF report of the
  /// check. Rs 1 for 30 days; paying again adds another 30 on top.
  static const String pro = 'pro';

  static const int proRupees = 1;
  static const int proDays = 30;
}

/// Razorpay checkout.
///
/// The app opens the sheet and reports the result; it never decides whether
/// the payment worked. Razorpay's response is handed to the server, which
/// reproduces the HMAC with the key secret and only then extends the Pro
/// period. A client that unlocked its own features would be bypassed with a
/// two-line patch to the APK.
class PaymentService {
  PaymentService({AccountService? account})
      : _account = account ?? AccountService();

  final AccountService _account;

  /// True while the signed-in account's Pro period is running.
  ///
  /// Read from the account the server last returned, so it is the same answer
  /// on every screen and follows the account to another phone.
  static bool get isPro => AccountService.current.value?.isPro ?? false;

  /// Re-reads the account so a payment made elsewhere — another phone, or one
  /// the webhook granted after the app was closed mid-payment — shows up.
  Future<bool> refresh() async {
    try {
      await _account.refreshAccount();
    } on AccountException {
      // Signed out or offline — keep what is already known rather than
      // revoking access the user has paid for.
    }
    return isPro;
  }

  /// Runs checkout for Pro and returns true once the server confirms it.
  ///
  /// Completes only after verification, so a caller can unlock immediately
  /// without a second round trip.
  Future<bool> purchasePro() async {
    final Map<String, dynamic> order = await _account.createOrder(Plans.pro);

    final Razorpay razorpay = Razorpay();
    final Completer<bool> done = Completer<bool>();

    void finish(bool ok, [Object? error]) {
      if (done.isCompleted) return;
      if (error != null) {
        done.completeError(error);
      } else {
        done.complete(ok);
      }
    }

    razorpay.on(Razorpay.EVENT_PAYMENT_SUCCESS,
        (PaymentSuccessResponse response) async {
      try {
        // The only path that grants anything.
        final Account account = await _account.verifyPayment(
          orderId: order['orderId'] as String,
          paymentId: response.paymentId ?? '',
          signature: response.signature ?? '',
        );
        finish(account.isPro);
      } catch (e) {
        finish(false, e);
      }
    });

    razorpay.on(Razorpay.EVENT_PAYMENT_ERROR,
        (PaymentFailureResponse response) {
      finish(
        false,
        AccountException(
          response.message?.isNotEmpty == true
              ? response.message!
              : 'The payment did not go through.',
        ),
      );
    });

    razorpay.on(Razorpay.EVENT_EXTERNAL_WALLET, (ExternalWalletResponse _) {
      // The wallet app takes over; the webhook grants it if it completes.
      finish(false);
    });

    razorpay.open(<String, dynamic>{
      'key': order['keyId'],
      'order_id': order['orderId'],
      'amount': order['amount'],
      'currency': order['currency'] ?? 'INR',
      'name': 'GeoGuard',
      'description': order['description'],
      'prefill': <String, dynamic>{'email': order['prefillEmail'] ?? ''},
    });

    try {
      return await done.future;
    } finally {
      razorpay.clear();
    }
  }
}
