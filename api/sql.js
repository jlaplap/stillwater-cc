// POST /api/sql { query } -> { rows } | { error }
// Runs SQL against Supabase Postgres with the service-level connection (DATABASE_URL),
// gated behind the command-center password. Single-operator tool — keep the deployment
// behind a password (this endpoint executes arbitrary SQL when authenticated).
const { Pool } = require('pg');
const { authed, body } = require('./_auth');

let pool;
function getPool() {
  if (!pool) {
    // Supports a manual DATABASE_URL or the vars added by the Vercel↔Supabase integration.
    let cs = process.env.DATABASE_URL || process.env.POSTGRES_URL || process.env.POSTGRES_PRISMA_URL || '';
    // Supabase's pooler cert isn't in Node's trust store. Drop sslmode from the URL so our
    // ssl option (rejectUnauthorized:false) is what applies, avoiding "self signed certificate".
    try { const u = new URL(cs); u.searchParams.delete('sslmode'); cs = u.toString(); } catch (e) {}
    pool = new Pool({
      connectionString: cs,
      ssl: { rejectUnauthorized: false },
      max: 3,
      idleTimeoutMillis: 10000,
    });
  }
  return pool;
}

module.exports = async (req, res) => {
  if (req.method !== 'POST') { res.status(405).json({ error: 'POST only' }); return; }
  if (!authed(req)) { res.status(401).json({ error: 'unauthorized' }); return; }
  if (!process.env.DATABASE_URL && !process.env.POSTGRES_URL && !process.env.POSTGRES_PRISMA_URL) { res.status(500).json({ error: 'No database connection string set (DATABASE_URL or POSTGRES_URL)' }); return; }

  const { query } = body(req);
  if (!query || typeof query !== 'string') { res.status(400).json({ error: 'query required' }); return; }

  try {
    const result = await getPool().query(query);
    const last = Array.isArray(result) ? result[result.length - 1] : result;
    res.status(200).json({ rows: (last && last.rows) || [] });
  } catch (e) {
    // Return as 200 + error so the client surfaces the message instead of a generic 500.
    res.status(200).json({ error: 'SQL error: ' + (e && e.message ? e.message : String(e)) });
  }
};
