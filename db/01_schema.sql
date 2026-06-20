-- Stillwater Command Center — Supabase migration (v1)
-- Run FIRST. Postgres 15+. Base schema: enums, tables, indexes, P&L view, RLS.
-- Enforces: exclusive single-sale (uq_lead_single_batch), dedup, per-segment attribution.
-- =========================================================
-- ENUMS
-- =========================================================
create type lead_status     as enum ('new','qualified','batched','sent','sold','refunded','dead');
create type buyer_status    as enum ('pending','active','paused');
create type batch_status    as enum ('draft','sent','invoiced','paid');
create type invoice_status  as enum ('draft','open','paid','failed','void');
create type delivery_status as enum ('pending','delivered','failed','dead');
create type price_model     as enum ('per_lead','flat_batch','revshare');
create type exclusivity_t   as enum ('exclusive','shared');

-- updated_at trigger helper
create or replace function set_updated_at()
returns trigger language plpgsql set search_path = public as $$
begin new.updated_at = now(); return new; end; $$;

-- =========================================================
-- BUYERS
-- =========================================================
create table buyers (
  id                   uuid primary key default gen_random_uuid(),
  company              text not null,
  contact_name         text,
  email                text not null,
  phone                text,
  segments_wanted      text[] default '{}',
  provinces_wanted     text[] default '{}',
  price_model          price_model not null default 'per_lead',
  price_per_lead       numeric(10,2),
  notes                text,
  status               buyer_status not null default 'active',   -- added directly as active (no apply/approval)
  stripe_customer_id   text,
  agreement_consent    boolean default false,   -- Joel ticks when buyer agrees (out of band) to honor CASL/consent
  agreement_timestamp  timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
create trigger trg_buyers_updated before update on buyers
  for each row execute function set_updated_at();

-- =========================================================
-- LEADS
-- =========================================================
create table leads (
  id                   uuid primary key default gen_random_uuid(),
  hubspot_contact_id   text unique,
  segment              text not null,
  lp_url               text,
  utm_source           text,
  utm_medium           text,
  utm_campaign         text,
  utm_content          text,    -- = ad.id  (creative-level ROI join key)
  utm_term             text,    -- = adset.id
  campaign_id          text,
  province             text,
  city                 text,
  qualified            boolean default false,
  qualification_payload jsonb,
  first_name           text,
  email                text,
  phone                text,
  consent_express      boolean default false,
  consent_timestamp    timestamptz,
  consent_ip           text,
  status               lead_status not null default 'new',
  exclusivity          exclusivity_t not null default 'exclusive',
  dedupe_key           text,    -- lower(email)|digits(phone)
  shelved_at           timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);
create trigger trg_leads_updated before update on leads
  for each row execute function set_updated_at();
create index idx_leads_segment    on leads(segment);
create index idx_leads_status     on leads(status);
create index idx_leads_created     on leads(created_at desc);
create index idx_leads_dedupe      on leads(dedupe_key);
create index idx_leads_utm_content on leads(utm_content);
create index idx_leads_available on leads(status) where shelved_at is null;

-- =========================================================
-- BATCHES (+ exclusive single-sale guard)
-- =========================================================
create table batches (
  id              uuid primary key default gen_random_uuid(),
  name            text,
  buyer_id        uuid references buyers(id) on delete restrict,
  segment_filter  text,
  province_filter text,
  exclusivity     exclusivity_t not null default 'exclusive',
  lead_count      int default 0,
  total_price     numeric(12,2) default 0,
  status          batch_status not null default 'draft',
  sent_at         timestamptz,
  created_at      timestamptz not null default now()
);

create table batch_leads (
  batch_id   uuid references batches(id) on delete cascade,
  lead_id    uuid references leads(id) on delete restrict,
  sale_price numeric(10,2),
  primary key (batch_id, lead_id),
  constraint uq_lead_single_batch unique (lead_id)   -- double-sell protection
);

-- Addendum #2: delivery is CSV export + manual handoff, so there is no
-- lead_deliveries table and no buyer delivery_* fields (the delivery_status
-- enum is left defined but unused).

-- =========================================================
-- INVOICES
-- =========================================================
create table invoices (
  id                uuid primary key default gen_random_uuid(),
  batch_id          uuid references batches(id) on delete restrict,
  buyer_id          uuid references buyers(id) on delete restrict,
  stripe_invoice_id text unique,
  amount            numeric(12,2),
  status            invoice_status not null default 'draft',
  due_date          date,
  paid_at           timestamptz,
  created_at        timestamptz not null default now()
);
create index idx_invoices_status on invoices(status);

-- =========================================================
-- AD SNAPSHOTS (daily cron from Meta)
-- =========================================================
create table ad_spend_daily (
  id               uuid primary key default gen_random_uuid(),
  date             date not null,
  platform         text not null default 'meta',
  campaign_id      text,
  segment          text,
  spend            numeric(12,2) default 0,
  impressions      int default 0,
  clicks           int default 0,
  leads_attributed int default 0,
  unique (date, platform, campaign_id)
);
create index idx_spend_seg_date on ad_spend_daily(segment, date);

create table ad_creatives (
  id          uuid primary key default gen_random_uuid(),
  campaign_id text,
  adset_id    text,
  ad_id       text unique,    -- joins leads.utm_content
  segment     text,
  name        text,
  status      text,
  spend       numeric(12,2) default 0,
  leads       int default 0,
  cpl         numeric(10,2),
  ctr         numeric(6,3),
  decision    text,           -- kill | scale | hold
  last_synced timestamptz
);

-- =========================================================
-- AUDIT LOG
-- =========================================================
create table audit_log (
  id         uuid primary key default gen_random_uuid(),
  entity     text,
  entity_id  uuid,
  action     text,
  actor      text default 'joel',
  payload    jsonb,
  created_at timestamptz not null default now()
);

-- =========================================================
-- P&L VIEW (spend vs revenue by segment by day) — security_invoker
-- =========================================================
create or replace view pnl_by_segment_daily
with (security_invoker = on) as
with spend as (
  select date as d, segment, sum(spend) as spend
  from ad_spend_daily group by date, segment
),
revenue as (
  select date(i.paid_at) as d, l.segment, sum(bl.sale_price) as revenue
  from invoices i
  join batches b      on b.id = i.batch_id
  join batch_leads bl on bl.batch_id = b.id
  join leads l        on l.id = bl.lead_id
  where i.status = 'paid'
  group by date(i.paid_at), l.segment
)
select
  coalesce(s.d, r.d)             as date,
  coalesce(s.segment, r.segment) as segment,
  coalesce(s.spend, 0)           as spend,
  coalesce(r.revenue, 0)         as revenue,
  coalesce(r.revenue,0) - coalesce(s.spend,0) as profit
from spend s
full outer join revenue r on s.d = r.d and s.segment = r.segment;

-- =========================================================
-- RLS (single operator — Joel). Server uses the service role (bypasses RLS).
-- =========================================================
alter table buyers          enable row level security;
alter table leads           enable row level security;
alter table batches         enable row level security;
alter table batch_leads     enable row level security;
alter table invoices        enable row level security;
alter table ad_spend_daily  enable row level security;
alter table ad_creatives    enable row level security;
alter table audit_log       enable row level security;

do $$
declare t text;
begin
  foreach t in array array[
    'buyers','leads','batches','batch_leads',
    'invoices','ad_spend_daily','ad_creatives','audit_log']
  loop
    execute format(
      'create policy %I_auth_all on %I for all to authenticated using (true) with check (true);',
      t, t);
  end loop;
end $$;
