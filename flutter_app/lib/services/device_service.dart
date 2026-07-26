import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Stable per-install device fingerprint. We combine an OS-provided hardware
/// identifier with a locally-generated install ID so the fingerprint is
/// stable across app launches but does not require any special permission.
class DeviceService {
  DeviceService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  Future<String> fingerprint() async {
    final DeviceInfoPlugin info = DeviceInfoPlugin();
    String hw = 'unknown';
    try {
      if (Platform.isAndroid) {
        final AndroidDeviceInfo a = await info.androidInfo;
        hw = '${a.brand}:${a.model}:${a.id}';
      } else if (Platform.isIOS) {
        final IosDeviceInfo i = await info.iosInfo;
        hw = '${i.name}:${i.model}:${i.identifierForVendor}';
      }
    } catch (_) {}

    String? install = await _storage.read(key: 'veripic_install_id');
    if (install == null || install.isEmpty) {
      install = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
      await _storage.write(key: 'veripic_install_id', value: install);
    }
    return '$hw#$install';
  }
}
