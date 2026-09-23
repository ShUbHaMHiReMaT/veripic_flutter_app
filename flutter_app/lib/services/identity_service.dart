import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/ecc/api.dart';
import 'package:pointycastle/ecc/curves/secp256r1.dart';
import 'package:pointycastle/key_derivators/api.dart';
import 'package:pointycastle/key_derivators/hkdf.dart';
import 'package:pointycastle/key_generators/api.dart';
import 'package:pointycastle/key_generators/ec_key_generator.dart';
import 'package:pointycastle/macs/hmac.dart';
import 'package:pointycastle/random/fortuna_random.dart';
import 'package:pointycastle/signers/ecdsa_signer.dart';

/// How much this phone knows about whoever signed a photo.
///
/// The signature answers "has this photo been altered since it was signed".
/// It does *not* answer "who signed it" — anyone can generate a keypair. The
/// two questions are kept separate on purpose, because collapsing them is how
/// a verifier ends up vouching for a stranger.
enum SignerTrust {
  /// Signed by a key this phone holds — we took it ourselves.
  thisPhone,

  /// Signed by a public key the user has saved under a name.
  savedContact,

  /// Signature is mathematically valid, but this key has never been seen.
  unknownPhone,

  /// No portable key involved (a pre-v6 photo, verified locally by HMAC).
  localOnly,
}

extension SignerTrustLabel on SignerTrust {
  String get plainLabel => switch (this) {
        SignerTrust.thisPhone => 'Taken on this phone',
        SignerTrust.savedContact => 'Taken by a saved contact',
        SignerTrust.unknownPhone => 'Taken on another GeoGuard phone',
        SignerTrust.localOnly => 'Taken on this phone',
      };
}

/// One saved sender: a public key the user has put a name to.
class TrustedContact {
  const TrustedContact({
    required this.fingerprint,
    required this.name,
    required this.publicKey,
    required this.savedAtMs,
  });

  /// First 16 hex chars of SHA-256 over the compressed public key.
  final String fingerprint;
  final String name;

  /// Base64 compressed public point, exactly as it travels in the photo.
  final String publicKey;
  final int savedAtMs;

  /// Grouped in fours so a human can read it aloud to check it matches.
  String get readableFingerprint {
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < fingerprint.length; i += 4) {
      if (i > 0) out.write(' ');
      out.write(fingerprint.substring(i, min(i + 4, fingerprint.length)));
    }
    return out.toString().toUpperCase();
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'fp': fingerprint,
        'name': name,
        'pk': publicKey,
        'ts': savedAtMs,
      };

  static TrustedContact fromJson(Map<String, dynamic> json) => TrustedContact(
        fingerprint: json['fp'] as String? ?? '',
        name: json['name'] as String? ?? '',
        publicKey: json['pk'] as String? ?? '',
        savedAtMs: (json['ts'] as num?)?.toInt() ?? 0,
      );
}

/// This install's portable signing identity.
///
/// The private half never leaves the phone. The public half is embedded in
/// every photo, which is what lets any other install verify the photo offline.
class PortableIdentity {
  const PortableIdentity({
    required this.privateKeyBytes,
    required this.publicKeyBytes,
    required this.encryptionPrivateKeyBytes,
    required this.encryptionPublicKeyBytes,
  });

  final Uint8List privateKeyBytes;
  final Uint8List publicKeyBytes;

  /// A second P-256 keypair, used only for key agreement when receiving a
  /// sealed photo.
  ///
  /// Separate from the signing pair on purpose. Using one key for both
  /// signing and key agreement mixes two different security arguments, and a
  /// weakness in either protocol then undermines both.
  final Uint8List encryptionPrivateKeyBytes;
  final Uint8List encryptionPublicKeyBytes;

  String get encryptionPublicKeyB64 =>
      base64Encode(encryptionPublicKeyBytes);

  String get publicKeyB64 => base64Encode(publicKeyBytes);

  String get fingerprint => IdentityService.fingerprintOf(publicKeyB64);

  String get readableFingerprint =>
      TrustedContact(
        fingerprint: fingerprint,
        name: '',
        publicKey: publicKeyB64,
        savedAtMs: 0,
      ).readableFingerprint;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'd': base64Encode(privateKeyBytes),
        'q': base64Encode(publicKeyBytes),
        'ed': base64Encode(encryptionPrivateKeyBytes),
        'eq': base64Encode(encryptionPublicKeyBytes),
      };

  /// Tolerates an identity stored before encryption keys existed by minting
  /// the missing pair, so an existing install keeps its signing key — and
  /// therefore keeps verifying every photo it has already taken.
  static PortableIdentity fromJson(Map<String, dynamic> json) {
    final String? ed = json['ed'] as String?;
    final String? eq = json['eq'] as String?;
    if (ed == null || eq == null) {
      final PortableIdentity fresh = IdentityService.generate();
      return PortableIdentity(
        privateKeyBytes: base64Decode(json['d'] as String),
        publicKeyBytes: base64Decode(json['q'] as String),
        encryptionPrivateKeyBytes: fresh.encryptionPrivateKeyBytes,
        encryptionPublicKeyBytes: fresh.encryptionPublicKeyBytes,
      );
    }
    return PortableIdentity(
      privateKeyBytes: base64Decode(json['d'] as String),
      publicKeyBytes: base64Decode(json['q'] as String),
      encryptionPrivateKeyBytes: base64Decode(ed),
      encryptionPublicKeyBytes: base64Decode(eq),
    );
  }
}

/// Portable, offline-verifiable signatures over NIST P-256 (secp256r1).
///
/// Replaces the device-bound HMAC for newly captured photos. HMAC is
/// symmetric, so only the phone holding the secret could ever verify its own
/// output — sharing a photo with another GeoGuard user always read as a
/// forgery. A keypair fixes that without weakening anything: the public key
/// travels in the photo and cannot be used to sign.
class IdentityService {
  IdentityService({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const String _identityStorageKey = 'geoguard_identity_p256_v6';
  static const String _contactsStorageKey = 'geoguard_trusted_contacts_v1';

  static final ECDomainParameters _curve = ECCurve_secp256r1();

  PortableIdentity? _cached;
  Future<PortableIdentity>? _inFlight;

  // =====================================================================
  // Identity
  // =====================================================================

  /// This install's keypair, generated once and then reused forever.
  Future<PortableIdentity> identity() {
    final PortableIdentity? cached = _cached;
    if (cached != null) return Future<PortableIdentity>.value(cached);
    return _inFlight ??= _load().then((PortableIdentity id) {
      _cached = id;
      _inFlight = null;
      return id;
    }, onError: (Object e) {
      _inFlight = null;
      throw e;
    });
  }

  Future<PortableIdentity> _load() async {
    try {
      final String? raw = await _storage.read(key: _identityStorageKey);
      if (raw != null && raw.isNotEmpty) {
        final Object? decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          return PortableIdentity.fromJson(decoded);
        }
      }
    } catch (_) {
      // Unreadable or corrupt — generate a fresh identity below rather than
      // leaving the app unable to sign at all.
    }

    final PortableIdentity fresh = generate();
    try {
      await _storage.write(
        key: _identityStorageKey,
        value: jsonEncode(fresh.toJson()),
      );
    } catch (_) {
      // Keystore unavailable. Signing still works this session; the identity
      // is simply not persisted, which the UI reports.
    }
    return fresh;
  }

  /// Seeds a CSPRNG from the platform's secure random source.
  static FortunaRandom _random() {
    final FortunaRandom rng = FortunaRandom();
    final Random seed = Random.secure();
    rng.seed(KeyParameter(
      Uint8List.fromList(List<int>.generate(32, (_) => seed.nextInt(256))),
    ));
    return rng;
  }

  static AsymmetricKeyPair<PublicKey, PrivateKey> _generatePair(
    FortunaRandom rng,
  ) {
    final ECKeyGenerator generator = ECKeyGenerator()
      ..init(ParametersWithRandom(ECKeyGeneratorParameters(_curve), rng));
    return generator.generateKeyPair();
  }

  /// Generates a fresh signing pair and a fresh encryption pair.
  static PortableIdentity generate() {
    final FortunaRandom rng = _random();

    final AsymmetricKeyPair<PublicKey, PrivateKey> signing = _generatePair(rng);
    final AsymmetricKeyPair<PublicKey, PrivateKey> encryption =
        _generatePair(rng);

    return PortableIdentity(
      privateKeyBytes: _bigIntToBytes((signing.privateKey as ECPrivateKey).d!, 32),
      // Compressed point: 33 bytes instead of 65, which matters because the
      // whole envelope has to fit in one JPEG COM segment.
      publicKeyBytes: (signing.publicKey as ECPublicKey).Q!.getEncoded(true),
      encryptionPrivateKeyBytes:
          _bigIntToBytes((encryption.privateKey as ECPrivateKey).d!, 32),
      encryptionPublicKeyBytes:
          (encryption.publicKey as ECPublicKey).Q!.getEncoded(true),
    );
  }

  /// One ephemeral keypair for a single sealed photo.
  static ({Uint8List privateKey, Uint8List publicKey}) ephemeralPair() {
    final AsymmetricKeyPair<PublicKey, PrivateKey> pair =
        _generatePair(_random());
    return (
      privateKey: _bigIntToBytes((pair.privateKey as ECPrivateKey).d!, 32),
      publicKey: (pair.publicKey as ECPublicKey).Q!.getEncoded(true),
    );
  }

  /// Random bytes from the platform CSPRNG.
  static Uint8List randomBytes(int length) =>
      _random().nextBytes(length);

  /// ECDH followed by HKDF-SHA256, yielding a 32-byte symmetric key.
  ///
  /// The raw ECDH output is a curve x-coordinate, not a uniformly random key,
  /// so it must never be used as one directly — HKDF is what turns it into
  /// key material. [info] separates this use from any other, so the same
  /// agreement can never produce the same key in two different contexts.
  static Uint8List agreeKey({
    required Uint8List privateKeyBytes,
    required String peerPublicKeyB64,
    required String info,
  }) {
    final ECPoint? peer = _curve.curve.decodePoint(base64Decode(peerPublicKeyB64));
    if (peer == null) {
      throw ArgumentError('Peer public key is not a point on P-256');
    }

    final ECDHBasicAgreement agreement = ECDHBasicAgreement()
      ..init(ECPrivateKey(_bytesToBigInt(privateKeyBytes), _curve));
    final BigInt shared =
        agreement.calculateAgreement(ECPublicKey(peer, _curve));

    final HKDFKeyDerivator hkdf = HKDFKeyDerivator(SHA256Digest())
      ..init(HkdfParameters(
        _bigIntToBytes(shared, 32),
        32,
        null,
        Uint8List.fromList(utf8.encode(info)),
      ));

    return hkdf.process(Uint8List(0));
  }

  /// Stable short name for a public key, used as the envelope's `kid` and as
  /// the identifier the user reads out to confirm a contact.
  static String fingerprintOf(String publicKeyB64) =>
      sha256.convert(utf8.encode(publicKeyB64)).toString().substring(0, 16);

  // =====================================================================
  // Sign / verify — pure, so they are safe to run in a background isolate
  // =====================================================================

  /// Signs [message] and returns the signature as `r|s` hex.
  ///
  /// Deterministic (RFC 6979), so no secure random is needed at capture time —
  /// which is what makes this callable from the capture isolate.
  static String sign(Uint8List privateKeyBytes, String message) {
    final ECPrivateKey key =
        ECPrivateKey(_bytesToBigInt(privateKeyBytes), _curve);

    final ECDSASigner signer =
        ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
          ..init(true, PrivateKeyParameter<ECPrivateKey>(key));

    final ECSignature sig = signer.generateSignature(
      Uint8List.fromList(utf8.encode(message)),
    ) as ECSignature;

    return '${_hex(sig.r)}|${_hex(sig.s)}';
  }

  /// Verifies an `r|s` hex signature against a base64 compressed public key.
  ///
  /// Returns false on any malformed input rather than throwing — a corrupt
  /// photo is an invalid photo, not a crash.
  static bool verify(String publicKeyB64, String message, String signature) {
    try {
      final List<String> parts = signature.split('|');
      if (parts.length != 2) return false;

      final BigInt r = BigInt.parse(parts[0], radix: 16);
      final BigInt s = BigInt.parse(parts[1], radix: 16);

      final ECPoint? q = _curve.curve.decodePoint(base64Decode(publicKeyB64));
      if (q == null) return false;

      final ECDSASigner signer = ECDSASigner(SHA256Digest())
        ..init(false, PublicKeyParameter<ECPublicKey>(ECPublicKey(q, _curve)));

      return signer.verifySignature(
        Uint8List.fromList(utf8.encode(message)),
        ECSignature(r, s),
      );
    } catch (_) {
      return false;
    }
  }

  // =====================================================================
  // Trusted contacts
  // =====================================================================

  /// Every sender the user has put a name to, newest first.
  Future<List<TrustedContact>> contacts() async {
    try {
      final String? raw = await _storage.read(key: _contactsStorageKey);
      if (raw == null || raw.isEmpty) return const <TrustedContact>[];

      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return const <TrustedContact>[];

      final List<TrustedContact> list = <TrustedContact>[
        for (final Object? e in decoded)
          if (e is Map<String, dynamic>) TrustedContact.fromJson(e),
      ]..sort((TrustedContact a, TrustedContact b) =>
          b.savedAtMs.compareTo(a.savedAtMs));
      return list;
    } catch (_) {
      return const <TrustedContact>[];
    }
  }

  Future<TrustedContact?> contactFor(String publicKeyB64) async {
    final String fp = fingerprintOf(publicKeyB64);
    for (final TrustedContact c in await contacts()) {
      if (c.fingerprint == fp) return c;
    }
    return null;
  }

  /// Saves (or renames) the sender behind [publicKeyB64].
  Future<TrustedContact> saveContact({
    required String publicKeyB64,
    required String name,
  }) async {
    final String fp = fingerprintOf(publicKeyB64);
    final TrustedContact contact = TrustedContact(
      fingerprint: fp,
      name: name.trim().isEmpty ? 'Unnamed sender' : name.trim(),
      publicKey: publicKeyB64,
      savedAtMs: DateTime.now().millisecondsSinceEpoch,
    );

    final List<TrustedContact> next = <TrustedContact>[
      for (final TrustedContact c in await contacts())
        if (c.fingerprint != fp) c,
      contact,
    ];
    await _writeContacts(next);
    return contact;
  }

  Future<void> removeContact(String fingerprint) async {
    final List<TrustedContact> next = <TrustedContact>[
      for (final TrustedContact c in await contacts())
        if (c.fingerprint != fingerprint) c,
    ];
    await _writeContacts(next);
  }

  Future<void> _writeContacts(List<TrustedContact> contacts) async {
    try {
      await _storage.write(
        key: _contactsStorageKey,
        value: jsonEncode(
          <Map<String, dynamic>>[
            for (final TrustedContact c in contacts) c.toJson(),
          ],
        ),
      );
    } catch (_) {
      // Storage unavailable — the contact simply is not remembered.
    }
  }

  // =====================================================================
  // Byte helpers
  // =====================================================================

  static String _hex(BigInt v) {
    final String s = v.toRadixString(16);
    return s.length.isEven ? s : '0$s';
  }

  static Uint8List _bigIntToBytes(BigInt value, int length) {
    final Uint8List out = Uint8List(length);
    BigInt v = value;
    for (int i = length - 1; i >= 0; i--) {
      out[i] = (v & BigInt.from(0xFF)).toInt();
      v = v >> 8;
    }
    return out;
  }

  static BigInt _bytesToBigInt(Uint8List bytes) {
    BigInt v = BigInt.zero;
    for (final int b in bytes) {
      v = (v << 8) | BigInt.from(b);
    }
    return v;
  }
}
