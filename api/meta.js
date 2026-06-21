// POST /api/meta { tool, args } -> { ad_entities } | { error }
// Proxies to the Meta Graph API. Requires META_ACCESS_TOKEN in Vercel env vars.
// Returns entities in the shape: {id, name, status, spend, impressions, clicks, cpc, ctr, reach}.
// Cowork mode uses the MCP bridge directly; this route is only hit in web (Vercel) mode.
//
// Two-step approach: fetch entity attributes then insights separately and merge by ID.
// This avoids URLSearchParams encoding {} and () in the inline field expansion syntax,
// which causes the Graph API to silently drop insights from the response.
const https = require('https');
const { authed, body } = require('./_auth');

const GRAPH_VER = 'v21.0';

// Simple HTTPS GET → parsed JSON. URL is passed as-is (no re-encoding by Node https).
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

// Follow paging.next cursors, collect all results (up to 10 pages).
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

// Build a safe query string: most params URL-encoded, `fields` left unencoded so that
// Graph API field expansion syntax ( . () {} , ) is preserved and not percent-escaped.
function buildUrl(base, fields, extra) {
  const enc = Object.entries(extra).map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`).join('&');
  return `${base}?fields=${fields}&${enc}`;
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

  // Account IDs stored as bare numerics in the app; Graph API needs the act_ prefix.
  const acctId = String(args.ad_account_id).startsWith('act_')
    ? args.ad_account_id
    : 'act_' + args.ad_account_id;

  const level      = args.level || 'campaign';
  const levelPlural = level === 'adset' ? 'adsets' : level + 's';
  const datePreset = args.date_preset || 'last_30d';

  // ID field name in insights rows differs by level.
  const insightIdKey = level === 'campaign' ? 'campaign_id'
                     : level === 'adset'    ? 'adset_id'
                     : 'ad_id';

  try {
    // Step 1: entity attributes (id, name, status) — simple fields, safe to encode normally.
    const entityUrl = buildUrl(
      `https://graph.facebook.com/${GRAPH_VER}/${acctId}/${levelPlural}`,
      'id,name,status',
      { limit: '200', access_token: token }
    );
    const entities = await graphGetAll(entityUrl);

    if (entities.length === 0) {
      res.status(200).json({ ad_entities: [] });
      return;
    }

    // Step 2: insights via the dedicated /insights endpoint — no field expansion needed.
    const insightFields = 'spend,impressions,clicks,cpc,ctr,reach,' + insightIdKey;
    const insightsUrl = buildUrl(
      `https://graph.facebook.com/${GRAPH_VER}/${acctId}/insights`,
      insightFields,
      { level, date_preset: datePreset, limit: '500', access_token: token }
    );
    let insightsRows = [];
    let insightsError = null;
    try {
      insightsRows = await graphGetAll(insightsUrl);
      console.error('[api/meta] OK', acctId, level, datePreset, 'entities:', entities.length, 'insights:', insightsRows.length);
    } catch (insErr) {
      insightsError = insErr.message || String(insErr);
      console.error('[api/meta] insights error', acctId, insightsError);
    }

    // Index insights by entity ID for O(1) lookup.
    const insMap = {};
    for (const row of insightsRows) {
      const id = row[insightIdKey];
      if (id) insMap[id] = row;
    }

    const ad_entities = entities.map(e => {
      const ins = insMap[e.id] || {};
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

    res.status(200).json({
      ad_entities,
      _debug: { entities: entities.length, insights: insightsRows.length, insights_error: insightsError },
    });
  } catch (e) {
    console.error('[api/meta]', e.message || e);
    res.status(200).json({
      ad_entities: [],
      error: 'Meta API error: ' + (e && e.message ? e.message : String(e)),
    });
  }
};
