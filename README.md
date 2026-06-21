# Stillwater Command Center

A single-operator command center for the GetInsuredBC paid lead-generation business:
Meta ads → segmented landing pages → n8n intake → **Supabase** leads → batch-routed to buyers →
invoiced, with a live money-in/money-out view and one-screen control of ad creatives.

This repo holds the **v1 live artifact** — a single self-contained `index.html` that runs inside
Cowork, reads real data (Supabase leads/store + Meta ads), performs real ad actions (kill / scale),
and uses **Supabase as the system of record** for leads, buyers, batches, and invoices.

## What's live

- **Dashboard** — KPI strip (leads today/week, active buyers, ad spend, revenue, profit, qualified
  rate), leads-vs-spend activity chart, spend-by-segment, live feed, channel-status panel.
- **Leads** — Supabase `leads` inbox (search + segment / source / province / status filters).
  Duplicates (`is_duplicate`) are flagged and hidden from the routable view (toggle to show). The
  MCP-bridge console polls every ~25s with an unread badge; the Next.js build subscribes to realtime.
  Select rows → create a batch; status (available / batched / sent / sold) is the lead's real column.
- **Buyers** — persisted in Supabase, added directly as **active** (no public form / approval).
  Activate-pause-edit, per-buyer per-lead pricing, and a **CASL agreement** flag Joel ticks when a
  buyer agrees (out of band) to honor consent.
- **Ads** — live across the three GetInsured BC Meta ad accounts. **Kill** pauses an ad or ad set and
  **Scale** bumps the ad-set daily budget (real Meta writes, behind a confirm dialog). CBO ad sets are
  flagged. CPL / leads come from Meta `results`.
- **Money** — P&L by segment (live Meta spend vs. Supabase invoice revenue) and an invoice list with
  mark-paid and void/refund.
- **CRM records** — every record opens a right-side detail panel with inline click-to-edit fields and an
  **Activity** timeline (log calls / emails / meetings / SMS / notes, merged with system events). Quiz
  answers land in a lead's Notes. Table columns are click-to-sort; Leads support checkbox + Shift/Cmd-click
  multi-select, "select first N", and XLS export. Tasks are a drag-and-drop board (To do / In progress /
  Done) with per-column quick-add. Activity-log schema lives in `db/04_crm_workspace.sql`.

## Data store (Supabase)

Project: **stillwater-cc** (`pqhejgzbmhhaxaraklgl`).

Run the SQL in order:

1. `db/01_schema.sql` — enums, tables, indexes, P&L view (security_invoker), RLS.
2. `db/02_persistence.sql` — transactional RPCs the app calls, plus execute lock-down.

Key guarantees enforced in the DB, not the UI:

- **Intake** — leads enter via `ingest_lead(jsonb)` (the n8n contract): CASL **consent gate** +
  **dedup**; `source` tags the originating site for multi-brand (getinsuredbc, willkitcanada, ...).
- **Exclusive single-sale** — `batch_leads.uq_lead_single_batch` makes it impossible to put a lead in
  two batches; `create_batch(uuid[])` links existing leads and skips any already routed.
- **Dedup** — leads carry a normalized `dedupe_key` (`lower(email)|digits(phone)`).
- **Per-segment attribution** — `utm_content` = ad id, `utm_term` = ad-set id; `pnl_by_segment_daily`
  joins spend to revenue by segment.

The Command Center talks to Supabase only through the **service connection** (Cowork's `execute_sql`),
never the public anon key — so no keys reach the browser and the mutating RPCs aren't client-callable.

## Live intake (Addendum #4)

Leads are produced by a **deployed n8n pipeline**, not this console. The two systems meet at exactly
one place: the `public.leads` table in `stillwater-cc`.

```
Ads -> LP form -> n8n webhook (X-Intake-Key) -> ingest_lead() -> leads(status='new') -> Resend ping
                                                       |
                                          Command Center reads here
```

- Intake webhook: `https://calm-tiger-18.ash-1.instapods.app/webhook/lead-intake` (site forms POST
  with the `X-Intake-Key` header; the console never calls it).
- `ingest_lead()` runs the CASL consent gate + dedup and is **owned by the pipeline** (see the note in
  `db/02_persistence.sql`). The console is a pure consumer + operator of leads.
- `leads` is on the `supabase_realtime` publication for the future realtime path.
- getinsuredbc's own Supabase (`ayzxnmftmzlzrqkmiebq`) is a *source*, not the CRM — don't point the
  console at it.

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
- Consent columns (`consent_*`) are populated by the quiz → n8n intake (`ingest_lead`) → Supabase
  capture, which is a separate workstream; until it's live the `leads` table is empty.
- RLS uses permissive `USING (true)` policies for `authenticated` (single-operator design). Tighten
  to per-user policies when a real multi-user / buyer-portal phase arrives.

## Migrating from the previous (localStorage) version

The artifact shows a one-time, non-destructive **"Import this browser's data"** banner if it finds
buyers / batches / invoices saved locally from the pre-Supabase build. It recreates them through the
RPCs and leaves localStorage intact as a backup.

## Usage

Open `index.html` inside Cowork (registered as the `stillwater-command-center` artifact) for the
bridge-backed dev build. On the web (Vercel) build the same page talks to Supabase through the API
routes below, behind a password.

## Deploy to Vercel

The page is **dual-mode**. It auto-detects its environment: inside Cowork it uses the data bridge; on
the open web it routes every data call to serverless API routes in `/api`. No code change needed
between the two.

### How it works on the web

- `index.html` is served statically at `/`.
- `/api/login` — exchanges `CC_PASSWORD` for a signed session token (stored in `sessionStorage`).
- `/api/sql` — runs the console's SQL against Supabase Postgres via `DATABASE_URL` (the `pg` pool),
  **only** when the request carries a valid token. This is the single data path for leads, buyers,
  the CRM (`cc_*`), tasks, distributions, invoices, etc.
- `/api/meta` — Meta Ads proxy. Returns empty (`not_configured`) until `META_ACCESS_TOKEN` is set, so
  the Ads view degrades gracefully instead of erroring. (Full Graph API proxy is a follow-up.)

### Steps

1. Import this repo into Vercel (Framework preset: **Other** — it's static + `/api`).
2. Add the environment variables from `.env.example`:
   - `DATABASE_URL` — Supabase → Project Settings → Database → Connection string → **Transaction** pooler.
   - `CC_PASSWORD` — the password you'll type to sign in.
   - `SESSION_SECRET` — a long random string (`openssl rand -hex 32`).
   - `META_ACCESS_TOKEN` *(optional)* — enables live Ads later.
3. Deploy. Open the URL, enter `CC_PASSWORD`, and the console loads live data.

### Security

`/api/sql` executes arbitrary SQL when authenticated — this is a single-operator tool. Keep the
deployment behind the password (and ideally Vercel **Deployment Protection**). `DATABASE_URL`,
`CC_PASSWORD`, and `SESSION_SECRET` live only in Vercel env vars, never in the client bundle. RLS on
`cc_*` / `leads` stays permissive for now; tighten to per-user policies for a multi-user phase.

## Migrating from the previous (localStorage) version

The artifact shows a one-time, non-destructive **"Import this browser's data"** banner if it finds
buyers / batches / invoices saved locally from the pre-Supabase build. It recreates them through the
RPCs and leaves localStorage intact as a backup.
