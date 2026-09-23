# GeoGuard server

Accounts and the username directory. The phone app talks to this over HTTPS;
only this service ever sees the database.

```
Flutter app ──HTTPS, session JWT──▶ this server ──▶ MongoDB Atlas
```

## Run locally

```bash
cd server
npm install
cp .env.example .env     # fill in the three values
node --env-file=.env src/index.js
curl localhost:8080/health
```

## Test

```bash
MONGODB_URI="..." JWT_SECRET=test-secret npm test
```

The validation tests run anywhere. The directory tests need `MONGODB_URI` and
skip themselves without it. They create and delete their own `test-sub-*`
users, so they are safe against a real cluster.

---

## The two credentials, and why they are different

This trips everyone up, so it is worth being exact.

| | Looks like | What it is for | Goes where |
|---|---|---|---|
| **API key** | `AIzaSy...` | Maps, Places, Firebase config | **Not used by this project** |
| **OAuth client ID** | `1234-abc.apps.googleusercontent.com` | Signing a user in | app + server |
| **OAuth client secret** | `GOCSPX-...` | Server-side web flows | **Never needed here** |

Google Sign-In needs the **OAuth client ID**. An `AIzaSy...` key cannot sign
anybody in — it is not an identity credential at all, and `google_sign_in`
will reject it.

## Getting the OAuth client IDs

1. <https://console.cloud.google.com> → pick or create a project.
2. **APIs & Services → OAuth consent screen**
   - User type: External
   - Fill in app name, support email, developer email
   - While in "Testing", add your own Google account under **Test users**, or
     sign-in fails with `access_denied`.
3. **APIs & Services → Credentials → Create credentials → OAuth client ID**

   **a) Android client** — the app is matched by package + certificate.
   - Package name: from `android/app/build.gradle` (`applicationId`). It is
     `com.example.veripic` today; change it before you ever publish, because
     `com.example.*` is rejected by the Play Store.
   - SHA-1 of your **release** keystore:
     ```bash
     keytool -list -v -keystore veripic-release.jks -alias YOUR_ALIAS
     ```
   - Also add the **debug** SHA-1, or sign-in fails on every dev build:
     ```bash
     keytool -list -v -keystore ~/.android/debug.keystore \
       -alias androiddebugkey -storepass android -keypass android
     ```
   - This client id is never typed anywhere. Google matches it automatically.

   **b) Web client** — counter-intuitive but required.
   - Create a second client, type **Web application**.
   - *This* id is the one you use, in two places:
     - server: `GOOGLE_WEB_CLIENT_ID`
     - app: `--dart-define=GOOGLE_SERVER_CLIENT_ID=...`
   - It is what makes Google mint an ID token whose `aud` the server can
     verify. Without it you get a token the server will refuse.

   Both must sit in the **same Google Cloud project**.

## Deploy to Render (free)

1. Push this repo to GitHub.
2. <https://render.com> → New → Web Service → connect the repo.
3. Root directory `server`, build `npm install`, start `npm start`.
4. Environment → add `MONGODB_URI`, `MONGODB_DB`, `GOOGLE_WEB_CLIENT_ID`,
   `JWT_SECRET`.
5. Atlas → Network Access → allow Render's outbound IPs (listed on the
   service's page), **not** `0.0.0.0/0`.
6. Copy the service URL — that is `GEOGUARD_API`.

The free instance sleeps after inactivity, so the first request after a quiet
spell takes ~30s. Fine for a demo; move to the paid tier or Fly.io for real use.

## Point the app at it

```bash
flutter run \
  --dart-define=GEOGUARD_API=https://your-service.onrender.com \
  --dart-define=GOOGLE_SERVER_CLIENT_ID=1234-abc.apps.googleusercontent.com
```

Without these the app runs exactly as before — capture, check, save senders by
hand and share-as-file all work offline. Only the username directory is off,
and the Senders screen says so.

## API

All routes except `/health` and `/auth/google` need `Authorization: Bearer <session>`.

| Route | Body | Returns |
|---|---|---|
| `GET /health` | — | `{ok}` |
| `POST /auth/google` | `{idToken}` | `{token, user, needsUsername}` |
| `GET /me` | — | `{user, needsUsername}` |
| `POST /me/username` | `{username}` | `{user}` · 409 if taken |
| `PUT /me/keys` | `{sharingCode}` | `{user}` |
| `GET /users/search?q=` | — | `{results[]}` |
| `GET /users/:username` | — | `{user}` |

Two rules the code enforces and the app depends on:

- **The fingerprint is always derived server-side** from the key it names. A
  client-supplied fingerprint is just a label an attacker chose, and it is the
  one value users compare out loud.
- **Search never returns an email.** Only username, display name, sharing code
  and fingerprint leave the server.

## What this does not do yet

Encrypted photo transfer (§4 of `../flutter_app/BACKEND_PLAN.md`) and payments
are not built. The directory is the prerequisite for both.
