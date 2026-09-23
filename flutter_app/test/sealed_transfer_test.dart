import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:geoguard/services/identity_service.dart';
import 'package:geoguard/services/sealed_transfer.dart';

Uint8List _photo([int size = 4096]) =>
    Uint8List.fromList(List<int>.generate(size, (int i) => (i * 31) % 256));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PortableIdentity alice;
  late PortableIdentity bob;

  setUp(() {
    alice = IdentityService.generate();
    bob = IdentityService.generate();
  });

  test('a sealed photo opens to the exact bytes that were sent', () {
    final Uint8List original = _photo();

    final SealedPhoto sealed = SealedTransfer.seal(
      fileBytes: original,
      recipientEncryptionKeyB64: bob.encryptionPublicKeyB64,
    );

    final Uint8List opened = SealedTransfer.open(
      ciphertext: sealed.ciphertext,
      wrappedKeyB64: sealed.wrappedKey,
      ephemeralPublicKeyB64: sealed.ephemeralPublicKey,
      expectedSha256: sealed.sha256,
      myEncryptionPrivateKey: bob.encryptionPrivateKeyBytes,
    );

    // Bit-for-bit. Anything less and the embedded signature stops verifying,
    // which is the entire reason for moving photos this way.
    expect(opened, equals(original));
  });

  test('the ciphertext does not contain the plaintext', () {
    final Uint8List original = _photo();
    final SealedPhoto sealed = SealedTransfer.seal(
      fileBytes: original,
      recipientEncryptionKeyB64: bob.encryptionPublicKeyB64,
    );

    expect(sealed.ciphertext.length, greaterThan(original.length));
    expect(
      latin1.decode(sealed.ciphertext, allowInvalid: true)
          .contains(latin1.decode(original.sublist(0, 64), allowInvalid: true)),
      isFalse,
    );
  });

  test('somebody else cannot open it', () {
    final SealedPhoto sealed = SealedTransfer.seal(
      fileBytes: _photo(),
      recipientEncryptionKeyB64: bob.encryptionPublicKeyB64,
    );

    // Alice sent it to Bob; Alice cannot read it back, and neither can a
    // third party. The server that stores the blob holds no key at all.
    expect(
      () => SealedTransfer.open(
        ciphertext: sealed.ciphertext,
        wrappedKeyB64: sealed.wrappedKey,
        ephemeralPublicKeyB64: sealed.ephemeralPublicKey,
        expectedSha256: sealed.sha256,
        myEncryptionPrivateKey: alice.encryptionPrivateKeyBytes,
      ),
      throwsA(isA<SealedTransferException>()),
    );
  });

  test('a corrupted download is reported before decryption is attempted', () {
    final SealedPhoto sealed = SealedTransfer.seal(
      fileBytes: _photo(),
      recipientEncryptionKeyB64: bob.encryptionPublicKeyB64,
    );

    final Uint8List damaged = Uint8List.fromList(sealed.ciphertext);
    damaged[damaged.length ~/ 2] ^= 0xFF;

    expect(
      () => SealedTransfer.open(
        ciphertext: damaged,
        wrappedKeyB64: sealed.wrappedKey,
        ephemeralPublicKeyB64: sealed.ephemeralPublicKey,
        expectedSha256: sealed.sha256,
        myEncryptionPrivateKey: bob.encryptionPrivateKeyBytes,
      ),
      throwsA(
        isA<SealedTransferException>().having(
          (SealedTransferException e) => e.message,
          'message',
          contains('did not arrive in one piece'),
        ),
      ),
    );
  });

  test('tampering with the ciphertext is caught even if the hash matches', () {
    // The scenario where a storage host swaps the blob *and* the recorded
    // hash. GCM's authentication tag is what stops it, independently.
    final SealedPhoto sealed = SealedTransfer.seal(
      fileBytes: _photo(),
      recipientEncryptionKeyB64: bob.encryptionPublicKeyB64,
    );

    final Uint8List damaged = Uint8List.fromList(sealed.ciphertext);
    damaged[damaged.length - 20] ^= 0x01;

    expect(
      () => SealedTransfer.open(
        ciphertext: damaged,
        wrappedKeyB64: sealed.wrappedKey,
        ephemeralPublicKeyB64: sealed.ephemeralPublicKey,
        // Recomputed, so the integrity check passes and GCM has to catch it.
        expectedSha256: SealedTransfer.seal(
          fileBytes: damaged,
          recipientEncryptionKeyB64: bob.encryptionPublicKeyB64,
        ).sha256,
        myEncryptionPrivateKey: bob.encryptionPrivateKeyBytes,
      ),
      throwsA(isA<SealedTransferException>()),
    );
  });

  test('two photos to the same person share no key material', () {
    final Uint8List original = _photo();
    final SealedPhoto a = SealedTransfer.seal(
      fileBytes: original,
      recipientEncryptionKeyB64: bob.encryptionPublicKeyB64,
    );
    final SealedPhoto b = SealedTransfer.seal(
      fileBytes: original,
      recipientEncryptionKeyB64: bob.encryptionPublicKeyB64,
    );

    expect(a.ephemeralPublicKey, isNot(b.ephemeralPublicKey));
    expect(a.wrappedKey, isNot(b.wrappedKey));
    // Identical input, different ciphertext: no one can tell from the stored
    // blobs that the same photo was sent twice.
    expect(a.ciphertext, isNot(equals(b.ciphertext)));
  });

  test('an identity saved before encryption keys still signs', () {
    // Upgrade path: an install created by the previous build has only the
    // signing pair stored. It must keep that key — losing it would invalidate
    // every photo already taken on that phone.
    final PortableIdentity old = IdentityService.generate();
    final Map<String, dynamic> legacy = <String, dynamic>{
      'd': base64Encode(old.privateKeyBytes),
      'q': base64Encode(old.publicKeyBytes),
    };

    final PortableIdentity restored = PortableIdentity.fromJson(legacy);

    expect(restored.publicKeyB64, old.publicKeyB64);
    expect(restored.encryptionPublicKeyBytes, hasLength(33));

    final SealedPhoto sealed = SealedTransfer.seal(
      fileBytes: _photo(256),
      recipientEncryptionKeyB64: restored.encryptionPublicKeyB64,
    );
    expect(
      SealedTransfer.open(
        ciphertext: sealed.ciphertext,
        wrappedKeyB64: sealed.wrappedKey,
        ephemeralPublicKeyB64: sealed.ephemeralPublicKey,
        expectedSha256: sealed.sha256,
        myEncryptionPrivateKey: restored.encryptionPrivateKeyBytes,
      ),
      hasLength(256),
    );
  });
}
