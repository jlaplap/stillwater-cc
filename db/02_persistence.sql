-- Stillwater Command Center — persistence RPCs (v1)
-- Run SECOND (after 01_schema.sql). Transactional operations the Command Center
-- calls via the Supabase service connection (execute_sql). All are SECURITY DEFINER
-- with a pinned search_path; client roles cannot execute them (see revoke block).

-- ---------- buyers ----------
create or replace function sw_upsert_buyer(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v buyers;
  segs text[] := coalesce((select array_agg(value) from jsonb_array_elements_text(coalesce(p->'segments_wanted','[]'::jsonb))),'{}');
  provs text[] := coalesce((select array_agg(value) from jsonb_array_elements_text(coalesce(p->'provinces_wanted','[]'::jsonb))),'{}');
  agree boolean := coalesce((p->>'agreement_consent')::boolean, false);
begin
  if (p->>'id') is not null and exists (select 1 from buyers where id = (p->>'id')::uuid) then
    update buyers set
      company = coalesce(p->>'company', company),
      contact_name = p->>'contact_name',
      email = coalesce(nullif(p->>'email',''), email),
      phone = p->>'phone',
      segments_wanted = segs,
      provinces_wanted = provs,
      price_per_lead = nullif(p->>'price_per_lead','')::numeric,
      notes = p->>'notes',
      status = coalesce(nullif(p->>'status','')::buyer_status, status),
      agreement_consent = agree,
      agreement_timestamp = case when agree then coalesce(agreement_timestamp, now()) else null end
    where id = (p->>'id')::uuid
    returning * into v;
  else
    insert into buyers(company,contact_name,email,phone,segments_wanted,provinces_wanted,price_per_lead,notes,status,agreement_consent,agreement_timestamp)
    values (p->>'company', p->>'contact_name', coalesce(nullif(p->>'email',''),'noemail@unknown.local'),
      p->>'phone', segs, provs, nullif(p->>'price_per_lead','')::numeric, p->>'notes',
      coalesce(nullif(p->>'status','')::buyer_status,'active'),
      agree, case when agree then now() else null end)
    returning * into v;
  end if;
  insert into audit_log(entity,entity_id,action,payload) values ('buyer', v.id, 'upsert', to_jsonb(v));
  return to_jsonb(v);
end $$;

create or replace function sw_set_buyer_status(p_buyer uuid, p_status text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v buyers;
begin
  update buyers set status = p_status::buyer_status where id = p_buyer returning * into v;
  insert into audit_log(entity,entity_id,action,payload) values ('buyer', p_buyer, 'status:'||p_status, to_jsonb(v));
  return to_jsonb(v);
end $$;

-- ---------- batches ----------
-- Materializes HubSpot leads into the leads table, then creates the batch.
-- uq_lead_single_batch is the DB-level double-sell guard: a lead already in any
-- batch is silently skipped (exclusive single-sale).
create or replace function sw_create_batch(
  p_buyer uuid, p_name text, p_excl text, p_unit numeric, p_segment text, p_leads jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_batch batches; v_item jsonb; v_lead_id uuid; v_count int := 0; v_excl exclusivity_t := p_excl::exclusivity_t;
begin
  insert into batches(name,buyer_id,segment_filter,exclusivity,status,lead_count,total_price)
  values (p_name, p_buyer, nullif(p_segment,''), v_excl, 'draft', 0, 0)
  returning * into v_batch;

  for v_item in select value from jsonb_array_elements(coalesce(p_leads,'[]'::jsonb))
  loop
    insert into leads(hubspot_contact_id,segment,first_name,email,phone,city,province,utm_source,status,exclusivity,dedupe_key)
    values (
      nullif(v_item->>'hubspot_contact_id',''),
      coalesce(nullif(v_item->>'segment',''),'unknown'),
      v_item->>'first_name', v_item->>'email', v_item->>'phone',
      v_item->>'city', v_item->>'province', v_item->>'source',
      'new', v_excl,
      lower(coalesce(v_item->>'email',''))||'|'||regexp_replace(coalesce(v_item->>'phone',''),'\D','','g'))
    on conflict (hubspot_contact_id) do update set segment = excluded.segment, updated_at = now()
    returning id into v_lead_id;

    begin
      insert into batch_leads(batch_id,lead_id,sale_price) values (v_batch.id, v_lead_id, p_unit);
      update leads set status = 'batched' where id = v_lead_id and status in ('new','qualified');
      v_count := v_count + 1;
    exception when unique_violation then null; -- lead already in a batch: skip
    end;
  end loop;

  update batches set lead_count = v_count, total_price = v_count * p_unit where id = v_batch.id returning * into v_batch;
  insert into audit_log(entity,entity_id,action,payload) values ('batch', v_batch.id, 'created', to_jsonb(v_batch));
  return to_jsonb(v_batch);
end $$;

create or replace function sw_send_batch(p_batch uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_batch batches;
begin
  update batches set status = 'sent', sent_at = now() where id = p_batch returning * into v_batch;
  update leads l set status = 'sent',
    shelved_at = case when v_batch.exclusivity = 'exclusive' then now() else l.shelved_at end
  from batch_leads bl where bl.batch_id = p_batch and bl.lead_id = l.id;
  -- Addendum #2: CSV export + manual handoff, so no per-lead delivery rows are created here.
  insert into audit_log(entity,entity_id,action,payload) values ('batch', p_batch, 'sent', to_jsonb(v_batch));
  return to_jsonb(v_batch);
end $$;

-- ---------- invoices ----------
create or replace function sw_create_invoice(p_batch uuid, p_due date default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_inv invoices; v_batch batches;
begin
  select * into v_batch from batches where id = p_batch;
  insert into invoices(batch_id,buyer_id,amount,status,due_date)
    values (p_batch, v_batch.buyer_id, v_batch.total_price, 'open', coalesce(p_due, current_date + 7))
    returning * into v_inv;
  update batches set status = 'invoiced' where id = p_batch;
  insert into audit_log(entity,entity_id,action,payload) values ('invoice', v_inv.id, 'created', to_jsonb(v_inv));
  return to_jsonb(v_inv);
end $$;

create or replace function sw_mark_invoice_paid(p_inv uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_inv invoices;
begin
  update invoices set status = 'paid', paid_at = now() where id = p_inv returning * into v_inv;
  update batches set status = 'paid' where id = v_inv.batch_id;
  update leads l set status = 'sold' from batch_leads bl where bl.batch_id = v_inv.batch_id and bl.lead_id = l.id;
  insert into audit_log(entity,entity_id,action,payload) values ('invoice', v_inv.id, 'paid', to_jsonb(v_inv));
  return to_jsonb(v_inv);
end $$;

-- void / refund: releases the leads back into the pool for resale
create or replace function sw_void_invoice(p_inv uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_inv invoices; v_b uuid;
begin
  update invoices set status = 'void' where id = p_inv returning * into v_inv;
  v_b := v_inv.batch_id;
  update leads l set status = 'refunded', shelved_at = null
    from batch_leads bl where bl.batch_id = v_b and bl.lead_id = l.id;
  delete from batch_leads where batch_id = v_b;
  update batches set status = 'draft', lead_count = 0, total_price = 0 where id = v_b;
  insert into audit_log(entity,entity_id,action,payload) values ('invoice', v_inv.id, 'void', to_jsonb(v_inv));
  return to_jsonb(v_inv);
end $$;

-- ---------- lock down execute ----------
-- These RPCs are only ever called through the Supabase service connection (owner role),
-- which executes regardless of grants. Postgres grants EXECUTE to PUBLIC by default, so
-- revoke it to keep anon/authenticated from invoking them via /rest/v1/rpc.
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public;
