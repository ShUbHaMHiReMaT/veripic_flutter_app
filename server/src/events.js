import { getDb } from './db.js';

/**
 * Activity log.
 *
 * Every meaningful thing an account does lands here, so the database is a
 * record of what happened rather than only a snapshot of what is true now.
 * That matters the first time somebody says "I paid and got nothing" — a
 * current-state-only database cannot answer it.
 *
 * Deliberately excluded: photo contents, coordinates, and anything derived
 * from them. The server cannot read a sealed photo and should not learn from
 * the log what it could not learn from the blob.
 */
export const EVENTS = {
  signedUp: 'auth.signed_up',
  signedIn: 'auth.signed_in',
  usernameClaimed: 'username.claimed',
  keysPublished: 'keys.published',
  orderCreated: 'payment.order_created',
  paymentPaid: 'payment.paid',
  paymentRejected: 'payment.rejected',
  shareSent: 'share.sent',
  shareOpened: 'share.opened',
  checkRun: 'photo.checked',
};

/** Rolling counters kept on the user, so a profile needs no aggregation. */
const COUNTERS = {
  [EVENTS.signedIn]: 'stats.logins',
  [EVENTS.shareSent]: 'stats.photosSent',
  [EVENTS.shareOpened]: 'stats.photosReceived',
  [EVENTS.checkRun]: 'stats.checksRun',
  [EVENTS.paymentPaid]: 'stats.payments',
};

/**
 * Records one event and bumps the matching counter.
 *
 * Never throws: an analytics write must not be able to fail a payment or lose
 * a photo. A missing log line is a smaller problem than a refused action.
 */
export async function logEvent(googleSub, type, data = {}) {
  try {
    const db = getDb();
    await db.collection('events').insertOne({
      googleSub,
      type,
      data,
      at: new Date(),
    });

    const counter = COUNTERS[type];
    const update = { $set: { lastSeenAt: new Date() } };
    if (counter) update.$inc = { [counter]: 1 };

    await db.collection('users').updateOne({ googleSub }, update);
  } catch (e) {
    console.error('logEvent failed:', type, e.message);
  }
}

/** Most recent activity for one account, newest first. */
export async function recentEvents(googleSub, limit = 50) {
  return getDb()
    .collection('events')
    .find({ googleSub })
    .sort({ at: -1 })
    .limit(Math.min(limit, 200))
    .toArray();
}

export async function createEventIndexes() {
  const events = getDb().collection('events');
  await events.createIndex({ googleSub: 1, at: -1 });
  await events.createIndex({ type: 1, at: -1 });

  // Keep the log from growing without bound on a 512 MB cluster. Ninety days
  // is long enough to settle a payment dispute.
  await events
    .createIndex({ at: 1 }, { expireAfterSeconds: 90 * 24 * 60 * 60 })
    .catch(() => {});
}
