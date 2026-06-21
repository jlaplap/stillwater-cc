-- Stillwater Command Center — quiz funnel integration (PRD 2026-06-20)
-- Run AFTER 01_schema.sql + 02_persistence.sql. Adds CASL consent-evidence columns,
-- extends ingest_lead to persist them, mirrors leads -> cc_leads for CRM visibility,
-- and pushes new leads to n8n via pg_net.
--
-- NOTE: cc_leads is the pre-existing CRM "working record" table (cc_* family) that lives
-- in the command center project but is NOT defined in this repo. The mirror trigger below
-- is guarded so a fresh deploy without cc_leads still succeeds.

-- 1) CASL consent-evidence columns
alter table public.leads add column if not exists consent_text text;
alter table public.leads add column if not exists consent_user_agent text;

-- 2) ingest_lead: deployed intake-owned function, EXTENDED additively to persist
--    consent_text + consent_user_agent (see note in 02_persistence.sql — intake owns this).
create or replace function public.ingest_lead(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_dupe boolean; v_key text;
begin
  if coalesce((p->>'consent_express')::boolean,false) is not true then
    raise exception 'consent_required';
  end if;
  v_key := lower(coalesce(p->>'email','')) || '|' || regexp_replace(coalesce(p->>'phone',''), '\D', '', 'g');
  select exists(
    select 1 from public.leads where dedupe_key = v_key and created_at > now() - interval '30 days'
  ) into v_dupe;
  insert into public.leads(
    source, segment, lp_url,
    utm_source, utm_medium, utm_campaign, utm_content, utm_term, campaign_id,
    province, city, qualified, qualification_payload,
    first_name, email, phone,
    consent_express, consent_timestamp, consent_ip, consent_text, consent_user_agent,
    status, exclusivity, dedupe_key, is_duplicate)
  values(
    p->>'source', coalesce(nullif(p->>'segment',''),'unknown'), p->>'lp_url',
    p->>'utm_source', p->>'utm_medium', p->>'utm_campaign', p->>'utm_content', p->>'utm_term', p->>'campaign_id',
    p->>'province', p->>'city', coalesce((p->>'qualified')::boolean,false), p->'qualification',
    p->>'first_name', p->>'email', p->>'phone',
    true, coalesce((p->>'consent_timestamp')::timestamptz, now()), p->>'consent_ip',
    p->>'consent_text', p->>'consent_user_agent',
    'new', 'exclusive', v_key, v_dupe)
  returning id into v_id;
  return jsonb_build_object('lead_id', v_id, 'duplicate', v_dupe);
end $$;

-- 3) mirror leads -> cc_leads (skips duplicates; idempotent on cc_leads.lead_id). Guarded.
do $$
begin
  if to_regclass('public.cc_leads') is null then
    raise notice 'cc_leads not present; skipping mirror trigger';
    return;
  end if;
  execute $mig$
    alter table public.cc_leads add column if not exists lead_id uuid references public.leads(id) on delete set null;
    create unique index if not exists uq_cc_leads_lead_id on public.cc_leads(lead_id);

    create or replace function public.leads_mirror_to_cc_leads()
    returns trigger language plpgsql security definer set search_path = public as $fn$
    declare v_notes text;
    begin
      if NEW.is_duplicate then return NEW; end if;
      select string_agg(key || ': ' || value, '; ' order by key)
        into v_notes from jsonb_each_text(coalesce(NEW.qualification_payload, '{}'::jsonb));
      insert into public.cc_leads(lead_id, first_name, email, phone, city, province, segment, source, campaign,
          product_interest, quality, status, notes, raw)
      values(
        NEW.id, NEW.first_name, NEW.email, NEW.phone, NEW.city, coalesce(NEW.province,'BC'), NEW.segment,
        NEW.source, coalesce(NEW.utm_campaign, NEW.campaign_id),
        NEW.qualification_payload->>'outcome_key',
        case when NEW.qualified then 'qualified' else 'warm' end,
        'new', v_notes,
        jsonb_build_object(
          'lead_id', NEW.id,
          'qualification', coalesce(NEW.qualification_payload, '{}'::jsonb),
          'utm', jsonb_build_object('source',NEW.utm_source,'medium',NEW.utm_medium,'campaign',NEW.utm_campaign,'content',NEW.utm_content,'term',NEW.utm_term),
          'consent', jsonb_build_object('express',NEW.consent_express,'timestamp',NEW.consent_timestamp,'ip',NEW.consent_ip,'text',NEW.consent_text)))
      on conflict (lead_id) do update set
        first_name=excluded.first_name, email=excluded.email, phone=excluded.phone, city=excluded.city,
        province=excluded.province, segment=excluded.segment, source=excluded.source, campaign=excluded.campaign,
        product_interest=excluded.product_interest, quality=excluded.quality, notes=excluded.notes, raw=excluded.raw;
      return NEW;
    end $fn$;

    drop trigger if exists trg_leads_mirror_cc on public.leads;
    create trigger trg_leads_mirror_cc after insert on public.leads
      for each row execute function public.leads_mirror_to_cc_leads();
  $mig$;
end $$;

-- 4) push new (non-duplicate) leads to n8n for side-effects (Resend alert, setter). Never blocks the write.
create extension if not exists pg_net;

create table if not exists public.cc_config(
  key text primary key, value text, updated_at timestamptz not null default now());
alter table public.cc_config enable row level security;
insert into public.cc_config(key, value) values
  ('n8n_lead_webhook', 'https://calm-tiger-18.ash-1.instapods.app/webhook/lead-created')
  on conflict (key) do nothing;

create or replace function public.leads_notify_n8n()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_url text;
begin
  if NEW.is_duplicate then return NEW; end if;
  select value into v_url from public.cc_config where key='n8n_lead_webhook';
  if v_url is null or v_url = '' then return NEW; end if;
  perform net.http_post(
    url := v_url,
    headers := jsonb_build_object('Content-Type','application/json'),
    body := jsonb_build_object(
      'event','lead.created',
      'lead_id', NEW.id, 'source', NEW.source, 'segment', NEW.segment,
      'first_name', NEW.first_name, 'email', NEW.email, 'phone', NEW.phone,
      'city', NEW.city, 'province', NEW.province, 'qualified', NEW.qualified,
      'created_at', NEW.created_at));
  return NEW;
end $$;

drop trigger if exists trg_leads_notify_n8n on public.leads;
create trigger trg_leads_notify_n8n after insert on public.leads
  for each row execute function public.leads_notify_n8n();

-- 5) keep client roles out of the SECURITY DEFINER functions
revoke execute on all functions in schema public from public, anon, authenticated;
