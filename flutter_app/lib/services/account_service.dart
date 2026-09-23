import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import 'identity_service.dart';

/// Raised for anything the user should read, so callers never have to show a
/// raw exception string.
class AccountException implements Exception {
  const AccountException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Somebody found in the username directory.
class DirectoryUser {
  const DirectoryUser({
    required this.username,
    required this.sharingCode,
    required this.fingerprint,
    this.displayName,
  });

  final String username;
  final String? displayName;

  /// Base64 P-256 public key — the same value photos carry.
  final String sharingCode;
  final String fingerprint;

  String get label => displayName?.isNotEmpty == true ? displayName! : username;

  static DirectoryUser fromJson(Map<String, dynamic> json) => DirectoryUser(
        username: json['username'] as String? ?? '',
        displayName: json['displayName'] as String?,
        sharingCode: json['sharingCode'] as String? ?? '',
        fingerprint: json['fingerprint'] as String? ?? '',
      );
}

/// The signed-in account, as this phone sees it.
class Account {
  const Account({
    required this.email,
    this.username,
    this.displayName,
    this.sharingCode,
    this.fingerprint,
    this.photoUrl,
  });

  final String? email;
  final String? username;
  final String? displayName;
  final String? sharingCode;
  final String? fingerprint;
  final String? photoUrl;

  bool get needsUsername => username == null || username!.isEmpty;

  /// True when the code stored in the directory is this install's current one.
  ///
  /// Reinstalling generates a new keypair, so the published code goes stale
  /// and everyone searching would get a key that cannot verify anything.
  bool matchesLocalKey(String localSharingCode) =>
      sharingCode != null && sharingCode == localSharingCode;

  static Account fromJson(Map<String, dynamic> json) => Account(
        email: json['email'] as String?,
        username: json['username'] as String?,
        displayName: json['displayName'] as String?,
        sharingCode: json['sharingCode'] as String?,
        fingerprint: json['fingerprint'] as String?,
        photoUrl: json['photoUrl'] as String?,
      );
}

/// Google sign-in, plus the username directory that carries sharing codes.
///
/// Every request goes to GeoGuard's own server over HTTPS. The app never holds
/// a database credential: it presents a token Google signed, the server checks
/// that signature and hands back a session of its own.
class AccountService {
  AccountService({
    FlutterSecureStorage? storage,
    IdentityService? identityService,
    http.Client? client,
  })  : _storage = storage ?? const FlutterSecureStorage(),
        _identity = identityService ?? IdentityService(),
        _http = client ?? http.Client();

  final FlutterSecureStorage _storage;
  final IdentityService _identity;
  final http.Client _http;

  static const String _sessionKey = 'geoguard_session_token_v1';

  /// Notifies the UI when sign-in state changes.
  static final ValueNotifier<Account?> current = ValueNotifier<Account?>(null);

  bool _googleReady = false;

  // =====================================================================
  // Session
  // =====================================================================

  Future<String?> _sessionToken() async {
    try {
      return await _storage.read(key: _sessionKey);
    } catch (_) {
      return null;
    }
  }

  Future<void> _storeSession(String? token) async {
    try {
      if (token == null) {
        await _storage.delete(key: _sessionKey);
      } else {
        await _storage.write(key: _sessionKey, value: token);
      }
    } catch (_) {
      // Keystore unavailable: the session simply does not survive a restart.
    }
  }

  Future<bool> get isSignedIn async => (await _sessionToken()) != null;

  // =====================================================================
  // Google
  // =====================================================================

  Future<void> _ensureGoogleReady() async {
    if (_googleReady) return;
    if (!AppConfig.hasGoogle) {
      throw const AccountException(
        'Google sign-in is not set up in this build.',
      );
    }
    await GoogleSignIn.instance.initialize(
      serverClientId: AppConfig.googleServerClientId,
    );
    _googleReady = true;
  }

  /// Signs in with Google and publishes this phone's sharing code.
  ///
  /// Publishing immediately is the point of the account: a directory entry
  /// with no key, or with a key from a previous install, cannot verify a
  /// single photo.
  Future<Account> signIn() async {
    if (!AppConfig.accountsEnabled) {
      throw AccountException(AppConfig.setupHint);
    }
    await _ensureGoogleReady();

    final GoogleSignInAccount googleUser;
    try {
      googleUser = await GoogleSignIn.instance.authenticate();
    } on GoogleSignInException catch (e) {
      throw AccountException(switch (e.code) {
        GoogleSignInExceptionCode.canceled => 'Sign-in cancelled.',
        GoogleSignInExceptionCode.interrupted =>
          'Sign-in was interrupted. Try again.',
        GoogleSignInExceptionCode.clientConfigurationError =>
          'This build is not set up for Google sign-in yet. Check the OAuth '
              'client id and the signing certificate fingerprint.',
        _ => 'Google sign-in failed. ${e.description ?? ''}'.trim(),
      });
    }

    final String? idToken = googleUser.authentication.idToken;
    if (idToken == null) {
      throw const AccountException(
        'Google did not return a sign-in token. Check that the web client id '
        'is set as serverClientId.',
      );
    }

    final Map<String, dynamic> body = await _post(
      '/auth/google',
      <String, dynamic>{'idToken': idToken},
    );

    await _storeSession(body['token'] as String?);
    Account account = Account.fromJson(
      (body['user'] as Map<String, dynamic>?) ?? <String, dynamic>{},
    );

    account = await _publishSharingCodeIfStale(account);
    current.value = account;
    return account;
  }

  /// Re-reads the account behind a stored session. Null when signed out.
  Future<Account?> restore() async {
    if (!AppConfig.accountsEnabled) return null;
    if (await _sessionToken() == null) return null;

    try {
      final Map<String, dynamic> body = await _get('/me');
      Account account = Account.fromJson(
        (body['user'] as Map<String, dynamic>?) ?? <String, dynamic>{},
      );
      account = await _publishSharingCodeIfStale(account);
      current.value = account;
      return account;
    } on AccountException {
      // Expired or revoked — drop it rather than leaving the UI half signed in.
      await _storeSession(null);
      current.value = null;
      return null;
    }
  }

  Future<void> signOut() async {
    await _storeSession(null);
    current.value = null;
    try {
      if (_googleReady) await GoogleSignIn.instance.signOut();
    } catch (_) {
      // Already signed out at the platform level.
    }
  }

  // =====================================================================
  // Directory
  // =====================================================================

  Future<Account> claimUsername(String username) async {
    final Map<String, dynamic> body = await _post(
      '/me/username',
      <String, dynamic>{'username': username},
    );
    final Account account = Account.fromJson(
      (body['user'] as Map<String, dynamic>?) ?? <String, dynamic>{},
    );
    current.value = account;
    return account;
  }

  /// Pushes this install's public key into the directory.
  Future<Account> publishSharingCode() async {
    final PortableIdentity id = await _identity.identity();
    final Map<String, dynamic> body = await _put(
      '/me/keys',
      <String, dynamic>{'sharingCode': id.publicKeyB64},
    );
    final Account account = Account.fromJson(
      (body['user'] as Map<String, dynamic>?) ?? <String, dynamic>{},
    );
    current.value = account;
    return account;
  }

  Future<Account> _publishSharingCodeIfStale(Account account) async {
    try {
      final PortableIdentity id = await _identity.identity();
      if (account.matchesLocalKey(id.publicKeyB64)) return account;
      return await publishSharingCode();
    } catch (_) {
      // Publishing is best effort at sign-in time; the Senders screen offers
      // a retry and says the code is not published yet.
      return account;
    }
  }

  Future<List<DirectoryUser>> search(String query) async {
    final String q = query.trim();
    if (q.length < 2) return const <DirectoryUser>[];

    final Map<String, dynamic> body =
        await _get('/users/search?q=${Uri.encodeQueryComponent(q)}');

    return <DirectoryUser>[
      for (final Object? row in (body['results'] as List<dynamic>? ?? const <dynamic>[]))
        if (row is Map<String, dynamic>) DirectoryUser.fromJson(row),
    ];
  }

  /// Saves a directory result as a named sender.
  ///
  /// Returns the existing contact unchanged when the directory hands back a
  /// key that differs from one already saved under the same code — see
  /// [conflictFor].
  Future<TrustedContact> saveFromDirectory(DirectoryUser user) =>
      _identity.saveContact(
        publicKeyB64: user.sharingCode,
        name: user.label,
      );

  /// Detects a directory entry whose key contradicts a saved contact.
  ///
  /// A server can be wrong or compromised, and silently replacing a saved key
  /// with a fetched one is exactly how an impostor gets accepted. When this
  /// returns a contact, the UI must ask rather than overwrite.
  Future<TrustedContact?> conflictFor(DirectoryUser user) async {
    for (final TrustedContact c in await _identity.contacts()) {
      if (c.name.toLowerCase() == user.label.toLowerCase() &&
          c.publicKey != user.sharingCode) {
        return c;
      }
    }
    return null;
  }

  // =====================================================================
  // HTTP
  // =====================================================================

  Uri _uri(String path) => Uri.parse('${AppConfig.apiBase}$path');

  Future<Map<String, String>> _headers() async {
    final String? token = await _sessionToken();
    return <String, String>{
      'content-type': 'application/json',
      if (token != null) 'authorization': 'Bearer $token',
    };
  }

  Future<Map<String, dynamic>> _get(String path) async =>
      _send(() async => _http.get(_uri(path), headers: await _headers()));

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) =>
      _send(() async => _http.post(
            _uri(path),
            headers: await _headers(),
            body: jsonEncode(body),
          ));

  Future<Map<String, dynamic>> _put(String path, Map<String, dynamic> body) =>
      _send(() async => _http.put(
            _uri(path),
            headers: await _headers(),
            body: jsonEncode(body),
          ));

  Future<Map<String, dynamic>> _send(
    Future<http.Response> Function() request,
  ) async {
    if (!AppConfig.hasApi) {
      throw AccountException(AppConfig.setupHint);
    }

    final http.Response response;
    try {
      response = await request().timeout(const Duration(seconds: 20));
    } catch (_) {
      throw const AccountException(
        'Could not reach the GeoGuard server. Check your connection.',
      );
    }

    Map<String, dynamic> body = <String, dynamic>{};
    try {
      final Object? decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) body = decoded;
    } catch (_) {
      // Non-JSON body — handled by the status check below.
    }

    if (response.statusCode >= 200 && response.statusCode < 300) {
      return body;
    }

    throw AccountException(
      body['error'] as String? ??
          'The server returned an error (${response.statusCode}).',
    );
  }
}
