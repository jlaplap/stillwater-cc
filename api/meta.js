// POST /api/meta { tool, args } -> { ad_entities } | { error }
// Proxies to the Meta Graph API. Requires META_ACCESS_TOKEN in Vercel env vars.
// Returns entities in the shape: {id, name, status, spend, impressions, clicks, cpc, ctr, reach}.
// Cowork mode uses the MCP bridge directly; this route is only hit in web (Vercel) mode.
const https = require('https');
const { authed, body } = require('./_auth');

const GRAPH_VER = 'v21.0';

// Simple HTTPS GET → parsed JSON (no npm deps needed).
function graphGet(url) {
  return new Promise((resolve, reject) => {
    https.get(url, (res) => {
      let raw = '';
      res.on('data', c => raw += c);
      res.on('end', () => {
        try { resolve(JSON.parse(raw)); }
        catch (e) { reject(new Error('Bad JSON from Graph API: ' + raw.slice(0, 300))); }
      });
    }).on('error', reject);
  });
}

// Follow pagination cursors, collect all results (up to 10 pages).
async function graphGetAll(url) {
  const out = [];
  let next = url;
  for (let page = 0; next && page < 10; page++) {
    const data = await graphGet(next);
    if (data.error) throw new Error(data.error.message || JSON.stringify(data.error));
    if (Array.isArray(data.data)) out.push(...data.data);
    next = data.paging && data.paging.next ? data.paging.next : null;
  }
  return out;
}

module.exports = async (req, res) => {
  if (req.method !== 'POST') { res.status(405).json({ error: 'POST only' }); return; }
  if (!authed(req)) { res.status(401).json({ error: 'unauthorized' }); return; }

  const token = process.env.META_ACCESS_TOKEN;
  if (!token) {
    res.status(200).json({ ad_entities: [], not_configured: true });
    return;
  }

  const { args } = body(req);
  if (!args || !args.ad_account_id) {
    res.status(400).json({ error: 'args.ad_account_id required' });
    return;
  }

  // Account IDs are stored as bare numerics in the app; Graph API needs the act_ prefix.
  const acctId = String(args.ad_account_id).startsWith('act_')
    ? args.ad_account_id
    : 'act_' + args.ad_account_id;

  const level = args.level || 'campaign';
  // campaign→campaigns, adset→adsets, ad→ads
  const levelPlural = level === 'adset' ? 'adsets' : level + 's';
  const datePreset = args.date_preset || 'last_30d';

  // Fetch entity attributes + inline insights in one call.
  const insightFields = 'spend,impressions,clicks,cpc,ctr,reach';
  const fields = `id,name,status,insights.date_preset(${datePreset}){${insightFields}}`;

  const params = new URLSearchParams({ fields, limit: '200', access_token: token });
  const url = `https://graph.facebook.com/${GRAPH_VER}/${acctId}/${levelPlural}?${params}`;

  try {
    const entities = await graphGetAll(url);

    const ad_entities = entities.map(e => {
      const ins = (e.insights && e.insights.data && e.insights.data[0]) || {};
      return {
        id:          e.id,
        name:        e.name,
        status:      e.status || '',
        spend:       ins.spend       || '0',
        impressions: ins.impressions || '0',
        clicks:      ins.clicks      || '0',
        cpc:         ins.cpc         || '0',
        ctr:         ins.ctr         || '0',
        reach:       ins.reach       || '0',
      };
    });

    res.status(200).json({ ad_entities });
  } catch (e) {
    // Degrade gracefully: surface the error message but still return a valid shape.
    res.status(200).json({
      ad_entities: [],
      error: 'Meta API error: ' + (e && e.message ? e.message : String(e)),
    });
  }
};
