import 'dart:convert';
import 'dart:io';

import 'package:android_id/android_id.dart';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Produces a single, deterministic per-device "hardware fingerprint" hash
/// that is reused for every photo signed on this device.
///
/// Note on IMEI: reading the real IMEI is not viable for a normal app.
/// Since Android 10 (API 29), `TelephonyManager.getImei()` requires the
/// privileged `READ_PRIVILEGED_PHONE_STATE` permission, which regular
/// Play Store apps cannot hold — it throws `SecurityException` instead of
/// returning a value. iOS never exposes IMEI to third-party apps at all.
/// So instead we use the strongest *legally accessible* hardware-bound
/// identifier on each platform:
///   - Android: `Settings.Secure.ANDROID_ID` — stable for the lifetime of
///     the install (survives app reinstall, tied to the device + signing
///     key), no permission required.
///   - iOS: `identifierForVendor` — Apple's sanctioned stable device
///     identifier for a vendor's apps, no permission required.
/// Both are combined with brand/model info and hashed with SHA-256, so the
/// *same physical device always produces the same fingerprint hash*, which
/// is then embedded in every signed photo instead of a random per-install
/// value.
class DeviceService {
  DeviceService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static String? _cachedFingerprint;

  Future<String> fingerprint() async {
    if (_cachedFingerprint != null) return _cachedFingerprint!;

    final DeviceInfoPlugin info = DeviceInfoPlugin();
    String hardwareId = '';
    String label = 'unknown';

    try {
      if (Platform.isAndroid) {
        final AndroidDeviceInfo a = await info.androidInfo;
        label = '${a.brand}:${a.model}';
        hardwareId = await const AndroidId().getId() ?? '';
      } else if (Platform.isIOS) {
        final IosDeviceInfo i = await info.iosInfo;
        label = '${i.name}:${i.model}';
        hardwareId = i.identifierForVendor ?? '';
      }
    } catch (_) {}

    // Extremely unlikely fallback (e.g. unsupported platform/emulator
    // quirk where the OS identifier is unavailable): fall back to a
    // one-time generated ID persisted in secure storage so the app still
    // functions, rather than crashing the capture flow.
    if (hardwareId.isEmpty) {
      hardwareId = await _persistedFallbackId();
    }

    final String raw = '$label#$hardwareId';
    final String hash = sha256.convert(utf8.encode(raw)).toString();
    _cachedFingerprint = hash;
    return hash;
  }

  Future<String> _persistedFallbackId() async {
    const String key = 'veripic_fallback_hw_id';
    String? stored = await _storage.read(key: key);
    if (stored == null || stored.isEmpty) {
      stored = sha256
          .convert(utf8.encode(DateTime.now().microsecondsSinceEpoch.toString()))
          .toString();
      await _storage.write(key: key, value: stored);
    }
    return stored;
  }

  Future<String> getDeviceId() async => fingerprint();
}
