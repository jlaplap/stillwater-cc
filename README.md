# Stillwater Command Center

A single-operator command center for the GetInsuredBC paid lead-generation business:
Meta ads → segmented landing pages → HubSpot leads → batch-routed to buyers → invoiced, with a
live money-in/money-out view and one-screen control of ad creatives.

This repo holds the **v1 live artifact** — a single self-contained `index.html` that runs inside
Cowork, reads real connector data (HubSpot + Meta), performs real ad actions (kill / scale), and
persists the operating store (buyers, batches, invoices, lead routing) in **Supabase**.

## What's live

- **Dashboard** — KPI strip (leads today/week, active buyers, ad spend, revenue, profit, qualified
  rate), leads-vs-spend activity chart, spend-by-segment, live feed, channel-status panel.
- **Leads** — live HubSpot inbox (search / segment / status filters); select rows → create a batch.
  Routing state (batched / sent / sold) comes from Supabase.
- **Buyers** — persisted in Supabase, added directly as **active** (no public form / approval).
  Activate-pause-edit, per-buyer per-lead pricing, and a **CASL agreement** flag Joel ticks when a
  buyer agrees (out of band) to honor consent.
- **Ads** — live across the three GetInsured BC Meta ad accounts. **Kill** pauses an ad or ad set and
  **Scale** bumps the ad-set daily budget (real Meta writes, behind a confirm dialog). CBO ad sets are
  flagged. CPL / leads come from Meta `results`.
- **Money** — P&L by segment (live Meta spend vs. Supabase invoice revenue) and an invoice list with
  mark-paid and void/refund.

## Data store (Supabase)

Project: **stillwater-cc** (`pqhejgzbmhhaxaraklgl`).

Run the SQL in order:

1. `db/01_schema.sql` — enums, tables, indexes, P&L view (security_invoker), RLS.
2. `db/02_persistence.sql` — transactional RPCs the app calls, plus execute lock-down.

Key guarantees enforced in the DB, not the UI:

- **Exclusive single-sale** — `batch_leads.uq_lead_single_batch` makes it impossible to put a lead in
  two batches; `sw_create_batch` skips any lead already routed.
- **Dedup** — leads carry a normalized `dedupe_key` (`lower(email)|digits(phone)`).
- **Per-segment attribution** — `utm_content` = ad id, `utm_term` = ad-set id; `pnl_by_segment_daily`
  joins spend to revenue by segment.

The Command Center talks to Supabase only through the **service connection** (Cowork's `execute_sql`),
never the public anon key — so no keys reach the browser and the mutating RPCs aren't client-callable.

## Operating rules baked in

- Leads default to **exclusive** (locked from re-batching once a batch is sent).
- Pricing is **per-lead, set per buyer** (overridable per batch).
- Delivery is **CSV export + manual handoff**. "Send" exports a CSV, marks the batch `sent`, and
  shelves the exclusive leads; Joel sends the file to the buyer (email / Drive / Slack) out of band.

### CSV column spec (the delivery artifact)

`lead_id, created_at, segment, first_name, email, phone, city, province, qualified,
consent_express, consent_timestamp, consent_ip` — one row per lead. The three `consent_*` columns
are the CASL proof of opt-in and are always included.

## Current limits (v1 artifact)

- **Stripe** isn't connected yet, so invoices are created and marked paid in-app (revenue = what's
  marked paid). Wiring Stripe (auto-create + `invoice.paid` webhook) is the next step.
- Consent columns (`consent_*`) are populated by the quiz → HubSpot → Supabase lead capture, which is
  a separate workstream; until it's live those columns export blank.
- RLS uses permissive `USING (true)` policies for `authenticated` (single-operator design). Tighten
  to per-user policies when a real multi-user / buyer-portal phase arrives.

## Migrating from the previous (localStorage) version

The artifact shows a one-time, non-destructive **"Import this browser's data"** banner if it finds
buyers / batches / invoices saved locally from the pre-Supabase build. It recreates them through the
RPCs and leaves localStorage intact as a backup.

## Usage

Open `index.html` inside Cowork (registered as the `stillwater-command-center` artifact). Outside
Cowork the page renders but live HubSpot/Meta/Supabase data and actions require the Cowork bridge.
