-- Stillwater Command Center — CRM workspace add-ons
-- Run AFTER 03_quiz_funnel.sql. Adds the polymorphic interaction log used by the
-- record detail panels (Activity timeline: calls, emails, meetings, SMS, notes).
--
-- NOTE: the cc_* CRM working tables (cc_leads, cc_buyers, cc_contacts, cc_companies,
-- cc_deals, cc_tasks, cc_notes, cc_distributions, cc_workflows) are the console's
-- working layer. cc_leads is populated by the mirror trigger in 03_quiz_funnel.sql.
-- This file only defines the cross-entity activity log, which has no dependency on the
-- other cc_* tables (it references them loosely by entity_type + entity_id).

create table if not exists public.cc_activities(
  id uuid primary key default gen_random_uuid(),
  entity_type text not null,          -- 'leads' | 'buyers' | 'contacts' | 'companies' | 'deals' | ...
  entity_id   uuid not null,
  type        text not null default 'note',  -- note | call | email | meeting | sms
  subject     text,
  body        text,
  occurred_at timestamptz not null default now(),
  actor       text default 'joel',
  created_at  timestamptz not null default now()
);
create index if not exists idx_cc_activities_entity
  on public.cc_activities(entity_type, entity_id, occurred_at desc);

-- Single-operator console reads/writes via the Supabase service connection. Permissive
-- policy keeps anon/authenticated paths working too; tighten for multi-user later.
alter table public.cc_activities enable row level security;
drop policy if exists cc_activities_anon_all on public.cc_activities;
create policy cc_activities_anon_all on public.cc_activities
  for all to anon, authenticated using (true) with check (true);
