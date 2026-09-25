import assert from 'node:assert/strict';
import { createHmac } from 'node:crypto';
import { after, before, describe, it } from 'node:test';

import jwt from 'jsonwebtoken';

import { createApp } from '../src/app.js';
import { close, connect, getDb, users } from '../src/db.js';
import { PLANS, PRO_DAYS } from '../src/payments.js';

const HAS_DB = Boolean(process.env.MONGODB_URI);

describe('payment verification', { skip: !HAS_DB }, () => {
  let server;
  let base;
  const sub = 'pay-test-dave';
  const orderId = 'order_TEST123';
  const renewalId = 'order_TEST456';
  const DAY = 24 * 60 * 60 * 1000;
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
    await getDb().collection('payments').deleteMany({ orderId: { $in: [orderId, renewalId] } });

    const now = new Date();
    await users().insertOne({
      googleSub: sub,
      username: 'dave_pay',
      email: 'dave@example.com',
      createdAt: now,
      updatedAt: now,
    });
    const user = await users().findOne({ googleSub: sub });
    token = jwt.sign({ sub, uid: user._id.toString() }, process.env.JWT_SECRET);

    // Stand in for an order Razorpay already created.
    await getDb().collection('payments').insertOne({
      orderId,
      googleSub: sub,
      plan: 'pro',
      amount: PLANS.pro.amount,
      status: 'created',
      createdAt: now,
    });

    server = createApp().listen(0);
    await new Promise((r) => server.once('listening', r));
    base = `http://127.0.0.1:${server.address().port}`;
  });

  after(async () => {
    await users().deleteMany({ googleSub: sub });
    await getDb().collection('payments').deleteMany({ orderId: { $in: [orderId, renewalId] } });
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
    assert.equal(user.proUntil, undefined);
  });

  const sign = (order, paymentId) =>
    createHmac('sha256', secret).update(`${order}|${paymentId}`).digest('hex');

  it('grants a month of Pro on a signature Razorpay would have produced', async () => {
    const paymentId = 'pay_REAL123';
    const res = await call('/payments/verify', {
      token,
      method: 'POST',
      body: { orderId, paymentId, signature: sign(orderId, paymentId) },
    });

    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.pro, true);
    assert.equal(body.user.pro, true);

    const left = new Date(body.proUntil).getTime() - Date.now();
    assert.ok(Math.abs(left - PRO_DAYS * DAY) < 60_000, `unexpected period ${left}`);
  });

  it('does not grant the same payment twice', async () => {
    const before = (await users().findOne({ googleSub: sub })).proUntil;
    const paymentId = 'pay_REAL123';
    const res = await call('/payments/verify', {
      token,
      method: 'POST',
      body: { orderId, paymentId, signature: sign(orderId, paymentId) },
    });

    assert.equal(res.status, 200);
    const after = (await users().findOne({ googleSub: sub })).proUntil;
    assert.equal(after.getTime(), before.getTime());
  });

  it('a renewal stacks on top of the time already left', async () => {
    const before = (await users().findOne({ googleSub: sub })).proUntil;
    await getDb().collection('payments').insertOne({
      orderId: renewalId,
      googleSub: sub,
      plan: 'pro',
      amount: PLANS.pro.amount,
      status: 'created',
      createdAt: new Date(),
    });

    const paymentId = 'pay_RENEW1';
    const res = await call('/payments/verify', {
      token,
      method: 'POST',
      body: { orderId: renewalId, paymentId, signature: sign(renewalId, paymentId) },
    });

    assert.equal(res.status, 200);
    const after = (await users().findOne({ googleSub: sub })).proUntil;
    assert.equal(after.getTime() - before.getTime(), PRO_DAYS * DAY);
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

  it('reports an expired period as not Pro', async () => {
    await users().updateOne(
      { googleSub: sub },
      { $set: { proUntil: new Date(Date.now() - DAY) } },
    );
    const body = await (await call('/payments/entitlements', { token })).json();
    assert.equal(body.pro, false);
    assert.deepEqual(body.entitlements, []);
  });

  it('needs a session to see entitlements', async () => {
    assert.equal((await call('/payments/entitlements')).status, 401);
  });
});
