# Stillwater Command Center

A single-operator command center for the GetInsuredBC paid lead-generation business:
Meta ads → segmented landing pages → HubSpot leads → batch-routed to buyers → invoiced, with a
live money-in/money-out view and one-screen control of ad creatives.

This repo holds the **v1 live artifact** — a single self-contained `index.html` that reads real
connector data (HubSpot + Meta) and performs real actions (kill / scale ads). It runs inside Cowork,
where `window.cowork.callMcpTool(...)` is provided.

## What's live

- **Dashboard** — KPI strip (leads today/week, active buyers, ad spend, revenue, profit, qualified
  rate), leads-vs-spend activity chart, spend-by-segment, live activity feed, channel-status panel.
- **Leads** — live HubSpot inbox (search / segment / status filters); select rows → create a batch.
- **Ads** — live across the three GetInsured BC Meta ad accounts. **Kill** pauses an ad or ad set and
  **Scale** bumps the ad-set daily budget (real Meta writes, behind a confirm dialog). CBO ad sets are
  flagged. CPL / leads come from Meta `results`.
- **Money** — P&L by segment (live Meta spend vs. invoice revenue) and an invoice list.

## Operating rules baked in

- Leads default to **exclusive** (locked from re-batching once a batch is sent).
- Pricing is **per-lead, set per buyer** (overridable per batch).
- Delivery is **API / webhook push** — "Send" produces the exact JSON payload to POST to the buyer.

## Current limits (v1 artifact)

- **Stripe** and a durable **Supabase** store are not yet connected, so buyers / batches / invoices
  persist in browser `localStorage` and revenue is whatever is marked paid.
- The sandbox can't POST to arbitrary buyer endpoints, so delivery generates a copy-ready payload.

Both become live in the full Next.js + Supabase build (see the PRD).

## Data sources

| Surface | Source | Mode |
|---|---|---|
| Leads | HubSpot CRM (portal 342381759) | live read |
| Ad spend / creatives / ad sets | Meta Marketing API — 3 GetInsured BC accounts | live read |
| Kill / Scale | Meta Marketing API (`ads_update_entity`) | live write |
| Buyers / batches / invoices / P&L revenue | browser localStorage | local (v1) |

## Usage

Open `index.html` inside Cowork (it's registered as the `stillwater-command-center` artifact).
Outside Cowork the page still renders and the buyers/batches/invoices layer works offline, but live
HubSpot/Meta data and kill/scale actions require the Cowork connector bridge.
