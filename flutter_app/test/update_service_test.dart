import 'package:flutter_test/flutter_test.dart';
import 'package:geoguard/services/update_service.dart';

void main() {
  const Map<String, dynamic> latest = <String, dynamic>{
    'build': 3,
    'version': '1.0.2',
    'url': 'https://example.com/GeoGuard.apk',
    'notes': 'Fixes.',
  };

  test('offers the update to an older build', () {
    final AvailableUpdate? u =
        UpdateService.updateFrom(latest, installedBuild: 2);
    expect(u?.version, '1.0.2');
    expect(u?.url.toString(), 'https://example.com/GeoGuard.apk');
  });

  test('stays quiet on the same or a newer build', () {
    expect(UpdateService.updateFrom(latest, installedBuild: 3), isNull);
    expect(UpdateService.updateFrom(latest, installedBuild: 4), isNull);
  });

  test('ignores a reply without a usable link', () {
    expect(
      UpdateService.updateFrom(<String, dynamic>{'build': 9, 'url': ''},
          installedBuild: 1),
      isNull,
    );
  });
}
