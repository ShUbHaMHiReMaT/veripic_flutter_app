import assert from 'node:assert/strict';
import { after, before, describe, it } from 'node:test';

import { checkAdminLogin } from '../src/admin.js';
import { createApp } from '../src/app.js';
import { close, connect, users } from '../src/db.js';

const HAS_DB = Boolean(process.env.MONGODB_URI);

describe('admin password check', () => {
  before(() => {
    process.env.ADMIN_USERNAME = 'doom_test';
    process.env.ADMIN_PASSWORD = 'correct-horse';
  });

  it('accepts only the configured name and password', () => {
    assert.equal(checkAdminLogin('doom_test', 'correct-horse'), true);
    assert.equal(checkAdminLogin('DOOM_test', 'correct-horse'), true);
    assert.equal(checkAdminLogin('doom_test', 'wrong'), false);
    assert.equal(checkAdminLogin('someone', 'correct-horse'), false);
    assert.equal(checkAdminLogin('doom_test', undefined), false);
  });

  it('is off entirely when no password is configured', () => {
    const saved = process.env.ADMIN_PASSWORD;
    delete process.env.ADMIN_PASSWORD;
    try {
      assert.equal(checkAdminLogin('doom_test', ''), false);
    } finally {
      process.env.ADMIN_PASSWORD = saved;
    }
  });
});

describe('admin sign-in', { skip: !HAS_DB }, () => {
  let server;
  let base;

  const post = (path, body, token) =>
    fetch(`${base}${path}`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        ...(token ? { authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify(body),
    });

  before(async () => {
    process.env.JWT_SECRET ??= 'test-secret';
    process.env.ADMIN_USERNAME = 'doom_test';
    process.env.ADMIN_PASSWORD = 'correct-horse';
    await connect();
    await users().deleteMany({ username: 'doom_test' });
    server = createApp().listen(0);
    await new Promise((r) => server.once('listening', r));
    base = `http://127.0.0.1:${server.address().port}`;
  });

  after(async () => {
    await users().deleteMany({ username: 'doom_test' });
    server?.close();
    await close();
  });

  it('refuses a wrong password with the same message as a wrong name', async () => {
    const a = await post('/auth/password', { username: 'doom_test', password: 'nope' });
    const b = await post('/auth/password', { username: 'nobody', password: 'nope' });
    assert.equal(a.status, 401);
    assert.equal(b.status, 401);
    assert.deepEqual(await a.json(), await b.json());
  });

  it('signs the admin in with Pro and no expiry', async () => {
    const res = await post('/auth/password', {
      username: 'doom_test',
      password: 'correct-horse',
    });
    assert.equal(res.status, 200);
    const body = await res.json();
    assert.equal(body.user.username, 'doom_test');
    assert.equal(body.user.pro, true);
    assert.equal(body.user.admin, true);
    assert.equal(body.needsUsername, false);

    const me = await fetch(`${base}/me`, {
      headers: { authorization: `Bearer ${body.token}` },
    });
    assert.equal((await me.json()).user.pro, true);
  });

  it('reserves the admin username against everyone else', async () => {
    await users().insertOne({ googleSub: 'test-sub-squatter', username: null });
    try {
      const jwt = (await import('jsonwebtoken')).default;
      const u = await users().findOne({ googleSub: 'test-sub-squatter' });
      const token = jwt.sign(
        { sub: 'test-sub-squatter', uid: u._id.toString() },
        process.env.JWT_SECRET,
      );
      const res = await post('/me/username', { username: 'doom_test' }, token);
      assert.equal(res.status, 409);
    } finally {
      await users().deleteMany({ googleSub: 'test-sub-squatter' });
    }
  });
});
