import { Buffer } from 'node:buffer';
import { createHash } from 'node:crypto';

import express from 'express';
import { GridFSBucket, ObjectId } from 'mongodb';

import { requireSession } from './auth.js';
import { getDb, users } from './db.js';
import { EVENTS, logEvent } from './events.js';
import { normaliseUsername } from './keys.js';

/**
 * Encrypted photo delivery.
 *
 * The server stores an opaque blob and some routing metadata. It holds no key
 * and can decrypt nothing: the file key is wrapped to the recipient's public
 * key on the sending phone. That is not only a privacy property — it is what
 * keeps the photo's own signature intact, because nothing in the path can
 * re-encode bytes it cannot read.
 */

/** Free-tier Atlas gives 512 MB total. Leave most of it for documents. */
const MAX_BLOB_BYTES = 12 * 1024 * 1024;
const MAX_PENDING_PER_USER = 25;

export function sharesRouter() {
  const router = express.Router();

  // Photos are large, so this router parses a bigger body than the rest of
  // the API. Scoped here deliberately: a 20 MB limit on the auth routes would
  // be an easy way to exhaust the instance's memory.
  router.use(express.json({ limit: '20mb' }));
  router.use(requireSession);

  const bucket = () => new GridFSBucket(getDb(), { bucketName: 'shareBlobs' });
  const shares = () => getDb().collection('shares');

  /** Metadata view. Never includes the blob. */
  const view = (doc) => ({
    id: doc._id.toString(),
    fromUsername: doc.fromUsername,
    wrappedKey: doc.wrappedKey,
    ephemeralPublicKey: doc.ephemeralPublicKey,
    sha256: doc.sha256,
    bytes: doc.bytes,
    sentAt: doc.sentAt,
  });

  // -------------------------------------------------------------------
  // Send
  // -------------------------------------------------------------------

  router.post('/', async (req, res) => {
    const {
      toUsername,
      ciphertextB64,
      wrappedKey,
      ephemeralPublicKey,
      sha256,
    } = req.body ?? {};

    const to = normaliseUsername(toUsername);
    if (!to) return res.status(400).json({ error: 'Bad username.' });

    if (
      typeof ciphertextB64 !== 'string' ||
      typeof wrappedKey !== 'string' ||
      typeof ephemeralPublicKey !== 'string' ||
      typeof sha256 !== 'string'
    ) {
      return res.status(400).json({ error: 'Incomplete share.' });
    }

    const sender = await users().findOne({ googleSub: req.session.sub });
    if (!sender?.username) {
      return res.status(400).json({ error: 'Pick a username before sending.' });
    }

    const recipient = await users().findOne({ username: to });
    if (!recipient?.encryptionPublicKey) {
      return res.status(404).json({
        error: 'That user cannot receive photos yet.',
      });
    }

    const ciphertext = Buffer.from(ciphertextB64, 'base64');
    if (ciphertext.length === 0 || ciphertext.length > MAX_BLOB_BYTES) {
      return res.status(413).json({ error: 'That photo is too large to send.' });
    }

    // Recompute rather than trust. A wrong hash recorded here would make the
    // recipient's integrity check fail on a perfectly good file, and the app
    // would report a tamper that never happened.
    const digest = createHash('sha256').update(ciphertext).digest('hex');
    if (digest !== sha256) {
      return res.status(400).json({ error: 'The photo did not upload cleanly.' });
    }

    const pending = await shares().countDocuments({ toUsername: to });
    if (pending >= MAX_PENDING_PER_USER) {
      return res.status(429).json({
        error: 'That user has too many unopened photos. Ask them to open them.',
      });
    }

    const blobId = await new Promise((resolve, reject) => {
      const upload = bucket().openUploadStream(`${to}-${Date.now()}`);
      upload.on('error', reject);
      upload.on('finish', () => resolve(upload.id));
      upload.end(ciphertext);
    });

    const doc = {
      _id: new ObjectId(),
      fromUsername: sender.username,
      toUsername: to,
      blobId,
      wrappedKey,
      ephemeralPublicKey,
      sha256: digest,
      bytes: ciphertext.length,
      sentAt: new Date(),
    };
    await shares().insertOne(doc);
    await logEvent(req.session.sub, EVENTS.shareSent, {
      to: to,
      bytes: ciphertext.length,
    });

    return res.status(201).json({ share: view(doc) });
  });

  // -------------------------------------------------------------------
  // Receive
  // -------------------------------------------------------------------

  router.get('/inbox', async (req, res) => {
    const me = await users().findOne({ googleSub: req.session.sub });
    if (!me?.username) return res.json({ shares: [] });

    const rows = await shares()
      .find({ toUsername: me.username })
      .sort({ sentAt: -1 })
      .limit(50)
      .toArray();

    return res.json({ shares: rows.map(view) });
  });

  router.get('/:id/blob', async (req, res) => {
    const me = await users().findOne({ googleSub: req.session.sub });
    if (!me?.username) return res.status(404).json({ error: 'Not found.' });

    let id;
    try {
      id = new ObjectId(req.params.id);
    } catch {
      return res.status(400).json({ error: 'Bad id.' });
    }

    // Scoped to the recipient, so an id alone is not enough to read somebody
    // else's blob even though it would still be undecryptable.
    const doc = await shares().findOne({ _id: id, toUsername: me.username });
    if (!doc) return res.status(404).json({ error: 'Not found.' });

    res.setHeader('content-type', 'application/octet-stream');
    res.setHeader('content-length', doc.bytes);

    bucket()
      .openDownloadStream(doc.blobId)
      .on('error', () => res.destroy())
      .pipe(res);
  });

  router.delete('/:id', async (req, res) => {
    const me = await users().findOne({ googleSub: req.session.sub });
    if (!me?.username) return res.status(404).json({ error: 'Not found.' });

    let id;
    try {
      id = new ObjectId(req.params.id);
    } catch {
      return res.status(400).json({ error: 'Bad id.' });
    }

    const doc = await shares().findOneAndDelete({
      _id: id,
      toUsername: me.username,
    });
    if (!doc) return res.status(404).json({ error: 'Not found.' });

    // Storage is the scarce resource on a free cluster, so the blob goes as
    // soon as the recipient has it.
    try {
      await bucket().delete(doc.blobId);
    } catch {
      // Already gone; the metadata delete above is what matters.
    }

    await logEvent(req.session.sub, EVENTS.shareOpened, {
      from: doc.fromUsername,
      bytes: doc.bytes,
    });

    return res.json({ ok: true });
  });

  return router;
}

export async function createShareIndexes() {
  const shares = getDb().collection('shares');
  await shares.createIndex({ toUsername: 1, sentAt: -1 });
}
