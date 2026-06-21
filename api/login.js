// POST /api/login { password } -> { token }
const { issueToken, passwordOk, body } = require('./_auth');

module.exports = async (req, res) => {
  if (req.method !== 'POST') { res.status(405).json({ error: 'POST only' }); return; }
  const { CC_PASSWORD, SESSION_SECRET } = process.env;
  if (!CC_PASSWORD || !SESSION_SECRET) {
    res.status(500).json({ error: 'Server not configured: set CC_PASSWORD and SESSION_SECRET.' });
    return;
  }
  const { password } = body(req);
  if (!passwordOk(password)) { res.status(401).json({ error: 'Wrong password' }); return; }
  res.status(200).json({ token: issueToken(SESSION_SECRET) });
};
