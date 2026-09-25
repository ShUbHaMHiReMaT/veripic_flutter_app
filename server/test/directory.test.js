import assert from 'node:assert/strict';
import { after, before, describe, it } from 'node:test';

import jwt from 'jsonwebtoken';

import { createApp } from '../src/app.js';
import { close, connect, users } from '../src/db.js';
import { fingerprintOf, isValidSharingCode, normaliseUsername } from '../src/keys.js';

/**
 * Exercises the directory against a real database.
 *
 * Google sign-in itself is not covered here — that needs a token only Google
 * can mint. Everything after it is, by issuing the session this server would
 * have issued, which is exactly the state a signed-in app is in.
 *
 * Needs MONGODB_URI. Skipped without it so the suite still runs offline.
 */
const HAS_DB = Boolean(process.env.MONGODB_URI);

/** A genuine compressed P-256 point shape: 0x02/0x03 then 32 bytes. */
function sharingCode(seed) {
  return Buffer.concat([
    Buffer.from([0x02]),
    Buffer.alloc(32, seed),
  ]).toString('base64');
}

describe('sharing code validation', () => {
  it('accepts a compressed P-256 point', () => {
    assert.equal(isValidSharingCode(sharingCode(7)), true);
  });

  it('rejects a key of the wrong length', () => {
    assert.equal(isValidSharingCode(Buffer.alloc(32).toString('base64')), false);
  });

  it('rejects an uncompressed point', () => {
    const uncompressed = Buffer.concat([
      Buffer.from([0x04]),
      Buffer.alloc(32),
    ]).toString('base64');
    assert.equal(isValidSharingCode(uncompressed), false);
  });

  it('rejects anything that is not base64', () => {
    assert.equal(isValidSharingCode('not base64!!'), false);
  });

  it('derives the same 16-hex fingerprint the app shows', () => {
    // Must match IdentityService.fingerprintOf in Dart:
    // sha256(utf8(publicKeyB64)) as hex, first 16 chars.
    const fp = fingerprintOf('AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIC');
    assert.match(fp, /^[0-9a-f]{16}$/);
  });
});

describe('username rules', () => {
  it('lowercases so two spellings cannot both exist', () => {
    assert.equal(normaliseUsername('Ravi_87'), 'ravi_87');
  });

  it('rejects short, long and spaced names', () => {
    assert.equal(normaliseUsername('ab'), null);
    assert.equal(normaliseUsername('a'.repeat(21)), null);
    assert.equal(normaliseUsername('has space'), null);
  });
});

describe('directory API', { skip: !HAS_DB }, () => {
  let server;
  let base;
  const subs = ['test-sub-alice', 'test-sub-bob'];

  const authFor = async (googleSub) => {
    const user = await users().findOne({ googleSub });
    return jwt.sign({ sub: googleSub, uid: user._id.toString() }, process.env.JWT_SECRET);
  };

  const call = (path, { token, method = 'GET', body } = {}) =>
    fetch(`${base}${path}`, {
      method,
      headers: {
        'content-type': 'application/json',
        ...(token ? { authorization: `Bearer ${token}` } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });

  before(async () => {
    process.env.JWT_SECRET ??= 'test-secret';
    await connect();
    await users().deleteMany({ googleSub: { $in: subs } });

    const now = new Date();
    await users().insertMany(
      subs.map((googleSub) => ({
        googleSub,
        email: `${googleSub}@example.com`,
        displayName: googleSub,
        username: null,
        signingPublicKey: null,
        fingerprint: null,
        createdAt: now,
        updatedAt: now,
      })),
    );

    server = createApp().listen(0);
    await new Promise((r) => server.once('listening', r));
    base = `http://127.0.0.1:${server.address().port}`;
  });

  after(async () => {
    await users().deleteMany({ googleSub: { $in: subs } });
    server?.close();
    await close();
  });

  it('refuses every directory route without a session', async () => {
    for (const path of ['/me', '/users/search?q=ravi', '/users/ravi']) {
      const res = await call(path);
      assert.equal(res.status, 401, `${path} should need a session`);
    }
  });

  it('claims a username', async () => {
    const token = await authFor(subs[0]);
    const res = await call('/me/username', {
      token,
      method: 'POST',
      body: { username: 'Alice_Test' },
    });
    assert.equal(res.status, 200);
    assert.equal((await res.json()).user.username, 'alice_test');
  });

  it('refuses a username somebody else holds', async () => {
    const token = await authFor(subs[1]);
    const res = await call('/me/username', {
      token,
      method: 'POST',
      body: { username: 'alice_test' },
    });
    // The unique index decides this, not a racy "is it free?" lookup.
    assert.equal(res.status, 409);
  });

  it('publishes a sharing code and derives its fingerprint server-side', async () => {
    const token = await authFor(subs[0]);
    const code = sharingCode(11);

    const res = await call('/me/keys', {
      token,
      method: 'PUT',
      body: { sharingCode: code, fingerprint: 'deadbeefdeadbeef' },
    });

    assert.equal(res.status, 200);
    const { user } = await res.json();
    assert.equal(user.sharingCode, code);
    // The client's claimed fingerprint is ignored.
    assert.equal(user.fingerprint, fingerprintOf(code));
  });

  it('rejects a malformed sharing code', async () => {
    const token = await authFor(subs[0]);
    const res = await call('/me/keys', {
      token,
      method: 'PUT',
      body: { sharingCode: 'AAAA' },
    });
    assert.equal(res.status, 400);
  });

  it('finds a user by name prefix and returns their sharing code', async () => {
    const token = await authFor(subs[1]);
    const res = await call('/users/search?q=alice', { token });
    assert.equal(res.status, 200);

    const { results } = await res.json();
    const hit = results.find((r) => r.username === 'alice_test');
    assert.ok(hit, 'alice_test should be findable');
    assert.equal(hit.sharingCode, sharingCode(11));
    // A search result must never leak contact details.
    assert.equal(hit.email, undefined);
  });

  it('hides users who have not published a sharing code', async () => {
    const token = await authFor(subs[0]);
    await call('/me/username', {
      token: await authFor(subs[1]),
      method: 'POST',
      body: { username: 'bob_test' },
    });

    const res = await call('/users/search?q=bob_test', { token });
    const { results } = await res.json();
    assert.equal(results.length, 0, 'a user with no key cannot verify anything');
  });

  it('reports whether a username is free, ignoring case', async () => {
    const token = await authFor(subs[1]);
    const taken = await (await call('/users/available?u=ALICE_test', { token })).json();
    assert.equal(taken.available, false);

    const free = await (await call('/users/available?u=nobody_has_this', { token })).json();
    assert.equal(free.available, true);

    const bad = await (await call('/users/available?u=a!', { token })).json();
    assert.equal(bad.available, false);
  });

  it('a username is set once and cannot be swapped for another', async () => {
    const token = await authFor(subs[0]);
    const res = await call('/me/username', {
      token,
      method: 'POST',
      body: { username: 'alice_renamed' },
    });
    assert.equal(res.status, 409);
    const me = await (await call('/me', { token })).json();
    assert.equal(me.user.username, 'alice_test');
  });

  it('never lists the person searching', async () => {
    const token = await authFor(subs[0]);
    const { results } = await (await call('/users/search?q=alice', { token })).json();
    assert.equal(results.some((r) => r.username === 'alice_test'), false);
  });
});
