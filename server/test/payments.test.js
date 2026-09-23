import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { after, before, describe, it } from 'node:test';

import jwt from 'jsonwebtoken';

import { createApp } from '../src/app.js';
import { close, connect, getDb, users } from '../src/db.js';
import { PLANS } from '../src/payments.js';

const HAS_DB = Boolean(process.env.MONGODB_URI);

describe('payment verification', { skip: !HAS_DB }, () => {
  let server;
  let base;
  const sub = 'pay-test-dave';
  const orderId = 'order_TEST123';
  const secret = 'test-razorpay-secret';

  const call = (path, { token, method = 'GET', body } = {}) =>
    fetch(`${base}${path}`, {
      method,
      headers: {
        'content-type': 'application/json',
        ...(token ? { authorization: `Bearer ${token}` } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });

  let token;

  before(async () => {
    process.env.JWT_SECRET ??= 'test-secret';
    process.env.RAZORPAY_KEY_ID = 'rzp_test_dummy';
    process.env.RAZORPAY_KEY_SECRET = secret;

    await connect();
    await users().deleteMany({ googleSub: sub });
    await getDb().collection('payments').deleteMany({ orderId });

    const now = new Date();
    await users().insertOne({
      googleSub: sub,
      username: 'dave_pay',
      email: 'dave@example.com',
      entitlements: [],
      createdAt: now,
      updatedAt: now,
    });
    const user = await users().findOne({ googleSub: sub });
    token = jwt.sign({ sub, uid: user._id.toString() }, process.env.JWT_SECRET);

    // Stand in for an order Razorpay already created.
    await getDb().collection('payments').insertOne({
      orderId,
      googleSub: sub,
      plan: 'verify',
      amount: PLANS.verify.amount,
      status: 'created',
      createdAt: now,
    });

    server = createApp().listen(0);
    await new Promise((r) => server.once('listening', r));
    base = `http://127.0.0.1:${server.address().port}`;
  });

  after(async () => {
    await users().deleteMany({ googleSub: sub });
    await getDb().collection('payments').deleteMany({ orderId });
    server?.close();
    await close();
  });

  it('exposes the key id but never the secret', async () => {
    const res = await call('/payments/config');
    const body = await res.json();

    assert.equal(body.keyId, 'rzp_test_dummy');
    assert.equal(body.enabled, true);
    // The one thing that must never reach a phone.
    assert.equal(JSON.stringify(body).includes(secret), false);
  });

  it('grants nothing on a forged signature', async () => {
    const res = await call('/payments/verify', {
      token,
      method: 'POST',
      body: { orderId, paymentId: 'pay_FAKE', signature: 'f'.repeat(64) },
    });

    assert.equal(res.status, 400);
    const user = await users().findOne({ googleSub: sub });
    assert.deepEqual(user.entitlements, []);
  });

  it('grants the plan on a signature Razorpay would have produced', async () => {
    const paymentId = 'pay_REAL123';
    const signature = createHmac('sha256', secret)
      .update(`${orderId}|${paymentId}`)
      .digest('hex');

    const res = await call('/payments/verify', {
      token,
      method: 'POST',
      body: { orderId, paymentId, signature },
    });

    assert.equal(res.status, 200);
    assert.deepEqual((await res.json()).entitlements, ['verify']);
  });

  it('refuses to verify somebody else\'s order', async () => {
    const stranger = jwt.sign(
      { sub: 'pay-test-stranger', uid: '000000000000000000000000' },
      process.env.JWT_SECRET,
    );
    const res = await call('/payments/verify', {
      token: stranger,
      method: 'POST',
      body: { orderId, paymentId: 'x', signature: 'y' },
    });
    assert.equal(res.status, 404);
  });

  it('needs a session to see entitlements', async () => {
    assert.equal((await call('/payments/entitlements')).status, 401);
  });
});
