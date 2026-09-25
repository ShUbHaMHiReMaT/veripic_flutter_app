import 'package:flutter_test/flutter_test.dart';
import 'package:geoguard/services/account_service.dart';

void main() {
  group('Pro status', () {
    test('an account that never paid is not Pro', () {
      final Account a = Account.fromJson(<String, dynamic>{
        'email': 'a@example.com',
        'username': 'ravi',
        'proUntil': null,
      });
      expect(a.isPro, isFalse);
      expect(a.isAdmin, isFalse);
    });

    test('a running Pro month counts, an expired one does not', () {
      final DateTime later = DateTime.now().add(const Duration(days: 10));
      final DateTime earlier = DateTime.now().subtract(const Duration(days: 1));

      expect(
        Account.fromJson(<String, dynamic>{
          'proUntil': later.toUtc().toIso8601String(),
        }).isPro,
        isTrue,
      );
      expect(
        Account.fromJson(<String, dynamic>{
          'proUntil': earlier.toUtc().toIso8601String(),
        }).isPro,
        isFalse,
      );
    });

    test('the admin account is Pro with no end date', () {
      final Account a = Account.fromJson(<String, dynamic>{
        'username': 'doom',
        'admin': true,
        'proUntil': null,
      });
      expect(a.isAdmin, isTrue);
      expect(a.isPro, isTrue);
    });

    test('the cached copy reads back the same', () {
      final Account a = Account(
        email: 'a@example.com',
        username: 'ravi',
        sharingCode: 'AgICAg==',
        fingerprint: '0123456789abcdef',
        proUntil: DateTime.utc(2030, 1, 2, 3, 4, 5).toLocal(),
      );
      final Account b = Account.fromJson(a.toJson());
      expect(b.username, a.username);
      expect(b.sharingCode, a.sharingCode);
      expect(b.proUntil, a.proUntil);
      expect(b.isPro, isTrue);
      expect(b.isAdmin, isFalse);
    });
  });

  group('session errors', () {
    test('only a rejected session counts as signed out', () {
      expect(const AccountException('x', statusCode: 401).isAuthFailure, isTrue);
      expect(const AccountException('x', statusCode: 404).isAuthFailure, isTrue);
      // A sleeping server or no signal must not throw the user out.
      expect(const AccountException('x').isAuthFailure, isFalse);
      expect(const AccountException('x', statusCode: 503).isAuthFailure, isFalse);
    });
  });
}
