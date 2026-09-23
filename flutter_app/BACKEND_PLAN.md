# GeoGuard — accounts, directory, sharing and payments

Plan for the server-side half. Nothing here is built yet: it is all blocked on
credentials (Google OAuth client, payment keys, a rotated database user).

---

## 0. Do this first — the pasted database URI is burned

The connection string shared in chat contains a live username and password for
`cluster0.h52ocio.mongodb.net`. Treat it as public now:

1. Atlas → Database Access → **delete** the `shubhamhiremath87_db_user` user.
2. Create a new user with a fresh password and **only** `readWrite` on the one
   database GeoGuard uses — not `atlasAdmin`, not `readWriteAnyDatabase`.
3. Atlas → Network Access → remove `0.0.0.0/0` if it is there. Allow only your
   backend host's egress IP.
4. Put the new URI in the backend's environment (`MONGODB_URI`), never in a
   file that gets committed.

Rotating costs five minutes. Not rotating means anyone who has seen this chat
can read, alter or drop every user record you ever store.

### The app must never hold that URI

This is the part that changes the architecture, so it is worth being plain
about. A Flutter APK is a zip. `unzip`, then `strings` on `libapp.so`, and
every string constant in the app is on screen in under a minute — obfuscation
does not help, because the connection string has to exist in plaintext at the
moment it is used.

A database URI in the app is not "a key that might leak". It is a published
admin password with a hostname attached.

```
  WRONG                               RIGHT
  ┌─────────┐                         ┌─────────┐
  │ Flutter │──── mongodb+srv ──────▶ │ Flutter │──── HTTPS + session JWT ──┐
  │   app   │     (URI in APK)        │   app   │                           │
  └─────────┘         │               └─────────┘                           ▼
                      ▼                                              ┌──────────────┐
              ┌──────────────┐                                       │ Your backend │
              │ MongoDB Atlas│                                       │  (holds URI) │
              └──────────────┘                                       └──────┬───────┘
                                                                            ▼
                                                                     ┌──────────────┐
                                                                     │ MongoDB Atlas│
                                                                     └──────────────┘
```

Two more reasons the direct route does not work even ignoring security: the
MongoDB wire protocol is frequently blocked on mobile carrier networks, and a
phone cannot hold a sane connection pool.

**You need a small backend.** Free tiers that work: Render, Fly.io, Railway.
(Atlas's own Data API was retired in 2025, so it is no longer an option.)

---

## 1. Storage budget — your instinct is right

0.5 GB is generous *as long as no image bytes go in Mongo*.

| Collection | Per document | 10,000 users |
|---|---|---|
| `users` | ~350 B (username, google sub, email, display name, public keys, fingerprint, timestamps) | ~3.5 MB |
| `shares` | ~400 B (from, to, blob URL, SHA-256, wrapped key, ephemeral key, state) | 20 shares each → ~80 MB |
| `payments` | ~250 B | ~2.5 MB |

Well inside 512 MB. **Photos go to object storage, never Mongo** — Cloudflare
R2 (10 GB free), Backblaze B2 (10 GB free) or Supabase Storage (1 GB free).
Mongo holds the URL and the hash, not the bytes.

---

## 2. Google sign-in — the flow that is actually safe

The rule: **the app never tells the server who it is.** It presents a token
signed by Google, and the server checks that signature itself.

```
app: google_sign_in  ──▶  Google  ──▶  ID token (JWT, signed by Google)
app  ──── POST /auth/google { idToken } ────▶  backend
backend: fetch https://www.googleapis.com/oauth2/v3/certs
         verify signature, check aud == YOUR_CLIENT_ID, check exp, read `sub`
backend  ──── { sessionJwt, needsUsername } ────▶  app
```

`sub` is Google's stable user id — that is the account key, not the email
(emails get reused and changed).

Steps for when you have the credentials:

1. Google Cloud Console → new project → **OAuth consent screen** (External).
2. **Credentials → OAuth client ID → Android.** Needs your package name
   (`com.example.veripic` today — change it before release) and the SHA-1 of
   your signing certificate. You already have `veripic-release.jks`; get the
   SHA-1 with:
   `keytool -list -v -keystore veripic-release.jks -alias <alias>`
   Add the **debug** keystore's SHA-1 too or sign-in fails on your dev builds.
3. Also create a **Web** OAuth client. Counter-intuitive, but `google_sign_in`
   needs its id as `serverClientId` to get an ID token with the right `aud`.
4. iOS client if you ship there, plus the reversed client id in `Info.plist`.
5. Flutter side: `google_sign_in: ^6.2.1`.
6. Backend verifies with `google-auth-library` (Node) or `google-auth`
   (Python). **Do not** decode the JWT without verifying it.

Only the **Web client id** goes in the app. The client *secret* never leaves
the backend, and for a mobile app you do not need it at all.

---

## 3. The username directory

What you described: search a username, find the person, send them a photo.

```js
// users
{
  _id, googleSub, email, displayName,
  username,            // unique, lowercased, 3-20 chars [a-z0-9_]
  signingPublicKey,    // base64 P-256, from IdentityService.publicKeyB64
  encryptionPublicKey, // base64 P-256, see §4 — a SEPARATE key
  fingerprint,         // IdentityService.fingerprintOf(signingPublicKey)
  createdAt, updatedAt
}
```

Indexes: `{ username: 1 } unique`, `{ googleSub: 1 } unique`.

| Route | Auth | Does |
|---|---|---|
| `POST /auth/google` | — | verify ID token, upsert user, return session JWT |
| `POST /me/username` | session | claim a username, 409 if taken |
| `PUT /me/keys` | session | publish this install's two public keys |
| `GET /users/search?q=` | session | prefix search, returns username, display name, both public keys, fingerprint |
| `POST /shares` | session | record an outgoing share |
| `GET /shares/inbox` | session | pending shares for me |

### The honest caveat about the directory

Once the server hands out public keys, **the server becomes a trust anchor**.
A compromised server could return an attacker's key under your friend's
username, and photos from the attacker would read as genuine.

So keep both paths:

- the directory as the convenient default, and
- the fingerprint **visible in the UI** (the app already shows it grouped in
  fours, like a Signal safety number) so two users can read it aloud and
  confirm, and
- trust-on-first-use, which is already built and needs no server at all.

If a fetched key ever differs from a saved contact's key, the app must say so
loudly rather than silently replacing it.

---

## 4. Sharing photos, WhatsApp-style

The flow you pasted is accurate, and adapting it fixes a problem GeoGuard has
right now: **chat apps re-encode photos and destroy the embedded proof.** Move
the bytes as an opaque encrypted blob and nothing can re-encode them. The
end-to-end encryption is not only privacy here — it is what keeps the evidence
intact.

```
SENDER                                                           RECIPIENT
  │ original signed JPEG (no recompression — this is the point)
  │ Km = 32 random bytes
  │ blob = AES-256-GCM(Km, file)
  │ PUT blob ──▶ object storage ──▶ url, sha256(blob)
  │
  │ ECDH(ephemeral_priv, recipient.encryptionPublicKey) ──▶ HKDF ──▶ wrapKey
  │ wrappedKm = AES-256-GCM(wrapKey, Km)
  │
  │ POST /shares { to, url, sha256, wrappedKm, ephemeralPub } ──▶ backend
  │                                                    (server sees ciphertext only)
  │                                                    push via FCM ──────────▶│
  │                                                                            │ GET /shares/inbox
  │                                                                            │ GET blob
  │                                                                            │ check sha256
  │                                                                            │ ECDH(priv, ephemeralPub) → unwrap Km
  │                                                                            │ decrypt → ORIGINAL bytes
  │                                                                            │ run the existing 4 checks
```

Notes that matter:

- **Use a separate encryption keypair.** `IdentityService` holds an ECDSA
  P-256 *signing* key. Signing keys should not also do key agreement. Generate
  a second P-256 keypair for ECDH and publish both. `pointycastle` has
  `ECDHBasicAgreement`; feed its output through HKDF-SHA256 with a distinct
  `info` string.
- **Do not compress before encrypting.** Every byte must survive or the
  signature check fails on arrival — which is exactly the bug we are fixing.
- Verify `sha256(blob)` *before* decrypting, so a corrupted download is
  reported as corrupted rather than as a forgery.
- Keep the existing **Share as file** button. It needs no account, no server
  and no payment, and it must stay the free path.

---

## 5. Payments

Server-side verification is not optional. A client that reports its own
payment succeeded will be lied to within a week of launch.

| Gateway | Setup cost | Fees | Notes |
|---|---|---|---|
| **Razorpay** (recommended for India) | ₹0 | ~2% + GST | UPI, cards, netbanking. `razorpay_flutter`. Test mode is free and complete. |
| Cashfree | ₹0 | ~1.75%+ | Also Indian, similar API |
| Stripe | $0 | 2.9%+30¢ | Best if you go international; awkward for Indian domestic |

Razorpay flow — note where each secret lives:

```
app   ──── POST /payments/order { plan } ────▶ backend
backend: razorpay.orders.create(...)   [uses KEY_SECRET — backend only]
backend ──── { orderId, KEY_ID } ────▶ app
app: open Razorpay checkout with KEY_ID (public, safe in the app)
app   ──── { orderId, paymentId, signature } ────▶ backend
backend: expected = HMAC_SHA256(KEY_SECRET, orderId + "|" + paymentId)
         constant-time compare with signature     ← the actual gate
backend: mark entitlement, return updated session
```

Also register the **webhook** (`payment.captured`). Users close the app mid-
redirect; the webhook is what makes the entitlement land anyway.

### What to charge for

Since there are no ads, revenue has to come from the product. Two candidates
you named:

- **Evidence certificate PDF** — already built, and genuinely the most
  "professional deliverable" thing in the app. A good paid unlock.
- **Directory sharing** — the encrypted transfer above.

One caution: taking a photo, checking a photo, and sharing as a file should
stay free. They are what make the app worth installing, and a verification
tool that refuses to verify until you pay is a tool nobody recommends. Charge
for the certificate and for hosted delivery, not for the truth.

---

## 6. Suggested order of work

1. Rotate the database credentials (§0). Today.
2. Stand up the backend skeleton on Render with `/health`. Nothing else.
3. Google OAuth clients + `POST /auth/google` + session JWT.
4. Username claim + search. The app can now find people.
5. Publish `signingPublicKey` on login; show a directory name in the check
   screen alongside the existing fingerprint.
6. Object storage + encrypted share pipeline.
7. Payments last — it is the easiest to add and the most annoying to migrate.

Steps 3 onward need the credentials you said you would upload. Send them
through something other than chat: put them straight into the backend host's
environment variables and tell me only the *names* you used.
