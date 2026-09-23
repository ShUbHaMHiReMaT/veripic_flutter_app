import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:razorpay_flutter/razorpay_flutter.dart';

import 'account_service.dart';

/// What a user can unlock. Names match the server's `PLANS`.
class Plans {
  const Plans._();

  /// Checking whether a photo is real.
  static const String verify = 'verify';

  /// Sending a photo to another GeoGuard user, encrypted.
  static const String sharing = 'sharing';

  /// Exporting a check as the signed PDF evidence certificate.
  static const String certificate = 'certificate';
}

/// Razorpay checkout.
///
/// The app opens the sheet and reports the result; it never decides whether
/// the payment worked. Razorpay's response is handed to the server, which
/// reproduces the HMAC with the key secret and only then grants anything. A
/// client that unlocked its own features would be bypassed with a two-line
/// patch to the APK.
class PaymentService {
  PaymentService({AccountService? account})
      : _account = account ?? AccountService();

  final AccountService _account;

  /// Entitlements this phone knows about, for the UI to listen to.
  static final ValueNotifier<Set<String>> entitlements =
      ValueNotifier<Set<String>>(<String>{});

  static bool has(String plan) => entitlements.value.contains(plan);

  Future<Set<String>> refresh() async {
    try {
      final List<String> granted = await _account.entitlements();
      entitlements.value = granted.toSet();
    } on AccountException {
      // Signed out or offline — leave whatever is already known rather than
      // revoking access the user has paid for.
    }
    return entitlements.value;
  }

  /// Runs checkout for [plan] and returns true once the server confirms it.
  ///
  /// Completes only after verification, so a caller can unlock immediately
  /// without a second round trip.
  Future<bool> purchase(String plan) async {
    final Map<String, dynamic> order = await _account.createOrder(plan);

    final Razorpay razorpay = Razorpay();
    final Completer<bool> done = Completer<bool>();

    Future<void> finish(bool ok, [Object? error]) async {
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
        final List<String> granted = await _account.verifyPayment(
          orderId: order['orderId'] as String,
          paymentId: response.paymentId ?? '',
          signature: response.signature ?? '',
        );
        entitlements.value = granted.toSet();
        await finish(granted.contains(plan));
      } catch (e) {
        await finish(false, e);
      }
    });

    razorpay.on(Razorpay.EVENT_PAYMENT_ERROR,
        (PaymentFailureResponse response) async {
      await finish(
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
