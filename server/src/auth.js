import { OAuth2Client } from 'google-auth-library';
import jwt from 'jsonwebtoken';

const SESSION_TTL = '30d';

let googleClient;

function client() {
  googleClient ??= new OAuth2Client();
  return googleClient;
}

/**
 * Verifies a Google ID token and returns the claims we trust.
 *
 * The app never tells us who it is. It hands over a token Google signed, and
 * this checks that signature against Google's published keys, plus `aud` (the
 * token was minted for *this* app, not some other app that also uses Google)
 * and `exp`. Decoding the JWT without verifying — which is easy to do by
 * accident, since the payload is just base64 — would let anyone sign in as
 * anyone by editing a string.
 */
export async function verifyGoogleIdToken(idToken) {
  // Comma-separated, because a project usually has more than one client id
  // (Android, Web, iOS) and the token's `aud` is whichever one the app was
  // configured with. Listing them all avoids a whole class of "works on my
  // build, fails on yours" — while still refusing a token minted for some
  // other project entirely, which is the check that actually matters.
  const audience = (process.env.GOOGLE_WEB_CLIENT_ID ?? '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);

  if (audience.length === 0) throw new Error('GOOGLE_WEB_CLIENT_ID is not set');

  const ticket = await client().verifyIdToken({ idToken, audience });
  const payload = ticket.getPayload();

  if (!payload?.sub) throw new Error('Token carried no subject');
  if (payload.email && payload.email_verified === false) {
    throw new Error('Google account email is not verified');
  }

  return {
    // `sub` is Google's stable per-account id. The account key is this, never
    // the email: emails are renamed and recycled, `sub` is not.
    googleSub: payload.sub,
    email: payload.email ?? null,
    displayName: payload.name ?? null,
    photoUrl: payload.picture ?? null,
  };
}

export function issueSession(user) {
  const secret = process.env.JWT_SECRET;
  if (!secret) throw new Error('JWT_SECRET is not set');

  return jwt.sign(
    { sub: user.googleSub, uid: user._id.toString() },
    secret,
    { expiresIn: SESSION_TTL },
  );
}

/** Express middleware: rejects anything without a session this server signed. */
export function requireSession(req, res, next) {
  const header = req.get('authorization') ?? '';
  const token = header.startsWith('Bearer ') ? header.slice(7) : null;
  if (!token) {
    return res.status(401).json({ error: 'Sign in first.' });
  }

  try {
    req.session = jwt.verify(token, process.env.JWT_SECRET);
    return next();
  } catch {
    return res.status(401).json({ error: 'Your session has expired. Sign in again.' });
  }
}
