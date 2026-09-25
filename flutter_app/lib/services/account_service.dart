import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import 'identity_service.dart';
import 'sealed_transfer.dart';

/// Raised for anything the user should read, so callers never have to show a
/// raw exception string.
class AccountException implements Exception {
  const AccountException(this.message, {this.statusCode});
  final String message;

  /// HTTP status when the server answered, null when it could not be reached.
  final int? statusCode;

  /// True when the server rejected the session itself, as opposed to being
  /// unreachable. Only this should ever sign the user out.
  bool get isAuthFailure => statusCode == 401 || statusCode == 404;

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
    this.encryptionKey,
  });

  final String username;
  final String? displayName;

  /// Base64 P-256 public key — the same value photos carry.
  final String sharingCode;
  final String fingerprint;

  /// Their key-agreement public key. Null when they have not published one,
  /// in which case a photo cannot be sealed to them.
  final String? encryptionKey;

  bool get canReceive => encryptionKey != null && encryptionKey!.isNotEmpty;

  String get label => displayName?.isNotEmpty == true ? displayName! : username;

  static DirectoryUser fromJson(Map<String, dynamic> json) => DirectoryUser(
        username: json['username'] as String? ?? '',
        displayName: json['displayName'] as String?,
        sharingCode: json['sharingCode'] as String? ?? '',
        fingerprint: json['fingerprint'] as String? ?? '',
        encryptionKey: json['encryptionKey'] as String?,
      );
}

/// A photo somebody sent, still sealed.
class InboxItem {
  const InboxItem({
    required this.id,
    required this.fromUsername,
    required this.wrappedKey,
    required this.ephemeralPublicKey,
    required this.sha256,
    required this.bytes,
    this.sentAt,
  });

  final String id;
  final String fromUsername;
  final String wrappedKey;
  final String ephemeralPublicKey;
  final String sha256;
  final int bytes;
  final DateTime? sentAt;

  static InboxItem fromJson(Map<String, dynamic> json) => InboxItem(
        id: json['id'] as String? ?? '',
        fromUsername: json['fromUsername'] as String? ?? '',
        wrappedKey: json['wrappedKey'] as String? ?? '',
        ephemeralPublicKey: json['ephemeralPublicKey'] as String? ?? '',
        sha256: json['sha256'] as String? ?? '',
        bytes: (json['bytes'] as num?)?.toInt() ?? 0,
        sentAt: DateTime.tryParse(json['sentAt'] as String? ?? ''),
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
    this.proUntil,
    this.isAdmin = false,
  });

  final String? email;
  final String? username;
  final String? displayName;
  final String? sharingCode;
  final String? fingerprint;
  final String? photoUrl;

  /// End of the paid Pro period. Null when the account has never paid.
  final DateTime? proUntil;

  /// Pro unlocks checking photos and downloading the PDF report.
  ///
  /// Worked out from the end date rather than a stored flag, so a period that
  /// runs out while the app is open stops counting straight away.
  ///
  /// The admin account has every feature without a period.
  bool get isPro =>
      isAdmin || (proUntil != null && proUntil!.isAfter(DateTime.now()));

  /// The single password-login account the server treats as all-access.
  final bool isAdmin;

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
        proUntil:
            DateTime.tryParse(json['proUntil'] as String? ?? '')?.toLocal(),
        isAdmin: json['admin'] == true,
      );

  /// Same shape the server sends, so the cached copy parses with [fromJson].
  Map<String, dynamic> toJson() => <String, dynamic>{
        'email': email,
        'username': username,
        'displayName': displayName,
        'sharingCode': sharingCode,
        'fingerprint': fingerprint,
        'photoUrl': photoUrl,
        'proUntil': proUntil?.toUtc().toIso8601String(),
        'admin': isAdmin,
      };
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

  /// Last account the server returned, so a signed-in user who opens the app
  /// offline — or while a sleeping Render instance is waking up — still gets
  /// in instead of being sent back to the login screen.
  static const String _accountCacheKey = 'geoguard_account_cache_v1';

  /// Long enough for a free Render instance to wake from sleep, which takes
  /// around thirty seconds on the first request after a quiet spell.
  static const Duration _timeout = Duration(seconds: 60);

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

  /// Publishes [account] to the UI and remembers it for the next launch.
  Future<Account> _setCurrent(Account account) async {
    current.value = account;
    try {
      await _storage.write(
        key: _accountCacheKey,
        value: jsonEncode(account.toJson()),
      );
    } catch (_) {
      // Not cached: the next offline launch shows the login screen instead.
    }
    return account;
  }

  Future<Account?> _cachedAccount() async {
    try {
      final String? raw = await _storage.read(key: _accountCacheKey);
      if (raw == null || raw.isEmpty) return null;
      final Object? decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? Account.fromJson(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  Account _accountFrom(Map<String, dynamic> body) => Account.fromJson(
        (body['user'] as Map<String, dynamic>?) ?? <String, dynamic>{},
      );

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
    return _setCurrent(await _publishSharingCodeIfStale(_accountFrom(body)));
  }

  /// Signs in the admin account with its username and password.
  ///
  /// Only the one account configured on the server accepts a password; every
  /// other account signs in with Google. The password is checked by the
  /// server and never stored on this phone — only the session it returns is.
  Future<Account> signInWithPassword({
    required String username,
    required String password,
  }) async {
    if (!AppConfig.hasApi) throw AccountException(AppConfig.setupHint);

    final Map<String, dynamic> body = await _post(
      '/auth/password',
      <String, dynamic>{'username': username.trim(), 'password': password},
    );
    await _storeSession(body['token'] as String?);
    return _setCurrent(await _publishSharingCodeIfStale(_accountFrom(body)));
  }

  /// Re-reads the account behind a stored session. Null when signed out.
  ///
  /// Shows the cached account first, then refreshes it from the server. Only
  /// a session the server actually rejects signs the user out; an unreachable
  /// server leaves them signed in with what this phone last knew.
  Future<Account?> restore() async {
    if (!AppConfig.accountsEnabled) return null;
    if (await _sessionToken() == null) return null;

    final Account? cached = await _cachedAccount();
    if (cached != null) current.value = cached;

    try {
      final Map<String, dynamic> body = await _get('/me');
      return _setCurrent(await _publishSharingCodeIfStale(_accountFrom(body)));
    } on AccountException catch (e) {
      if (e.isAuthFailure) {
        // Expired or revoked — drop it rather than leaving the UI half signed in.
        await signOut();
        return null;
      }
      return cached;
    }
  }

  /// Fetches the latest account, including its Pro period, from the server.
  Future<Account> refreshAccount() async =>
      _setCurrent(_accountFrom(await _get('/me')));

  Future<void> signOut() async {
    await _storeSession(null);
    try {
      await _storage.delete(key: _accountCacheKey);
    } catch (_) {
      // Nothing cached, or storage unavailable — either way it is gone.
    }
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
    return _setCurrent(_accountFrom(body));
  }

  /// Asks whether [username] is free, for live feedback while typing.
  ///
  /// Returns null when free, otherwise the reason it cannot be used. This is
  /// only a hint — two people can see "free" at the same moment, and the
  /// server's unique index decides who actually gets it on [claimUsername].
  Future<String?> usernameProblem(String username) async {
    final Map<String, dynamic> body = await _get(
      '/users/available?u=${Uri.encodeQueryComponent(username.trim())}',
    );
    if (body['available'] == true) return null;
    return body['reason'] as String? ?? 'That username cannot be used.';
  }

  /// Pushes this install's public key into the directory.
  Future<Account> publishSharingCode() async {
    final PortableIdentity id = await _identity.identity();
    final Map<String, dynamic> body = await _put(
      '/me/keys',
      <String, dynamic>{
        'sharingCode': id.publicKeyB64,
        'encryptionKey': id.encryptionPublicKeyB64,
      },
    );
    return _setCurrent(_accountFrom(body));
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
      for (final Object? row
          in (body['results'] as List<dynamic>? ?? const <dynamic>[]))
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

  /// Records that a check ran, so the account has a history.
  ///
  /// Sends the verdict and nothing else. Silently does nothing when signed
  /// out or offline — a verification must never depend on a network call.
  Future<void> reportCheck(String verdict) async {
    if (!AppConfig.hasApi) return;
    if (await _sessionToken() == null) return;
    try {
      await _post('/events/checked', <String, dynamic>{'verdict': verdict});
    } catch (_) {
      // Best effort by design.
    }
  }

  // =====================================================================
  // Payments
  // =====================================================================

  /// Asks the server to open a Razorpay order.
  ///
  /// The amount is set server-side from a fixed price list, so a patched app
  /// cannot change what it pays.
  Future<Map<String, dynamic>> createOrder(String plan) =>
      _post('/payments/order', <String, dynamic>{'plan': plan});

  /// Hands Razorpay's response to the server for verification, and returns
  /// the account with its new Pro period.
  ///
  /// Nothing is unlocked until this returns: the signature can only be
  /// reproduced with the key secret, which lives on the server.
  Future<Account> verifyPayment({
    required String orderId,
    required String paymentId,
    required String signature,
  }) async {
    final Map<String, dynamic> body =
        await _post('/payments/verify', <String, dynamic>{
      'orderId': orderId,
      'paymentId': paymentId,
      'signature': signature,
    });
    return _setCurrent(_accountFrom(body));
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

  // =====================================================================
  // Encrypted photo delivery
  // =====================================================================

  /// Seals [fileBytes] to [recipient] and uploads the ciphertext.
  ///
  /// The bytes handed in must be the original signed file, uncompressed. That
  /// is the whole point: the server cannot read them, so nothing in the path
  /// can re-encode them, so the signature inside still verifies on arrival.
  Future<void> sendPhoto({
    required DirectoryUser recipient,
    required Uint8List fileBytes,
  }) async {
    final String? theirKey = recipient.encryptionKey;
    if (theirKey == null || theirKey.isEmpty) {
      throw AccountException(
        '@${recipient.username} cannot receive photos yet. They need to open '
        'the app once and sign in.',
      );
    }

    final SealedPhoto sealed = await compute(
      _sealInBackground,
      (bytes: fileBytes, key: theirKey),
    );

    await _post('/shares', <String, dynamic>{
      'toUsername': recipient.username,
      'ciphertextB64': base64Encode(sealed.ciphertext),
      ...sealed.toMetadata(),
    });
  }

  Future<List<InboxItem>> inbox() async {
    final Map<String, dynamic> body = await _get('/shares/inbox');
    return <InboxItem>[
      for (final Object? row
          in (body['shares'] as List<dynamic>? ?? const <dynamic>[]))
        if (row is Map<String, dynamic>) InboxItem.fromJson(row),
    ];
  }

  /// Downloads and opens one sealed photo, returning the original file.
  Future<Uint8List> receivePhoto(InboxItem item) async {
    if (!AppConfig.hasApi) throw AccountException(AppConfig.setupHint);

    final String? token = await _sessionToken();
    final http.Response res;
    try {
      res = await _http.get(
        _uri('/shares/${item.id}/blob'),
        headers: <String, String>{
          if (token != null) 'authorization': 'Bearer $token',
        },
      ).timeout(const Duration(minutes: 3));
    } catch (_) {
      throw const AccountException('Could not download that photo.');
    }

    if (res.statusCode != 200) {
      throw const AccountException('That photo is no longer available.');
    }

    final PortableIdentity me = await _identity.identity();
    return compute(
      _openInBackground,
      (
        ciphertext: res.bodyBytes,
        wrappedKey: item.wrappedKey,
        ephemeral: item.ephemeralPublicKey,
        sha256: item.sha256,
        privateKey: me.encryptionPrivateKeyBytes,
      ),
    );
  }

  /// Drops a share once it has been saved locally, freeing server storage.
  Future<void> deleteShare(InboxItem item) async {
    await _send(() async => _http.delete(
          _uri('/shares/${item.id}'),
          headers: await _headers(),
        ));
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
      response = await request().timeout(_timeout);
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
      statusCode: response.statusCode,
    );
  }
}

// AES-GCM over a multi-megabyte photo is heavy enough to drop frames, so both
// directions run off the UI isolate. Top-level functions, because `compute`
// cannot send a closure that captures `this`.

SealedPhoto _sealInBackground(({Uint8List bytes, String key}) job) =>
    SealedTransfer.seal(
      fileBytes: job.bytes,
      recipientEncryptionKeyB64: job.key,
    );

Uint8List _openInBackground(
  ({
    Uint8List ciphertext,
    String wrappedKey,
    String ephemeral,
    String sha256,
    Uint8List privateKey,
  }) job,
) =>
    SealedTransfer.open(
      ciphertext: job.ciphertext,
      wrappedKeyB64: job.wrappedKey,
      ephemeralPublicKeyB64: job.ephemeral,
      expectedSha256: job.sha256,
      myEncryptionPrivateKey: job.privateKey,
    );
