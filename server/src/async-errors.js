import Layer from 'express/lib/router/layer.js';

/**
 * Forwards errors from async route handlers to Express's error handler.
 *
 * Express 4 only catches errors thrown synchronously. A rejected promise from
 * an `async` handler — a dropped database connection, say — became an
 * unhandled rejection, which on Node 15+ kills the whole process: every user
 * in flight lost their request and the instance restarted. Patching the one
 * place Express calls handlers covers every route, including ones added later.
 */
const original = Layer.prototype.handle_request;

Layer.prototype.handle_request = function handleRequest(req, res, next) {
  const fn = this.handle;
  // Four-argument functions are error handlers; Express skips them here.
  if (fn.length > 3) return original.call(this, req, res, next);
  try {
    const result = fn(req, res, next);
    if (result && typeof result.catch === 'function') result.catch(next);
  } catch (err) {
    next(err);
  }
};
