import assert from 'node:assert/strict';
import { Buffer } from 'node:buffer';
import { createHash, randomBytes } from 'node:crypto';
import { after, before, describe, it } from 'node:test';

import jwt from 'jsonwebtoken';

import { createApp } from '../src/app.js';
import { close, connect, getDb, users } from '../src/db.js';

const HAS_DB = Boolean(process.env.MONGODB_URI);

function key(seed) {
  return Buffer.concat([Buffer.from([0x02]), Buffer.alloc(32, seed)]).toString('base64');
}

describe('encrypted photo delivery', { skip: !HAS_DB }, () => {
  let server;
  let base;
  const subs = ['share-test-alice', 'share-test-bob', 'share-test-carol'];

  const tokenFor = async (googleSub) => {
    const user = await users().findOne({ googleSub });
    return jwt.sign({ sub: googleSub, uid: user._id.toString() }, process.env.JWT_SECRET);
  };

  const call = (path, { token, method = 'GET', body, raw = false } = {}) =>
    fetch(`${base}${path}`, {
      method,
      headers: {
        ...(raw ? {} : { 'content-type': 'application/json' }),
        ...(token ? { authorization: `Bearer ${token}` } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
    });

  before(async () => {
    process.env.JWT_SECRET ??= 'test-secret';
    await connect();
    await users().deleteMany({ googleSub: { $in: subs } });
    await getDb().collection('shares').deleteMany({
      toUsername: { $in: ['bob_share', 'carol_share'] },
    });

    const now = new Date();
    await users().insertMany([
      {
        googleSub: subs[0],
        username: 'alice_share',
        signingPublicKey: key(1),
        encryptionPublicKey: key(2),
        fingerprint: 'a'.repeat(16),
        createdAt: now,
        updatedAt: now,
      },
      {
        googleSub: subs[1],
        username: 'bob_share',
        signingPublicKey: key(3),
        encryptionPublicKey: key(4),
        fingerprint: 'b'.repeat(16),
        createdAt: now,
        updatedAt: now,
      },
      {
        // Signed up, published a signing key, but cannot receive yet.
        googleSub: subs[2],
        username: 'carol_share',
        signingPublicKey: key(5),
        encryptionPublicKey: null,
        fingerprint: 'c'.repeat(16),
        createdAt: now,
        updatedAt: now,
      },
    ]);

    server = createApp().listen(0);
    await new Promise((r) => server.once('listening', r));
    base = `http://127.0.0.1:${server.address().port}`;
  });

  after(async () => {
    await users().deleteMany({ googleSub: { $in: subs } });
    await getDb().collection('shares').deleteMany({
      toUsername: { $in: ['bob_share', 'carol_share'] },
    });
    server?.close();
    await close();
  });

  it('carries an encrypted photo from one user to another, byte for byte', async () => {
    // Stand-in for a sealed JPEG. The server must never alter a single byte:
    // the photo's own signature is computed over exactly these bytes.
    const ciphertext = randomBytes(64 * 1024);
    const sha256 = createHash('sha256').update(ciphertext).digest('hex');

    const alice = await tokenFor(subs[0]);
    const sent = await call('/shares', {
      token: alice,
      method: 'POST',
      body: {
        toUsername: 'bob_share',
        ciphertextB64: ciphertext.toString('base64'),
        wrappedKey: randomBytes(60).toString('base64'),
        ephemeralPublicKey: key(9),
        sha256,
      },
    });
    assert.equal(sent.status, 201);

    const bob = await tokenFor(subs[1]);
    const inbox = await (await call('/shares/inbox', { token: bob })).json();
    const item = inbox.shares.find((s) => s.sha256 === sha256);
    assert.ok(item, 'the share should be in Bob\'s inbox');
    assert.equal(item.fromUsername, 'alice_share');

    const blobRes = await call(`/shares/${item.id}/blob`, { token: bob, raw: true });
    assert.equal(blobRes.status, 200);
    const received = Buffer.from(await blobRes.arrayBuffer());

    assert.deepEqual(received, ciphertext);

    const gone = await call(`/shares/${item.id}`, { token: bob, method: 'DELETE' });
    assert.equal(gone.status, 200);
  });

  it('never lets a third party fetch the blob', async () => {
    const ciphertext = randomBytes(1024);
    const alice = await tokenFor(subs[0]);
    const sent = await (
      await call('/shares', {
        token: alice,
        method: 'POST',
        body: {
          toUsername: 'bob_share',
          ciphertextB64: ciphertext.toString('base64'),
          wrappedKey: randomBytes(60).toString('base64'),
          ephemeralPublicKey: key(9),
          sha256: createHash('sha256').update(ciphertext).digest('hex'),
        },
      })
    ).json();

    // Carol has a valid session and the share id, and still gets nothing.
    const carol = await tokenFor(subs[2]);
    const res = await call(`/shares/${sent.share.id}/blob`, { token: carol, raw: true });
    assert.equal(res.status, 404);
  });

  it('rejects a body whose hash does not match', async () => {
    const alice = await tokenFor(subs[0]);
    const res = await call('/shares', {
      token: alice,
      method: 'POST',
      body: {
        toUsername: 'bob_share',
        ciphertextB64: randomBytes(512).toString('base64'),
        wrappedKey: randomBytes(60).toString('base64'),
        ephemeralPublicKey: key(9),
        sha256: 'f'.repeat(64),
      },
    });
    // Storing a wrong hash would make the recipient report a perfectly good
    // photo as tampered with.
    assert.equal(res.status, 400);
  });

  it('refuses a recipient who cannot receive yet', async () => {
    const ciphertext = randomBytes(256);
    const alice = await tokenFor(subs[0]);
    const res = await call('/shares', {
      token: alice,
      method: 'POST',
      body: {
        toUsername: 'carol_share',
        ciphertextB64: ciphertext.toString('base64'),
        wrappedKey: randomBytes(60).toString('base64'),
        ephemeralPublicKey: key(9),
        sha256: createHash('sha256').update(ciphertext).digest('hex'),
      },
    });
    assert.equal(res.status, 404);
  });

  it('needs a session', async () => {
    const res = await call('/shares/inbox');
    assert.equal(res.status, 401);
  });
});
