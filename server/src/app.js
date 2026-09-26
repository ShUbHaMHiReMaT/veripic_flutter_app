import cors from 'cors';
import express from 'express';
import rateLimit from 'express-rate-limit';

import { checkAdminLogin, ensureAdminUser, adminUsername } from './admin.js';
import { issueSession, requireSession, verifyGoogleIdToken } from './auth.js';
import { close, connect, users } from './db.js';
import { EVENTS, logEvent, recentEvents } from './events.js';
import {
  escapeRegex,
  fingerprintOf,
  isValidSharingCode,
  normaliseUsername,
} from './keys.js';
import { paymentsRouter, webhookRouter } from './payments.js';
import { pagesRouter } from './pages.js';
import { LATEST_RELEASE } from './release.js';
import { sharesRouter } from './shares.js';
import { privateView, publicView } from './views.js';

export function createApp() {
const app = express();
app.set('trust proxy', 1);
app.use(cors());

// Photos are megabytes, so this router brings its own body parser and must be
// mounted before the small global limit below — otherwise every upload is
// rejected as "request entity too large" before it reaches the route.
app.use('/shares', sharesRouter());

// The webhook signature covers the exact bytes Razorpay sent, so this must
// see the raw body — a JSON parser upstream would re-serialise it and every
// signature check would fail.
app.use('/payments/webhook', webhookRouter());
app.use('/payments', paymentsRouter());

app.use(express.json({ limit: '16kb' }));

app.get('/health', (_req, res) => res.json({ ok: true }));

// Home page and privacy policy, required by Google's OAuth consent screen.
app.use(pagesRouter());

// Public, so an app that is signed out can still learn it is out of date.
app.get('/app/latest', (_req, res) => res.json(LATEST_RELEASE));

// ---------------------------------------------------------------------------
// Sign in
// ---------------------------------------------------------------------------

app.post(
  '/auth/google',
  rateLimit({ windowMs: 60_000, limit: 20 }),
  async (req, res) => {
    const { idToken } = req.body ?? {};
    if (typeof idToken !== 'string' || idToken.length < 20) {
      return res.status(400).json({ error: 'No Google token supplied.' });
    }

    let claims;
    try {
      claims = await verifyGoogleIdToken(idToken);
    } catch (e) {
      // Deliberately vague to the caller, detailed in the log: the difference
      // between "bad signature" and "wrong audience" is useful to an attacker
      // probing the endpoint and useless to a real user.
      console.error('Google token rejected:', e.message);
      return res.status(401).json({ error: 'Google sign-in could not be confirmed.' });
    }

    const now = new Date();
    await users().updateOne(
      { googleSub: claims.googleSub },
      {
        $set: {
          email: claims.email,
          displayName: claims.displayName,
          photoUrl: claims.photoUrl,
          updatedAt: now,
        },
        $setOnInsert: {
          googleSub: claims.googleSub,
          username: null,
          signingPublicKey: null,
          fingerprint: null,
          createdAt: now,
        },
      },
      { upsert: true },
    );

    const user = await users().findOne({ googleSub: claims.googleSub });

    // `createdAt` equal to this request's `now` means the upsert inserted.
    const isNew = user.createdAt?.getTime() === now.getTime();
    await logEvent(
      claims.googleSub,
      isNew ? EVENTS.signedUp : EVENTS.signedIn,
      { email: claims.email },
    );
    if (isNew) await logEvent(claims.googleSub, EVENTS.signedIn, {});

    return res.json({
      token: issueSession(user),
      user: privateView(user),
      needsUsername: !user.username,
    });
  },
);

/**
 * Password sign-in, for the single admin account only.
 *
 * Every other account signs in with Google. The limit is tight because this
 * is the one route where a guess can be checked: ten tries per IP per fifteen
 * minutes makes working through even a short password list impractical.
 */
app.post(
  '/auth/password',
  rateLimit({ windowMs: 15 * 60_000, limit: 10 }),
  async (req, res) => {
    const { username, password } = req.body ?? {};
    if (!checkAdminLogin(username, password)) {
      // Same answer for a wrong name and a wrong password.
      return res.status(401).json({ error: 'Wrong username or password.' });
    }

    await ensureAdminUser();
    const user = await users().findOne({ username: adminUsername(), role: 'admin' });
    if (!user) {
      return res.status(409).json({
        error: 'The admin username is held by another account.',
      });
    }

    await logEvent(user.googleSub, EVENTS.signedIn, { method: 'password' });
    return res.json({
      token: issueSession(user),
      user: privateView(user),
      needsUsername: false,
    });
  },
);

// ---------------------------------------------------------------------------
// Me
// ---------------------------------------------------------------------------

app.get('/me', requireSession, async (req, res) => {
  const user = await users().findOne({ googleSub: req.session.sub });
  if (!user) return res.status(404).json({ error: 'Account not found.' });
  return res.json({ user: privateView(user), needsUsername: !user.username });
});

app.post('/me/username', requireSession, async (req, res) => {
  const username = normaliseUsername(req.body?.username);
  if (!username) {
    return res.status(400).json({
      error: 'Use 3-20 characters: letters, numbers and underscore.',
    });
  }

  try {
    // Set once. Photos are addressed to a username, so renaming would strand
    // every photo already waiting in this person's inbox.
    const result = await users().updateOne(
      { googleSub: req.session.sub, username: null },
      { $set: { username, updatedAt: new Date() } },
    );
    if (result.matchedCount === 0) {
      return res.status(409).json({ error: 'You already have a username.' });
    }
  } catch (e) {
    // The unique index is what actually decides this, so the duplicate-key
    // error is the answer rather than an unexpected failure.
    if (e?.code === 11000) {
      return res.status(409).json({ error: 'That username is taken.' });
    }
    throw e;
  }

  await logEvent(req.session.sub, EVENTS.usernameClaimed, { username });

  const user = await users().findOne({ googleSub: req.session.sub });
  return res.json({ user: privateView(user) });
});

/**
 * Publishes this install's sharing code.
 *
 * The app calls this after every sign-in, because reinstalling generates a new
 * keypair. The fingerprint is derived here rather than accepted, so it always
 * matches the key it names.
 */
app.put('/me/keys', requireSession, async (req, res) => {
  const sharingCode = req.body?.sharingCode;
  const encryptionKey = req.body?.encryptionKey;

  if (!isValidSharingCode(sharingCode)) {
    return res.status(400).json({ error: 'That is not a valid sharing code.' });
  }
  // Optional so an older app build can still publish its signing key, but a
  // malformed one is rejected rather than stored — a bad key here would make
  // every photo sent to this user undecryptable.
  if (encryptionKey !== undefined && !isValidSharingCode(encryptionKey)) {
    return res.status(400).json({ error: 'That is not a valid encryption key.' });
  }

  await users().updateOne(
    { googleSub: req.session.sub },
    {
      $set: {
        signingPublicKey: sharingCode,
        fingerprint: fingerprintOf(sharingCode),
        ...(encryptionKey ? { encryptionPublicKey: encryptionKey } : {}),
        keysUpdatedAt: new Date(),
      },
    },
  );

  await logEvent(req.session.sub, EVENTS.keysPublished, {
    fingerprint: fingerprintOf(sharingCode),
    withEncryptionKey: Boolean(encryptionKey),
  });

  const user = await users().findOne({ googleSub: req.session.sub });
  return res.json({ user: privateView(user) });
});

/**
 * The account's own activity log.
 *
 * Exists so a user can see what their account did — and so "I paid and got
 * nothing" has an answer that is not guesswork.
 */
app.get('/me/activity', requireSession, async (req, res) => {
  const rows = await recentEvents(req.session.sub);
  res.json({
    events: rows.map((e) => ({ type: e.type, at: e.at, data: e.data })),
  });
});

/**
 * The app reporting that a check ran.
 *
 * Verdict only. The photo, its coordinates and its signature stay on the
 * phone — the server has no business learning from a log what it cannot see
 * in the data itself.
 */
app.post('/events/checked', requireSession, async (req, res) => {
  const verdict = String(req.body?.verdict ?? '').slice(0, 40);
  await logEvent(req.session.sub, EVENTS.checkRun, { verdict });
  res.json({ ok: true });
});

// ---------------------------------------------------------------------------
// Directory
// ---------------------------------------------------------------------------

app.get(
  '/users/search',
  requireSession,
  rateLimit({ windowMs: 60_000, limit: 60 }),
  async (req, res) => {
    const q = String(req.query.q ?? '').trim().toLowerCase();
    if (q.length < 2) {
      return res.json({ results: [] });
    }

    const results = await users()
      .find({
        username: { $regex: `^${escapeRegex(q)}`, $options: 'i' },
        // Someone who has not published a key yet cannot be verified, so
        // listing them would only produce a dead end.
        signingPublicKey: { $ne: null },
        // Nobody needs to find themselves.
        googleSub: { $ne: req.session.sub },
      })
      .limit(20)
      .toArray();

    return res.json({ results: results.map(publicView) });
  },
);

/**
 * Live feedback for the username picker.
 *
 * Only a hint: two people can see "available" for the same name at once, and
 * the unique index on claim is what actually decides who gets it.
 */
app.get(
  '/users/available',
  requireSession,
  rateLimit({ windowMs: 60_000, limit: 120 }),
  async (req, res) => {
    const username = normaliseUsername(req.query.u);
    if (!username) {
      return res.json({
        available: false,
        reason: 'Use 3-20 characters: letters, numbers and underscore.',
      });
    }
    const taken = await users().countDocuments({ username }, { limit: 1 });
    return res.json({
      available: taken === 0,
      reason: taken === 0 ? null : 'That username is taken.',
    });
  },
);

app.get('/users/:username', requireSession, async (req, res) => {
  const username = normaliseUsername(req.params.username);
  if (!username) return res.status(400).json({ error: 'Bad username.' });

  const user = await users().findOne({ username });
  if (!user?.signingPublicKey) {
    return res.status(404).json({ error: 'No such user.' });
  }
  return res.json({ user: publicView(user) });
});

// ---------------------------------------------------------------------------

app.use((err, _req, res, _next) => {
  console.error(err);
  res.status(500).json({ error: 'Something went wrong on the server.' });
});
  return app;
}
