// POST /api/meta { tool, args } -> { ad_entities } | { error }
// Graceful stub: the live Meta Ads view runs through the Cowork bridge during development.
// On the web build it returns empty (not_configured) until META_ACCESS_TOKEN is wired to the
// Meta Graph API. The console degrades to "no ad data" rather than erroring.
const { authed } = require('./_auth');

module.exports = async (req, res) => {
  if (req.method !== 'POST') { res.status(405).json({ error: 'POST only' }); return; }
  if (!authed(req)) { res.status(401).json({ error: 'unauthorized' }); return; }

  if (!process.env.META_ACCESS_TOKEN) {
    res.status(200).json({ ad_entities: [], not_configured: true });
    return;
  }
  // TODO: proxy to https://graph.facebook.com/<ver>/<account>/<level>s?fields=...&access_token=...
  // and map insights to the {id,name,status,spend,impressions,clicks,cpc,ctr,reach} shape.
  res.status(200).json({ ad_entities: [], not_configured: false });
};
