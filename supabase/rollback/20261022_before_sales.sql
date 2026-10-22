-- Rollback for the 2026-10-22 Sales app migrations (team hub, salesman access, leads).
-- Restores place_order() exactly as it was and removes everything the migrations added.
-- Existing data (orders, vouchers, parties, items…) is never touched by those migrations.

drop policy if exists sm_read on public.items;
drop policy if exists sm_read on public.categories;
drop policy if exists sm_read on public.orders;
drop policy if exists sm_read on public.order_lines;
drop view if exists public.sm_parties, public.sm_bills, public.v_prospects;
drop policy if exists vc_insert on storage.objects;
drop policy if exists vc_select on storage.objects;
drop table if exists public.lead_visits, public.prospects, public.team_reads, public.team_replies,
                     public.team_task_status, public.team_posts, public.team_members cascade;
drop function if exists public.lead_save(jsonb), public.lead_dup(text), public.lead_visit(jsonb),
                        public.team_send(jsonb), public.team_set_status(bigint,text), public.team_can_see(team_posts),
                        public.is_salesman(), public.sm_slug(), public.team_is_admin(), public.team_me();

-- place_order as of 2026-10-22 09:30 UTC (before the server-side price fix)
CREATE OR REPLACE FUNCTION public.place_order(p jsonb)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  ref text := left(coalesce(p->>'client_ref',''), 64);
  mob text := right(regexp_replace(coalesce(p->>'mobile',''), '\D', '', 'g'), 10);
  oid bigint; ono text; n int; recent int; tot numeric := 0; pid bigint;
begin
  if length(ref) < 8 then raise exception 'bad ref'; end if;
  select id, order_no into oid, ono from orders where client_ref = ref;
  if found then
    update orders set attempts = attempts + 1 where id = oid;
    return json_build_object('ok', true, 'order_no', ono, 'dup', true);
  end if;   -- retry = wahi order

  if length(mob) <> 10 then raise exception 'mobile'; end if;
  n := jsonb_array_length(coalesce(p->'items','[]'));
  if n = 0 or n > 200 then raise exception 'items'; end if;
  select count(*) into recent from orders where mobile = mob and created_at > now() - interval '1 hour';
  if recent >= 10 then raise exception 'too many orders'; end if;

  select id into pid from parties
   where right(regexp_replace(coalesce(phone,''), '\D', '', 'g'), 10) = mob and is_active
   order by id limit 1;

  perform pg_advisory_xact_lock(hashtext('orderno'));
  select 'O-' || lpad((coalesce(max(substring(order_no from '(\d+)$')::int), 0) + 1)::text, 4, '0') into ono from orders;

  insert into orders(order_no, client_ref, cust_name, mobile, city, firm, note, party_id, attempts, client_at)
  values (ono, ref, left(p->>'name',80), mob, left(p->>'city',60), left(p->>'firm',100), left(p->>'note',500), pid,
          greatest(coalesce((p->>'attempt')::int,1),1),
          case when (p->>'client_at') ~ '^\d+$' then to_timestamp((p->>'client_at')::bigint/1000.0) end)
  returning id into oid;

  insert into order_lines(order_id, app_code, name, size, finish, variant_id, qty, rate)
  select oid, left(it->>'code',40), left(it->>'name',120),
         coalesce(nullif(trim(it->>'size'),''), '-'), coalesce(nullif(trim(it->>'finish'),''), '-'),
         (select va.id from variants va join items i on i.id = va.item_id
           where i.app_code in (it->>'code', (it->>'code') || '-CUT') and va.is_active and i.is_active
             and lower(trim(va.size))   = lower(coalesce(nullif(trim(it->>'size'),''), '-'))
             and lower(trim(va.finish)) = lower(coalesce(nullif(trim(it->>'finish'),''), '-'))
           order by (i.app_code = it->>'code') desc, va.id limit 1),
         least(greatest(coalesce((it->>'qty')::numeric, 1), 1), 100000),
         greatest(coalesce((it->>'price')::numeric, 0), 0)
    from jsonb_array_elements(p->'items') it;

  select coalesce(sum(qty * rate), 0) into tot from order_lines where order_id = oid;
  update orders set est_total = tot where id = oid;
  return json_build_object('ok', true, 'order_no', ono);
end $function$;
