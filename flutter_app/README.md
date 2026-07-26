# VeriPic — Tamper-Proof Geotagged Camera

Flutter (Dart) app for Android/iOS that captures geotagged photos and embeds a
cryptographic signature + steganographic watermark so any pixel edit, EXIF
strip, re-encode, or AI manipulation is detectable.

> **This is a Flutter project.** It cannot run inside the Lovable web preview.
> Copy the `flutter_app/` folder into a real Flutter environment to build.

## Setup

```bash
cd flutter_app
cp .env.example .env         # fill in NVIDIA_API_KEY + APP_SIGNING_SECRET
flutter pub get
flutter run                  # on a connected device (camera needs real hardware)
```

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
<key>NSCameraUsageDescription</key><string>VeriPic needs the camera to capture signed photos.</string>
<key>NSLocationWhenInUseUsageDescription</key><string>VeriPic embeds GPS coordinates into signed photos.</string>
<key>NSPhotoLibraryUsageDescription</key><string>VeriPic verifies photos from your library.</string>
```

## Architecture

| Layer | File |
|-------|------|
| Camera + GPS capture | `lib/services/camera_service.dart` |
| Hashing, HMAC signing, LSB steganography | `lib/services/security_service.dart` |
| NVIDIA Build API (deepfake / vision analysis) | `lib/services/nvidia_vision_service.dart` |
| Verification pipeline | `lib/services/verification_service.dart` |
| Capture UI (live Lat/Long/UTC HUD) | `lib/screens/camera_screen.dart` |
| Verify UI (badge: AUTHENTIC / TAMPERED) | `lib/screens/verify_screen.dart` |

## How the signature works

1. On capture: raw JPEG bytes are decoded to RGB pixels.
2. `payload = SHA256(pixels_downsampled || lat || lon || alt || utc_ms || device_id)`
3. `signature = HMAC_SHA256(APP_SIGNING_SECRET, payload)`
4. A JSON envelope `{lat, lon, alt, ts, dev, sig}` is embedded via **LSB
   steganography** into the blue channel of a deterministic subset of pixels,
   then the image is re-encoded as PNG (lossless — required so LSBs survive).
5. On verify: extract envelope, recompute pixel hash + HMAC, compare. Any
   mismatch => tamper. Then hand the image to the NVIDIA Vision model for
   deepfake artifact scoring.

Because the hash is computed over a **downsampled** pixel grid (32×32 luma),
minor JPEG re-encoding tolerance is *not* provided — this is deliberate: the
output is PNG and any pixel change flips the verdict. Swap to a perceptual
hash (pHash) if you need robustness to benign re-compression.
