import { createHmac, timingSafeEqual } from 'node:crypto';

import express from 'express';

import { requireSession } from './auth.js';
import { getDb, users } from './db.js';
import { EVENTS, logEvent } from './events.js';

/**
 * Razorpay payments.
 *
 * The rule this file exists to enforce: **the client never decides whether it
 * paid.** An app that reports its own success will be lied to, and the lie is
 * a two-line patch to the APK. Every entitlement here is granted only after
 * this server reproduces Razorpay's HMAC over the order and payment ids using
 * the key secret, which never leaves the server.
 */

/** What can be bought, in paise. Server-side so the price cannot be edited. */
export const PLANS = {
  // Test pricing. Rs 1 is Razorpay's minimum charge; raise `amount` here when
  // going live and nothing else has to change, because the app never sends a
  // price — it only names a plan.
  verify: {
    id: 'verify',
    name: 'Photo checking',
    amount: 100, // Rs 1
    description: 'Check whether a photo is real',
  },
  sharing: {
    id: 'sharing',
    name: 'Encrypted sending',
    amount: 100, // Rs 1
    description: 'Send photos to other GeoGuard users',
  },
  certificate: {
    id: 'certificate',
    name: 'Evidence certificate',
    amount: 100, // Rs 1
    description: 'Export the check as a signed PDF report',
  },
};

function keys() {
  const id = process.env.RAZORPAY_KEY_ID;
  const secret = process.env.RAZORPAY_KEY_SECRET;
  if (!id || !secret) throw new Error('Razorpay keys are not configured');
  return { id, secret };
}

/** Razorpay's REST API, called directly so there is no extra dependency. */
async function razorpay(path, { method = 'GET', body } = {}) {
  const { id, secret } = keys();
  const res = await fetch(`https://api.razorpay.com/v1${path}`, {
    method,
    headers: {
      'content-type': 'application/json',
      authorization: `Basic ${Buffer.from(`${id}:${secret}`).toString('base64')}`,
    },
    body: body ? JSON.stringify(body) : undefined,
  });

  const json = await res.json().catch(() => ({}));
  if (!res.ok) {
    throw new Error(json?.error?.description ?? `Razorpay returned ${res.status}`);
  }
  return json;
}

/**
 * Constant-time comparison of two hex signatures.
 *
 * `===` on a signature leaks, through timing, how many leading characters
 * matched — which is enough to forge one a byte at a time.
 */
function signatureMatches(expected, received) {
  if (typeof received !== 'string' || expected.length !== received.length) {
    return false;
  }
  return timingSafeEqual(Buffer.from(expected), Buffer.from(received));
}

export function paymentsRouter() {
  const router = express.Router();
  router.use(express.json({ limit: '16kb' }));

  const payments = () => getDb().collection('payments');

  /** Public config: the key id is meant to be in the app, the secret is not. */
  router.get('/config', (_req, res) => {
    res.json({
      keyId: process.env.RAZORPAY_KEY_ID ?? null,
      enabled: Boolean(process.env.RAZORPAY_KEY_ID && process.env.RAZORPAY_KEY_SECRET),
      plans: Object.values(PLANS),
    });
  });

  router.use(requireSession);

  router.get('/entitlements', async (req, res) => {
    const user = await users().findOne({ googleSub: req.session.sub });
    res.json({ entitlements: user?.entitlements ?? [] });
  });

  router.post('/order', async (req, res) => {
    const plan = PLANS[req.body?.plan];
    if (!plan) return res.status(400).json({ error: 'Unknown plan.' });

    const user = await users().findOne({ googleSub: req.session.sub });
    if (!user) return res.status(404).json({ error: 'Account not found.' });

    try {
      const order = await razorpay('/orders', {
        method: 'POST',
        body: {
          // Amount comes from PLANS, never from the request body.
          amount: plan.amount,
          currency: 'INR',
          receipt: `${plan.id}-${user._id}`.slice(0, 40),
          notes: { plan: plan.id, uid: user._id.toString() },
        },
      });

      await payments().insertOne({
        orderId: order.id,
        googleSub: req.session.sub,
        plan: plan.id,
        amount: plan.amount,
        status: 'created',
        createdAt: new Date(),
      });
      await logEvent(req.session.sub, EVENTS.orderCreated, {
        orderId: order.id,
        plan: plan.id,
        amount: plan.amount,
      });

      return res.json({
        orderId: order.id,
        amount: plan.amount,
        currency: 'INR',
        keyId: keys().id,
        name: plan.name,
        description: plan.description,
        prefillEmail: user.email ?? '',
      });
    } catch (e) {
      console.error('Razorpay order failed:', e.message);
      return res.status(502).json({ error: 'Could not start the payment.' });
    }
  });

  /** The actual gate. Nothing is unlocked anywhere else. */
  router.post('/verify', async (req, res) => {
    const { orderId, paymentId, signature } = req.body ?? {};
    if (!orderId || !paymentId || !signature) {
      return res.status(400).json({ error: 'Incomplete payment details.' });
    }

    const record = await payments().findOne({
      orderId,
      googleSub: req.session.sub,
    });
    if (!record) return res.status(404).json({ error: 'Unknown order.' });

    const expected = createHmac('sha256', keys().secret)
      .update(`${orderId}|${paymentId}`)
      .digest('hex');

    if (!signatureMatches(expected, signature)) {
      await payments().updateOne(
        { orderId },
        { $set: { status: 'invalid_signature', checkedAt: new Date() } },
      );
      await logEvent(req.session.sub, EVENTS.paymentRejected, {
        orderId,
        paymentId,
        reason: 'signature_mismatch',
      });
      return res.status(400).json({ error: 'That payment could not be confirmed.' });
    }

    await payments().updateOne(
      { orderId },
      { $set: { status: 'paid', paymentId, paidAt: new Date() } },
    );
    await users().updateOne(
      { googleSub: req.session.sub },
      { $addToSet: { entitlements: record.plan } },
    );

    await logEvent(req.session.sub, EVENTS.paymentPaid, {
      orderId,
      paymentId,
      plan: record.plan,
      amount: record.amount,
    });

    const user = await users().findOne({ googleSub: req.session.sub });
    return res.json({ entitlements: user.entitlements ?? [] });
  });

  return router;
}

/**
 * Razorpay's server-to-server notification.
 *
 * Needed because people close the app mid-redirect. Without it those payments
 * are taken and never granted. Mounted with a raw body parser, since the
 * signature covers the exact bytes Razorpay sent.
 */
export function webhookRouter() {
  const router = express.Router();
  router.use(express.raw({ type: '*/*', limit: '1mb' }));

  router.post('/', async (req, res) => {
    const secret = process.env.RAZORPAY_WEBHOOK_SECRET;
    if (!secret) return res.status(503).end();

    const expected = createHmac('sha256', secret).update(req.body).digest('hex');
    if (!signatureMatches(expected, req.get('x-razorpay-signature') ?? '')) {
      return res.status(400).end();
    }

    let event;
    try {
      event = JSON.parse(req.body.toString('utf8'));
    } catch {
      return res.status(400).end();
    }

    if (event.event === 'payment.captured') {
      const orderId = event.payload?.payment?.entity?.order_id;
      const record = await getDb().collection('payments').findOne({ orderId });
      if (record && record.status !== 'paid') {
        await getDb().collection('payments').updateOne(
          { orderId },
          { $set: { status: 'paid', paidAt: new Date(), viaWebhook: true } },
        );
        await users().updateOne(
          { googleSub: record.googleSub },
          { $addToSet: { entitlements: record.plan } },
        );
        await logEvent(record.googleSub, EVENTS.paymentPaid, {
          orderId,
          plan: record.plan,
          amount: record.amount,
          viaWebhook: true,
        });
      }
    }

    return res.json({ ok: true });
  });

  return router;
}
