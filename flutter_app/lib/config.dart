/// Build-time configuration for the optional online account.
///
/// Both values are supplied with `--dart-define` at build time and are
/// deliberately *public* values: the API's own address, and the Google OAuth
/// **client id** (not the secret — a mobile app has no secret, and the
/// database URI lives only on the server).
///
/// ```
/// flutter run \
///   --dart-define=GEOGUARD_API=https://geoguard-server.onrender.com \
///   --dart-define=GOOGLE_SERVER_CLIENT_ID=1234-abc.apps.googleusercontent.com
/// ```
///
/// Unset, the app runs exactly as before: capture, check, share-as-file and
/// saving senders by hand all work offline. Only the username directory is
/// unavailable, and the Senders screen says so rather than failing.
class AppConfig {
  const AppConfig._();

  static const String apiBase = String.fromEnvironment('GEOGUARD_API');

  /// The **Web** OAuth client id, not the Android one.
  ///
  /// Counter-intuitive but correct: `google_sign_in` needs the web client id
  /// as `serverClientId` for Google to mint an ID token whose `aud` the server
  /// can verify. The Android client id still has to exist — it is matched by
  /// package name and signing certificate — but it is never named here.
  static const String googleServerClientId =
      String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');

  static bool get hasApi => apiBase.isNotEmpty;
  static bool get hasGoogle => googleServerClientId.isNotEmpty;

  /// True when online accounts can work at all.
  static bool get accountsEnabled => hasApi && hasGoogle;

  /// What is missing, in words a person can act on.
  static String get setupHint {
    if (accountsEnabled) return '';
    final List<String> missing = <String>[
      if (!hasApi) 'GEOGUARD_API',
      if (!hasGoogle) 'GOOGLE_SERVER_CLIENT_ID',
    ];
    return 'Build the app with --dart-define=${missing.join(' and --dart-define=')} '
        'to turn on accounts.';
  }
}
