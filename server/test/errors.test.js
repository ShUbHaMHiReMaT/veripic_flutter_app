import assert from 'node:assert/strict';
import { after, before, describe, it } from 'node:test';

import jwt from 'jsonwebtoken';

import { createApp } from '../src/app.js';

/**
 * Runs with no database connected on purpose: every data route then throws
 * inside an async handler, which is exactly what a dropped Atlas connection
 * looks like in production.
 */
describe('server errors', () => {
  let server;
  let base;
  let token;

  before(() => {
    process.env.JWT_SECRET ||= 'test-secret-'.repeat(4);
    token = jwt.sign({ sub: 'google-sub-1' }, process.env.JWT_SECRET, {
      expiresIn: '1h',
    });
    server = createApp().listen(0);
    base = `http://127.0.0.1:${server.address().port}`;
  });

  after(() => server.close());

  it('answers 500 instead of crashing when an async handler fails', async () => {
    const res = await fetch(`${base}/users/someone`, {
      headers: { authorization: `Bearer ${token}` },
    });
    assert.equal(res.status, 500);
    assert.deepEqual(await res.json(), {
      error: 'Something went wrong on the server.',
    });

    // Still serving afterwards.
    const health = await fetch(`${base}/health`);
    assert.equal(health.status, 200);
  });
});
