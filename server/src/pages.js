import express from 'express';

/**
 * The two public pages Google requires before the OAuth consent screen can
 * leave "Testing": a home page and a privacy policy.
 *
 * The policy describes what this server actually stores (see db.js, shares.js,
 * payments.js and events.js). Keep it in step with those files — a policy that
 * promises less collection than the code performs is worse than none.
 */
const CONTACT = 'shubhamhiremath87@gmail.com';

function page(title, body) {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title}</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; background: #FCF9F0; color: #000;
         font: 16px/1.55 system-ui, sans-serif; }
  main { max-width: 680px; margin: 0 auto; padding: 32px 16px; }
  h1 { font-size: 30px; margin: 0 0 16px; }
  h2 { font-size: 18px; margin: 32px 0 8px; }
  a { color: inherit; }
  @media (prefers-color-scheme: dark) {
    body { background: #15130F; color: #F5F1E6; }
  }
</style>
</head>
<body><main>${body}</main></body>
</html>`;
}

const HOME = page('GeoGuard', `
<h1>GeoGuard</h1>
<p>GeoGuard is an Android camera that stamps each photo with where and when it
was taken, and signs it so anyone can later check whether it was edited.</p>
<p>Signing in with Google gives you a username, so friends can find you and send
you photos end-to-end encrypted. Taking and checking photos works without an
account.</p>
<p><a href="/privacy">Privacy policy</a> · Contact: <a href="mailto:${CONTACT}">${CONTACT}</a></p>
`);

const PRIVACY = page('GeoGuard privacy policy', `
<h1>Privacy policy</h1>
<p>Last updated 26 September 2026.</p>

<h2>What we collect when you sign in with Google</h2>
<p>Your Google account id, email address, name and profile picture URL. We use
these only to run your GeoGuard account. We never show your email to other
users.</p>

<h2>What else your account stores</h2>
<ul>
  <li>The username you choose, and your app's public keys and sharing code, so
      other users can find you and check photos you took.</li>
  <li>Whether you have GeoGuard Pro and until when, and a record of each
      payment order (plan, amount, status). Card and UPI details are handled
      by Razorpay and never reach us.</li>
  <li>An activity log (sign-ins, payments, photos sent and received, checks
      run). For checks we record only the verdict, never the photo. Log entries
      are deleted automatically after 90 days.</li>
</ul>

<h2>Photos</h2>
<p>Photos stay on your phone. When you send a photo to another user, it is
encrypted on your phone before upload, and our server stores only the
encrypted file, which it cannot open. It is deleted as soon as the recipient
opens it.</p>

<h2>Sharing</h2>
<p>We do not sell your data or share it with advertisers. Data is stored with
MongoDB Atlas and served from Render. Payments are processed by Razorpay.</p>

<h2>Deleting your account</h2>
<p>Email <a href="mailto:${CONTACT}">${CONTACT}</a> from your account's address
and we will delete your account and its data.</p>
`);

export function pagesRouter() {
  const router = express.Router();
  const send = (html) => (_req, res) => res.type('html').send(html);
  router.get('/', send(HOME));
  router.get('/privacy', send(PRIVACY));
  return router;
}
