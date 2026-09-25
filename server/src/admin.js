import { createHash, timingSafeEqual } from 'node:crypto';

import { users } from './db.js';
import { normaliseUsername } from './keys.js';

/**
 * The one account that signs in with a password instead of Google, and has
 * every paid feature without paying.
 *
 * Its credentials come only from the environment — `ADMIN_USERNAME` and
 * `ADMIN_PASSWORD` in the Render dashboard — never from the repo or the app.
 * An APK is a zip anyone can unpack, so a password compiled into it would be
 * public the day the app ships. Unset, the account does not exist and the
 * password route refuses everything.
 */
export const ADMIN_SUB_PREFIX = 'admin:';

export function adminUsername() {
  return normaliseUsername(process.env.ADMIN_USERNAME ?? 'doom');
}

function adminPassword() {
  const value = process.env.ADMIN_PASSWORD;
  return typeof value === 'string' && value.length > 0 ? value : null;
}

export function adminEnabled() {
  return Boolean(adminUsername() && adminPassword());
}

/**
 * Constant-time password check.
 *
 * Both sides are hashed first so the comparison is always over equal-length
 * buffers — `timingSafeEqual` refuses unequal ones, and an early return on
 * length would leak the password's length through timing.
 */
export function checkAdminLogin(username, password) {
  if (!adminEnabled()) return false;
  if (normaliseUsername(username) !== adminUsername()) return false;
  if (typeof password !== 'string') return false;

  const digest = (s) => createHash('sha256').update(s, 'utf8').digest();
  return timingSafeEqual(digest(password), digest(adminPassword()));
}

/**
 * Creates the admin's user document on startup, so the username is reserved
 * before any Google user can claim it.
 */
export async function ensureAdminUser() {
  if (!adminEnabled()) return;
  const username = adminUsername();
  const now = new Date();

  try {
    await users().updateOne(
      { googleSub: `${ADMIN_SUB_PREFIX}${username}` },
      {
        $set: { username, role: 'admin', updatedAt: now },
        $setOnInsert: {
          googleSub: `${ADMIN_SUB_PREFIX}${username}`,
          email: null,
          displayName: username,
          signingPublicKey: null,
          fingerprint: null,
          createdAt: now,
        },
      },
      { upsert: true },
    );
  } catch (e) {
    if (e?.code === 11000) {
      // A Google user already holds the name. Refuse loudly rather than
      // handing their account to whoever knows the admin password.
      console.error(
        `Admin username "${username}" is already taken by another account. ` +
          'Set ADMIN_USERNAME to a different name.',
      );
      return;
    }
    throw e;
  }
}
