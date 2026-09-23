import { MongoClient } from 'mongodb';

/**
 * The one place the database URI is ever read.
 *
 * It comes from the environment and is never sent to a client, logged, or
 * returned in an error body. The phone app talks to this server over HTTPS and
 * has no idea the database exists.
 */
let client;
let db;

export async function connect() {
  const uri = process.env.MONGODB_URI;
  if (!uri) {
    throw new Error('MONGODB_URI is not set');
  }

  client = new MongoClient(uri, {
    // A free-tier cluster has a low connection cap; a small pool leaves room
    // for the Atlas UI and any other service.
    maxPoolSize: 10,
    serverSelectionTimeoutMS: 10000,
    retryWrites: true,
  });

  await client.connect();
  db = client.db(process.env.MONGODB_DB || 'geoguard');

  await createIndexes();
  return db;
}

async function createIndexes() {
  const users = db.collection('users');

  // Identity keys. `unique` is the actual guard against two people claiming
  // the same username — an application-level "is it taken?" check races under
  // concurrent signups and eventually loses.
  await users.createIndex({ googleSub: 1 }, { unique: true });
  await users.createIndex(
    { username: 1 },
    { unique: true, partialFilterExpression: { username: { $type: 'string' } } },
  );
  await users.createIndex({ fingerprint: 1 });

  await db.collection('shares').createIndex({ toUsername: 1, sentAt: -1 });

  const events = db.collection('events');
  await events.createIndex({ googleSub: 1, at: -1 });
  await events.createIndex({ type: 1, at: -1 });
  // Ninety days is long enough to settle a payment dispute, and keeps the log
  // from filling a 512 MB cluster on its own.
  await events
    .createIndex({ at: 1 }, { expireAfterSeconds: 90 * 24 * 60 * 60 })
    .catch(() => {});

  await db.collection('payments').createIndex({ googleSub: 1, createdAt: -1 });
  await db.collection('payments').createIndex({ orderId: 1 }, { unique: true });
}

export function getDb() {
  if (!db) throw new Error('Database not connected');
  return db;
}

export function users() {
  return getDb().collection('users');
}

export async function close() {
  await client?.close();
  client = undefined;
  db = undefined;
}
