-- =====================================================================
-- AADHAYA SALES — salesman access (run AFTER 20261022_team_hub.sql)
-- Salesmen = active team_members with role 'salesman'. They can:
--   ✔ read catalogue, sale rates, stock (v_stock), customer balances + overdue SALE bills
--   ✔ place orders through place_order() and read only their own orders
--   ✘ never read purchase rates, profit, suppliers, vouchers, expenses, ledgers, audit log
-- Accounts users (acct_users) are unaffected.
-- =====================================================================

create or replace function public.is_salesman() returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists(select 1 from team_members where email = lower(coalesce(auth.jwt()->>'email','')) and active and role = 'salesman')
$$;

-- same slug the app builds: client_ref = 'sm-<slug>-…'
create or replace function public.sm_slug() returns text
language sql stable as $$
  select left(regexp_replace(lower(coalesce(auth.jwt()->>'email','')), '[^a-z0-9]', '', 'g'), 24)
$$;

drop policy if exists sm_read on public.items;
create policy sm_read on public.items for select to authenticated using (is_salesman() and is_active and show_in_app);
drop policy if exists sm_read on public.categories;
create policy sm_read on public.categories for select to authenticated using (is_salesman());

drop policy if exists sm_read on public.orders;
create policy sm_read on public.orders for select to authenticated
  using (is_salesman() and client_ref like 'sm-' || sm_slug() || '-%');
drop policy if exists sm_read on public.order_lines;
create policy sm_read on public.order_lines for select to authenticated
  using (is_salesman() and exists (select 1 from orders o where o.id = order_id and o.client_ref like 'sm-' || sm_slug() || '-%'));

-- Owner-rights views: salesmen never need SELECT on vouchers / parties. No suppliers, no purchase bills.
create or replace view public.sm_parties with (security_invoker = false) as
  select party_id, code, name, kind, phone, city, balance, last_activity
    from v_party_balance where kind <> 'supplier' and (is_salesman() or is_acct_user());
create or replace view public.sm_bills with (security_invoker = false) as
  select bill_id, vno, vdate, party_id, total, due, age_days
    from v_bill_outstanding where vtype = 'sale' and due > 0 and (is_salesman() or is_acct_user());
revoke all on public.sm_parties, public.sm_bills from anon;
grant select on public.sm_parties, public.sm_bills to authenticated;

-- NOTE: a server-side repricing of place_order() was applied and reverted on 2026-10-22 within minutes.
-- The Order App deliberately sends 50%-off rates for 'disc' categories (e.g. 60 vs sale_rate 120),
-- so overwriting with variants.sale_rate would double those orders. place_order() is unchanged.
