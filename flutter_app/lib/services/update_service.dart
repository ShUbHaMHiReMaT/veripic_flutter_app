import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../config.dart';

/// A newer build than the one installed.
class AvailableUpdate {
  const AvailableUpdate({
    required this.version,
    required this.url,
    this.notes,
  });

  final String version;
  final Uri url;
  final String? notes;
}

/// Asks the GeoGuard server whether a newer APK has been published.
///
/// The app is installed from a file, not a store, so nothing else will ever
/// tell a user their copy is out of date. Compares build numbers (the part
/// after `+` in pubspec's `version`), which only ever go up.
class UpdateService {
  UpdateService({http.Client? client}) : _http = client ?? http.Client();

  final http.Client _http;

  /// The update to offer, or null when up to date, offline, or built without
  /// a server. Never throws: an update check must not break the home screen.
  Future<AvailableUpdate?> check() async {
    if (!AppConfig.hasApi) return null;
    try {
      final PackageInfo info = await PackageInfo.fromPlatform();
      final int installed = int.tryParse(info.buildNumber) ?? 0;

      final http.Response res = await _http
          .get(Uri.parse('${AppConfig.apiBase}/app/latest'))
          // Long enough for a sleeping Render instance to wake.
          .timeout(const Duration(seconds: 60));
      if (res.statusCode != 200) return null;

      final Object? body = jsonDecode(res.body);
      if (body is! Map<String, dynamic>) return null;
      return updateFrom(body, installedBuild: installed);
    } catch (_) {
      return null;
    }
  }

  /// Pure comparison, split out so it can be tested without a platform.
  static AvailableUpdate? updateFrom(
    Map<String, dynamic> latest, {
    required int installedBuild,
  }) {
    final int build = (latest['build'] as num?)?.toInt() ?? 0;
    final Uri? url = Uri.tryParse(latest['url'] as String? ?? '');
    if (build <= installedBuild || url == null || !url.hasScheme) return null;
    return AvailableUpdate(
      version: latest['version'] as String? ?? '$build',
      url: url,
      notes: latest['notes'] as String?,
    );
  }
}
