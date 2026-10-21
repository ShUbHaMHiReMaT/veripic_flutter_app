import assert from 'node:assert/strict';
import { beforeEach, describe, it } from 'node:test';

import {
  LATEST_RELEASE,
  latestRelease,
  releaseAvailable,
  resetReleaseCheck,
} from '../src/release.js';

const answering = (status) => async () => ({ status });

describe('update banner', () => {
  beforeEach(resetReleaseCheck);

  it('offers the build once GitHub redirects to the APK', async () => {
    const body = await latestRelease(answering(302), 1_000);
    assert.equal(body.build, LATEST_RELEASE.build);
    assert.equal(body.url, LATEST_RELEASE.url);
  });

  it('offers nothing while no release carries the APK', async () => {
    // Every installed build is above 0, so the app shows no banner rather
    // than a button that opens an empty page.
    const body = await latestRelease(answering(404), 1_000);
    assert.equal(body.build, 0);
  });

  it('reuses one answer for ten minutes, then asks again', async () => {
    let calls = 0;
    const counting = async () => {
      calls++;
      return { status: 302 };
    };
    await releaseAvailable(counting, 1_000);
    await releaseAvailable(counting, 1_000 + 9 * 60_000);
    assert.equal(calls, 1);
    await releaseAvailable(counting, 1_000 + 11 * 60_000);
    assert.equal(calls, 2);
  });

  it('keeps the last answer when GitHub cannot be reached', async () => {
    await releaseAvailable(answering(302), 1_000);
    const failing = async () => {
      throw new Error('offline');
    };
    assert.equal(await releaseAvailable(failing, 1_000 + 11 * 60_000), true);
  });
});
