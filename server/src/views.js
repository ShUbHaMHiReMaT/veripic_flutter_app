/**
 * How a user document is shown to the outside world.
 *
 * Kept in one module so every route that returns a user — sign-in, the
 * directory, payments — agrees on exactly which fields leave the server.
 */

/** Whether the account's Pro month is still running. */
export function isPro(user, now = new Date()) {
  if (isAdmin(user)) return true;
  return Boolean(user?.proUntil && user.proUntil > now);
}

/** The password-login account that has every feature without paying. */
export function isAdmin(user) {
  return user?.role === 'admin';
}

/** What a user looks like to somebody else. Never the email, never the sub. */
export function publicView(user) {
  return {
    username: user.username,
    displayName: user.displayName,
    sharingCode: user.signingPublicKey,
    // Needed to seal a photo to this person. Public by design: it can wrap a
    // key to them and do nothing else.
    encryptionKey: user.encryptionPublicKey ?? null,
    fingerprint: user.fingerprint,
    canReceive: Boolean(user.encryptionPublicKey),
  };
}

/** What a user looks like to themselves. */
export function privateView(user) {
  return {
    ...publicView(user),
    email: user.email,
    photoUrl: user.photoUrl,
    pro: isPro(user),
    admin: isAdmin(user),
    proUntil: user.proUntil ?? null,
  };
}
