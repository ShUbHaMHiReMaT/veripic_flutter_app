import 'dart:convert';
import 'dart:io';

import 'package:android_id/android_id.dart';
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Immutable snapshot of everything VeriPic knows about the host device.
///
/// Split deliberately into three tiers:
///  * [seed]       — the *secret* hardware key material. Never leaves the
///                   device, never lands in an envelope, never shown in UI.
///                   Used exclusively as HKDF input keying material.
///  * [publicId]   — a domain-separated SHA-256 of [seed]. This is the value
///                   embedded in every signed photo. Because it is derived
///                   through a distinct domain-separation prefix, publishing
///                   it does not reveal the HKDF input.
///  * [attributes] — human-readable diagnostics for the UI / support. Includes
///                   volatile values (build fingerprint, OS version) that are
///                   intentionally *excluded* from key material.
class DeviceFingerprint {
  const DeviceFingerprint({
    required this.seed,
    required this.publicId,
    required this.label,
    required this.attributes,
    required this.usedFallback,
  });

  /// Secret hardware key material (HKDF IKM). Do not log or transmit.
  final String seed;

  /// Public, publishable device hash embedded in signed envelopes.
  final String publicId;

  /// Short human label, e.g. `Google:Pixel 7`.
  final String label;

  /// Diagnostic attributes for display. Safe to show; not key material.
  final Map<String, String> attributes;

  /// True when the OS identifier was unavailable and a persisted random
  /// fallback had to be used instead (emulators, unsupported platforms).
  final bool usedFallback;

  /// First 16 hex chars of [publicId] — what the UI shows in chips/badges.
  String get shortId =>
      publicId.length >= 16 ? publicId.substring(0, 16) : publicId;
}

/// Produces a single, deterministic per-device hardware fingerprint that is
/// reused for every photo signed on this device, plus the secret seed the
/// signing key is derived from.
///
/// ## Why not IMEI?
/// Reading the real IMEI is not viable for a normal app. Since Android 10
/// (API 29), `TelephonyManager.getImei()` requires the privileged
/// `READ_PRIVILEGED_PHONE_STATE` permission, which regular Play Store apps
/// cannot hold — it throws `SecurityException` instead of returning a value.
/// iOS never exposes IMEI to third-party apps at all. So we use the strongest
/// *legally accessible* hardware-bound identifier on each platform:
///
///   * Android: `Settings.Secure.ANDROID_ID` — stable for the lifetime of the
///     install (survives app reinstall; tied to device + signing key), no
///     permission required.
///   * iOS: `identifierForVendor` — Apple's sanctioned stable device
///     identifier for a vendor's apps, no permission required.
///
/// ## Why `build.fingerprint` is NOT part of the key material
/// `Build.FINGERPRINT` changes on *every OTA update*. Binding the signing key
/// to it would silently rotate the key after a system update and invalidate
/// every previously signed photo. Instead the seed uses only OTA-stable
/// hardware attributes (`hardware`, `board`, `device`, `brand`, `model` /
/// `utsname.machine`), and the build fingerprint is retained purely as a
/// display-level diagnostic in [DeviceFingerprint.attributes].
class DeviceService {
  DeviceService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const String _fallbackIdKey = 'veripic_fallback_hw_id';

  /// Domain-separation prefix so the published device hash can never be used
  /// as the HKDF input keying material.
  static const String _publicIdDomain = 'VeriPic-PublicDeviceID-v1';

  static DeviceFingerprint? _cached;
  static Future<DeviceFingerprint>? _inFlight;

  /// Resolves (and process-caches) the full device fingerprint.
  ///
  /// Concurrent callers share a single in-flight resolution so we never hit the
  /// platform channels twice during a capture burst.
  Future<DeviceFingerprint> resolve() {
    final DeviceFingerprint? cached = _cached;
    if (cached != null) return Future<DeviceFingerprint>.value(cached);
    return _inFlight ??= _resolveUncached().then((DeviceFingerprint fp) {
      _cached = fp;
      _inFlight = null;
      return fp;
    }, onError: (Object e) {
      _inFlight = null;
      throw e;
    });
  }

  Future<DeviceFingerprint> _resolveUncached() async {
    final DeviceInfoPlugin info = DeviceInfoPlugin();
    final Map<String, String> attributes = <String, String>{};

    // OTA-stable hardware attributes only — see class docs.
    final List<String> stableParts = <String>[];
    String hardwareId = '';
    String label = 'unknown';
    String platform = Platform.operatingSystem;

    try {
      if (Platform.isAndroid) {
        final AndroidDeviceInfo a = await info.androidInfo;
        platform = 'android';
        label = '${a.brand}:${a.model}';
        hardwareId = await const AndroidId().getId() ?? '';

        stableParts
          ..add('brand=${a.brand}')
          ..add('model=${a.model}')
          ..add('device=${a.device}')
          ..add('board=${a.board}')
          ..add('hardware=${a.hardware}')
          ..add('manufacturer=${a.manufacturer}');

        attributes
          ..['Platform'] =
              'Android ${a.version.release} (SDK ${a.version.sdkInt})'
          ..['Manufacturer'] = a.manufacturer
          ..['Model'] = '${a.brand} ${a.model}'
          ..['Hardware'] = a.hardware
          ..['Board'] = a.board
          ..['Build fingerprint'] = a.fingerprint
          ..['Physical device'] = a.isPhysicalDevice ? 'yes' : 'emulator'
          ..['Hardware ID source'] = 'Settings.Secure.ANDROID_ID';
      } else if (Platform.isIOS) {
        final IosDeviceInfo i = await info.iosInfo;
        platform = 'ios';
        label = '${i.name}:${i.model}';
        hardwareId = i.identifierForVendor ?? '';

        stableParts
          ..add('model=${i.model}')
          ..add('machine=${i.utsname.machine}')
          ..add('sysname=${i.utsname.sysname}');

        attributes
          ..['Platform'] = '${i.systemName} ${i.systemVersion}'
          ..['Model'] = i.model
          ..['Machine'] = i.utsname.machine
          ..['Physical device'] = i.isPhysicalDevice ? 'yes' : 'simulator'
          ..['Hardware ID source'] = 'identifierForVendor';
      } else {
        attributes['Platform'] = platform;
        attributes['Hardware ID source'] = 'persisted fallback';
      }
    } catch (_) {
      // Platform channel unavailable (desktop/test host) — fall through to the
      // persisted fallback below rather than breaking the capture flow.
    }

    // Extremely unlikely fallback (unsupported platform, emulator quirk where
    // the OS identifier is unavailable): use a one-time random ID persisted in
    // the Keystore/Keychain so the app still behaves deterministically.
    bool usedFallback = false;
    if (hardwareId.isEmpty) {
      hardwareId = await _persistedFallbackId();
      usedFallback = true;
      attributes['Hardware ID source'] = 'persisted fallback (Keystore)';
    }

    stableParts.sort(); // order-independent, so the seed is reproducible
    final String seed = 'veripic|$platform|$hardwareId|${stableParts.join('|')}';
    final String publicId =
        sha256.convert(utf8.encode('$_publicIdDomain|$seed')).toString();

    attributes['Device hash'] = publicId;

    return DeviceFingerprint(
      seed: seed,
      publicId: publicId,
      label: label,
      attributes: attributes,
      usedFallback: usedFallback,
    );
  }

  /// Public, publishable device hash embedded in every signed envelope.
  Future<String> fingerprint() async => (await resolve()).publicId;

  /// Secret HKDF input keying material. Never embed or transmit this.
  Future<String> hardwareSeed() async => (await resolve()).seed;

  /// Alias kept for existing call sites.
  Future<String> getDeviceId() async => fingerprint();

  /// Test / diagnostics hook: drops the process cache.
  static void resetCacheForTesting() {
    _cached = null;
    _inFlight = null;
  }

  Future<String> _persistedFallbackId() async {
    String? stored = await _storage.read(key: _fallbackIdKey);
    if (stored == null || stored.isEmpty) {
      stored = sha256
          .convert(utf8.encode('${DateTime.now().microsecondsSinceEpoch}:'
              '${identityHashCode(this)}'))
          .toString();
      await _storage.write(key: _fallbackIdKey, value: stored);
    }
    return stored;
  }
}
