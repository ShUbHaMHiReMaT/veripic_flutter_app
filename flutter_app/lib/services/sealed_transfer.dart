import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as c;
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes.dart';
import 'package:pointycastle/block/modes/gcm.dart';

import 'identity_service.dart';

/// Domain separator for the key-wrapping agreement.
///
/// Changing it breaks every sealed photo already in flight, so it is fixed.
const String _wrapInfo = 'GeoGuard-Share-v1';

const int _keyLength = 32; // AES-256
const int _nonceLength = 12; // GCM standard
const int _tagLength = 16;

/// A photo encrypted for exactly one recipient.
///
/// This is what solves the problem that chat apps destroy the proof. A
/// WhatsApp "photo" is re-encoded, which strips the EXIF comment, the JPEG COM
/// segment and the tail block — all three copies of the signature. Moving the
/// file as an opaque ciphertext means nothing along the way can re-encode it,
/// so the bytes that arrive are bit-for-bit the bytes that were signed.
class SealedPhoto {
  const SealedPhoto({
    required this.ciphertext,
    required this.wrappedKey,
    required this.ephemeralPublicKey,
    required this.sha256,
  });

  /// AES-256-GCM over the original signed file.
  final Uint8List ciphertext;

  /// The file key, itself encrypted to the recipient. Base64.
  final String wrappedKey;

  /// One-use public key the recipient needs to redo the agreement. Base64.
  final String ephemeralPublicKey;

  /// Hex digest of [ciphertext], checked before any decryption is attempted.
  final String sha256;

  Map<String, dynamic> toMetadata() => <String, dynamic>{
        'wrappedKey': wrappedKey,
        'ephemeralPublicKey': ephemeralPublicKey,
        'sha256': sha256,
      };
}

/// Raised when a sealed photo cannot be opened. Never says *why* in detail —
/// a precise reason is a decryption oracle.
class SealedTransferException implements Exception {
  const SealedTransferException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Seals a photo to a recipient's encryption public key, and opens it again.
///
/// The shape follows the standard hybrid scheme: a fresh random key encrypts
/// the file, and only that small key is handled by public-key crypto.
/// Encrypting a multi-megabyte photo directly with an asymmetric cipher is not
/// something P-256 can do at all.
class SealedTransfer {
  const SealedTransfer._();

  /// Encrypts [fileBytes] so only the holder of [recipientEncryptionKeyB64]
  /// can read it.
  static SealedPhoto seal({
    required Uint8List fileBytes,
    required String recipientEncryptionKeyB64,
  }) {
    // A fresh file key per photo. Reusing one across photos would mean a
    // single compromised key exposes every photo ever sent.
    final Uint8List fileKey = IdentityService.randomBytes(_keyLength);
    final Uint8List fileNonce = IdentityService.randomBytes(_nonceLength);

    final Uint8List body = _gcm(
      encrypt: true,
      key: fileKey,
      nonce: fileNonce,
      data: fileBytes,
    );

    // Nonce travels with the ciphertext it belongs to.
    final Uint8List ciphertext = Uint8List.fromList(<int>[
      ...fileNonce,
      ...body,
    ]);

    // Wrap the file key to the recipient using an ephemeral agreement, so two
    // photos to the same person share no key material.
    final ({Uint8List privateKey, Uint8List publicKey}) ephemeral =
        IdentityService.ephemeralPair();

    final Uint8List wrapKey = IdentityService.agreeKey(
      privateKeyBytes: ephemeral.privateKey,
      peerPublicKeyB64: recipientEncryptionKeyB64,
      info: _wrapInfo,
    );

    final Uint8List wrapNonce = IdentityService.randomBytes(_nonceLength);
    final Uint8List wrapped = _gcm(
      encrypt: true,
      key: wrapKey,
      nonce: wrapNonce,
      data: fileKey,
    );

    return SealedPhoto(
      ciphertext: ciphertext,
      wrappedKey: base64Encode(<int>[...wrapNonce, ...wrapped]),
      ephemeralPublicKey: base64Encode(ephemeral.publicKey),
      sha256: c.sha256.convert(ciphertext).toString(),
    );
  }

  /// Recovers the original file. Returns the exact bytes that were signed.
  static Uint8List open({
    required Uint8List ciphertext,
    required String wrappedKeyB64,
    required String ephemeralPublicKeyB64,
    required String expectedSha256,
    required Uint8List myEncryptionPrivateKey,
  }) {
    // Integrity before confidentiality: a truncated download is a broken
    // download, and saying so beats reporting the photo as a forgery.
    if (c.sha256.convert(ciphertext).toString() != expectedSha256) {
      throw const SealedTransferException(
        'This photo did not arrive in one piece. Ask for it again.',
      );
    }

    if (ciphertext.length < _nonceLength + _tagLength) {
      throw const SealedTransferException('This photo could not be opened.');
    }

    try {
      final Uint8List wrapKey = IdentityService.agreeKey(
        privateKeyBytes: myEncryptionPrivateKey,
        peerPublicKeyB64: ephemeralPublicKeyB64,
        info: _wrapInfo,
      );

      final Uint8List wrappedBlob = base64Decode(wrappedKeyB64);
      final Uint8List fileKey = _gcm(
        encrypt: false,
        key: wrapKey,
        nonce: Uint8List.sublistView(wrappedBlob, 0, _nonceLength),
        data: Uint8List.sublistView(wrappedBlob, _nonceLength),
      );

      return _gcm(
        encrypt: false,
        key: fileKey,
        nonce: Uint8List.sublistView(ciphertext, 0, _nonceLength),
        data: Uint8List.sublistView(ciphertext, _nonceLength),
      );
    } catch (e) {
      if (e is SealedTransferException) rethrow;
      // GCM authentication failed, or the agreement produced a different key.
      // Both mean the same thing to the user.
      throw const SealedTransferException(
        'This photo was not sent to you, or it has been tampered with.',
      );
    }
  }

  static Uint8List _gcm({
    required bool encrypt,
    required Uint8List key,
    required Uint8List nonce,
    required Uint8List data,
  }) {
    final GCMBlockCipher cipher = GCMBlockCipher(AESEngine())
      ..init(
        encrypt,
        AEADParameters(
          KeyParameter(key),
          _tagLength * 8,
          nonce,
          Uint8List(0),
        ),
      );
    return cipher.process(data);
  }
}
