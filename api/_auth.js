// Shared auth for the command center API routes (files prefixed with _ are not routes).
const crypto = require('crypto');

const TAG = 'cc-authed-v1';

function issueToken(secret) {
  return crypto.createHmac('sha256', secret).update(TAG).digest('hex');
}

function safeEqualHex(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) return false;
  try { return crypto.timingSafeEqual(Buffer.from(a, 'utf8'), Buffer.from(b, 'utf8')); }
  catch (e) { return false; }
}

// Returns true if the request carries a valid bearer token.
function authed(req) {
  const secret = process.env.SESSION_SECRET;
  if (!secret) return false;
  const hdr = req.headers['authorization'] || req.headers['Authorization'] || '';
  const token = String(hdr).replace(/^Bearer\s+/i, '').trim();
  return safeEqualHex(token, issueToken(secret));
}

function passwordOk(input) {
  const pw = process.env.CC_PASSWORD;
  if (!pw || input == null) return false;
  const h = (s) => crypto.createHash('sha256').update(String(s)).digest('hex');
  return safeEqualHex(h(input), h(pw));
}

function body(req) {
  let b = req.body || {};
  if (typeof b === 'string') { try { b = JSON.parse(b); } catch (e) { b = {}; } }
  return b || {};
}

module.exports = { issueToken, authed, passwordOk, body };
