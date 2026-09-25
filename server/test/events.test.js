import assert from 'node:assert/strict';
import { after, before, describe, it } from 'node:test';

import jwt from 'jsonwebtoken';

import { createApp } from '../src/app.js';
import { close, connect, getDb, users } from '../src/db.js';
import { EVENTS, logEvent, recentEvents } from '../src/events.js';
import { PLANS } from '../src/payments.js';

const HAS_DB = Boolean(process.env.MONGODB_URI);

describe('the paid plan', () => {
  it('is a single Pro plan that lasts a month', () => {
    assert.deepEqual(Object.keys(PLANS), ['pro']);
    assert.equal(PLANS.pro.days, 30);
  });

  it('prices every plan server-side', () => {
    for (const plan of Object.values(PLANS)) {
      assert.equal(typeof plan.amount, 'number');
      // Razorpay's minimum is 100 paise; anything lower is rejected at the
      // gateway rather than here, which is a confusing place to find out.
      assert.ok(plan.amount >= 100, `${plan.id} is below Rs 1`);
    }
  });
});

describe('activity log', { skip: !HAS_DB }, () => {
  let server;
  let base;
  const sub = 'events-test-erin';
  let token;

  before(async () => {
    process.env.JWT_SECRET ??= 'test-secret';
    await connect();
    await users().deleteMany({ googleSub: sub });
    await getDb().collection('events').deleteMany({ googleSub: sub });

    await users().insertOne({
      googleSub: sub,
      username: 'erin_events',
      email: 'erin@example.com',
      entitlements: [],
      createdAt: new Date(),
      updatedAt: new Date(),
    });
    const user = await users().findOne({ googleSub: sub });
    token = jwt.sign({ sub, uid: user._id.toString() }, process.env.JWT_SECRET);

    server = createApp().listen(0);
    await new Promise((r) => server.once('listening', r));
    base = `http://127.0.0.1:${server.address().port}`;
  });

  after(async () => {
    await users().deleteMany({ googleSub: sub });
    await getDb().collection('events').deleteMany({ googleSub: sub });
    server?.close();
    await close();
  });

  it('records an event and bumps the matching counter', async () => {
    await logEvent(sub, EVENTS.checkRun, { verdict: 'authentic' });
    await logEvent(sub, EVENTS.checkRun, { verdict: 'tampered' });

    const rows = await recentEvents(sub);
    assert.equal(rows.length, 2);
    assert.equal(rows[0].type, EVENTS.checkRun);

    const user = await users().findOne({ googleSub: sub });
    assert.equal(user.stats.checksRun, 2);
    assert.ok(user.lastSeenAt instanceof Date);
  });

  it('never throws, so logging cannot fail a payment', async () => {
    // Undefined subject, junk payload: it has to swallow this. An analytics
    // write that can throw is an analytics write that can lose a photo.
    await assert.doesNotReject(() => logEvent(undefined, 'weird.type', null));
  });

  it('serves the account its own activity', async () => {
    const res = await fetch(`${base}/me/activity`, {
      headers: { authorization: `Bearer ${token}` },
    });
    assert.equal(res.status, 200);

    const { events } = await res.json();
    assert.ok(events.length >= 2);
    assert.ok(events[0].type);
    assert.ok(events[0].at);
  });

  it('records a check reported by the app, verdict only', async () => {
    const res = await fetch(`${base}/events/checked`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({
        verdict: 'authentic',
        // Things the app must never be able to push into the log.
        latitude: 15.8497,
        photo: 'AAAA',
      }),
    });
    assert.equal(res.status, 200);

    const rows = await recentEvents(sub);
    const logged = rows.find((r) => r.type === EVENTS.checkRun);
    assert.equal(logged.data.verdict, 'authentic');
    assert.equal(logged.data.latitude, undefined);
    assert.equal(logged.data.photo, undefined);
  });

  it('needs a session to read activity', async () => {
    assert.equal((await fetch(`${base}/me/activity`)).status, 401);
  });
});
