import { close, connect } from './db.js';
import { createApp } from './app.js';

const port = process.env.PORT || 8080;

connect()
  .then(() => {
    createApp().listen(port, () =>
      console.log(`GeoGuard server listening on :${port}`),
    );
  })
  .catch((e) => {
    console.error('Could not start:', e.message);
    process.exit(1);
  });

process.on('SIGTERM', async () => {
  await close();
  process.exit(0);
});
