import { createHash } from 'node:crypto';

/**
 * Validation for the sharing code a phone publishes.
 *
 * The app signs photos with ECDSA P-256 and embeds the public half, so what
 * arrives here must be a compressed point on that curve: 33 bytes, with a
 * leading 0x02 or 0x03. Anything else is either a bug in the client or someone
 * poking at the API, and storing it would put a key in the directory that can
 * never verify anything.
 */
export function isValidSharingCode(publicKeyB64) {
  if (typeof publicKeyB64 !== 'string' || publicKeyB64.length > 128) {
    return false;
  }

  let raw;
  try {
    raw = Buffer.from(publicKeyB64, 'base64');
  } catch {
    return false;
  }

  // Round-trip so padding tricks and non-base64 junk are rejected rather than
  // silently normalised into something different from what the client sent.
  if (raw.toString('base64') !== publicKeyB64) return false;
  if (raw.length !== 33) return false;
  return raw[0] === 0x02 || raw[0] === 0x03;
}

/**
 * The short code users read to each other, derived exactly the way
 * `IdentityService.fingerprintOf` derives it in the app.
 *
 * Always computed here, never accepted from the client: a fingerprint the
 * server did not derive is just a label an attacker chose, and it is the one
 * thing users compare out of band.
 */
export function fingerprintOf(publicKeyB64) {
  return createHash('sha256').update(publicKeyB64, 'utf8').digest('hex').slice(0, 16);
}

const USERNAME_RE = /^[a-z0-9_]{3,20}$/;

/** Lowercase, so `Ravi` and `ravi` cannot both exist and be confused. */
export function normaliseUsername(input) {
  if (typeof input !== 'string') return null;
  const value = input.trim().toLowerCase();
  return USERNAME_RE.test(value) ? value : null;
}

/** Escapes a user-supplied search term before it reaches a regex query. */
export function escapeRegex(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
