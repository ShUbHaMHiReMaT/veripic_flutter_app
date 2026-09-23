# GeoGuard — Tamper-Proof Geotagged Camera

Flutter (Dart) app for Android/iOS. It takes a photo, burns a GPS stamp into
the pixels, signs the result, and can later tell you whether that photo — or a
photo someone sent you — has been edited since it was taken.

> **This is a Flutter project.** It cannot run inside a web preview.
> Copy the `flutter_app/` folder into a real Flutter environment to build.

## Setup

```bash
cd flutter_app
flutter pub get
flutter run                  # on a connected device (camera needs real hardware)
```

No API keys and no `.env` are needed. Everything runs on the device, offline.

### Android permissions (`android/app/src/main/AndroidManifest.xml`)

```xml
<uses-permission android:name="android.permission.CAMERA"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
<uses-permission android:name="android.permission.INTERNET"/>
```

Set `minSdkVersion 21` in `android/app/build.gradle`.

### iOS permissions (`ios/Runner/Info.plist`)

```xml
<key>NSCameraUsageDescription</key><string>GeoGuard needs the camera to capture signed photos.</string>
<key>NSLocationWhenInUseUsageDescription</key><string>GeoGuard embeds GPS coordinates into signed photos.</string>
<key>NSPhotoLibraryUsageDescription</key><string>GeoGuard verifies photos from your library.</string>
```

---

## What changed, and why

| Area | How it was | How it is now | Why |
|---|---|---|---|
| **Sharing a photo** | Signature was **HMAC-SHA256** with a secret derived from the phone's hardware ID. Only the phone that took the photo held that secret. | Signature is **ECDSA P-256**. The private half stays in the Keystore; the **public half is embedded in the photo**. | HMAC is symmetric, so a friend's app had no key that could reproduce the signature and reported every shared photo as edited. A keypair verifies anywhere, offline, and the public key cannot sign anything. |
| **Who took it** | Not answered. A valid signature just meant "this phone". | Four tiers: **this phone / a saved contact / another GeoGuard phone (unknown) / not real**, in their own "Who took it" card. | "Unedited" and "I know who sent it" are different questions. Collapsing them makes the app vouch for strangers. |
| **Adding a friend** | Not possible. | Check a photo they sent → **Save this sender** → name them. Every later photo of theirs reads *"Taken by Ravi"*. | Trust on first use, the way SSH does it. Needs no server, no account, and no QR scanner. |
| **Sending a photo** | No share button. | **Share this photo** sends the original file, with a plain-words warning to send it as a **file/document, not as a photo**. | WhatsApp and Instagram re-encode photos and strip EXIF, the COM segment and the tail block — all three copies of the proof. Only the original file survives. |
| **Capture speed** | After the shutter: requested a *fresh* best-accuracy GPS fix, then **reverse-geocoded over the network**, then decoded the full-res frame **twice** and JPEG-encoded it **twice** — all on the UI thread. | Reuses the fix and address the viewfinder already has, and does **one decode, one encode** inside `Isolate.run`. | The old path blocked the shutter on a GPS lock and an HTTP round trip, then froze the interface for the entire image pipeline. |
| **Where photos are kept** | `getTemporaryDirectory()`. | App documents directory. The temp directory is still read, so older captures are not orphaned. | The OS reclaims temp space whenever it wants, which silently deleted captures. |
| **New photo showing up** | Frames and Locations read the disk once at startup. A new capture only appeared after killing and reopening the app. | A capture bumps `FrameStore.revision`; both tabs listen and reload. | Both tabs live in an `IndexedStack`, so their state is built once and never rebuilt on tab change. |
| **Gallery export failing** | Threw, so the whole capture reported failure. | Non-fatal. The signed photo is saved either way and the message says the gallery copy failed. | The app's own store is the system of record; the camera roll is a convenience. |
| **Home screen** | Two controls opened the camera: the big button *and* a "Camera" tool card. | One **Open camera** button. The freed tool card is now **Senders**. | One action, one control. |
| **Wording** | `Viewfinder`, `frame`, `payload`, `envelope`, `Extracting EXIF / COM payload`, `HAMMING 3 / 64 — TOLERANCE 10`. | `Camera`, `photo`, `details`, `Looking for the hidden details`, `3 OF 64 SPOTS DIFFER — LIMIT 10`. | Field users are not cryptographers. |

### Envelope versions

| Version | Signature | Protects | Checkable on another phone |
|---|---|---|---|
| v3 | HMAC, random per-install secret | stamp banner | no |
| v4 | HMAC, hardware-derived (HKDF) | stamp banner | no |
| v5 | HMAC, hardware-derived | stamp banner + 16 scene tiles | no |
| **v6** | **ECDSA P-256, key travels in the photo** | stamp banner + 16 scene tiles | **yes** |

Every older version still verifies on the phone that produced it — the key ring
and the old canonical forms are kept byte-for-byte.

---

## Architecture

| Layer | File |
|-------|------|
| Camera, GPS, capture pipeline | `lib/services/camera_service.dart` |
| Stamp compositing (pure, isolate-safe) | `lib/services/overlay_service.dart` |
| Envelope, perceptual hashing, embedding, verification | `lib/services/security_service.dart` |
| Portable keypair, signing, trusted contacts | `lib/services/identity_service.dart` |
| Stored photo index | `lib/services/frame_store.dart` |
| Verification pipeline (the 4 checks) | `lib/services/verification_service.dart` |
| Evidence certificate (PDF) | `lib/services/certificate_service.dart` |
| Camera UI | `lib/screens/camera_screen.dart` |
| Check UI | `lib/screens/verify_screen.dart` |
| Your code + saved senders | `lib/screens/senders_screen.dart` |

## How the signature works

1. The raw JPEG is decoded **once**, in a background isolate.
2. The GPS stamp is drawn into the pixels.
3. Two perceptual hashes are taken of the stamped image:
   - a 64-bit dHash of the stamp banner (the bottom 18%),
   - a 4×4 grid of independent dHashes covering the scene above it.
   Tiling matters: a single whole-image hash barely moves when one object is
   cloned out, but the tile containing that object moves unmistakably.
4. The envelope `{lat, lon, alt, ts, dev, ph, st, kid, pk, v}` is signed:
   `sig = ECDSA-P256-SHA256(private_key, "v6|lat|lon|alt|ts|dev|ph|tiles|pk")`.
   The public key is inside the signed string, so it cannot be swapped for an
   attacker's own.
5. The image is encoded **once** and the payload is embedded three times — EXIF
   `UserComment`, a real JPEG `COM` (0xFFFE) segment, and a tail block after
   EOF — because different tools strip different ones.
6. On check: recover the envelope, verify the signature with the public key in
   the photo, recompute both hashes, compare within tolerance.

Perceptual hashes, not exact ones: a signed photo has to survive being saved
and re-read. Tolerance is 10 of 64 bits, which benign recompression stays well
inside and a real edit does not.

## Known limits

- **A valid signature does not identify the signer.** Anyone can generate a
  keypair. The app says "another GeoGuard phone" until you save that sender by
  name, and never pretends otherwise. Proper attribution would need hardware
  attestation (Play Integrity / DeviceCheck) or a server-issued certificate.
- **Chat apps destroy the proof.** Anything that re-encodes the image strips
  all three payload copies. Share the file, not the photo.
- **Mock locations are refused, not flagged.** If the OS reports the fix came
  from a mock provider, capture is blocked rather than signed with a caveat.

## Device fingerprint — why not IMEI

The spec asked for an IMEI-derived hash shared by every photo from a device.
Real IMEI access isn't something a normal app can rely on:

- **Android 10+ (API 29+):** `TelephonyManager.getImei()` requires the
  privileged `READ_PRIVILEGED_PHONE_STATE` permission. Regular Play Store
  apps cannot hold that permission — the call throws `SecurityException`
  instead of returning a value.
- **iOS:** IMEI (and any true hardware serial) has never been exposed to
  third-party apps, at any OS version.

`DeviceService` instead uses the strongest identifier each platform actually
grants without special permission — `Settings.Secure.ANDROID_ID` on Android,
`identifierForVendor` on iOS — combined with brand/model and hashed with
SHA-256. The result is one deterministic 64-hex-char fingerprint, the same for
every photo from that device. It is shown, truncated, on the home screen.
