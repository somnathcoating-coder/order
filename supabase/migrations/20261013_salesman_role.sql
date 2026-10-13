-- =====================================================================
-- AADHAYA SALES — salesman role (NOT YET APPLIED — review, then run once)
--
-- Goal: field salesmen can log in to salesman.html and
--   ✔ see catalogue, sale rates, stock availability
--   ✔ see customer/dealer balance + overdue SALE bills
--   ✔ place orders (existing place_order RPC) and see THEIR OWN orders
--   ✘ never see purchase rates, profit, suppliers, purchase bills,
--     expenses, ledgers, audit log — and cannot write to any table.
--
-- Accounts users (acct_users) are unaffected.
-- Add a salesman:  1) Supabase → Auth → Add user (email + password)
--                  2) insert into salesmen(email,name,phone) values ('ravi@…','Ravi','98…');
-- Switch off:      update salesmen set active=false where email='ravi@…';
-- =====================================================================

create table if not exists public.salesmen (
  email      text primary key check (email = lower(email)),
  name       text not null,
  phone      text,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.salesmen enable row level security;
drop policy if exists acct_all on public.salesmen;
create policy acct_all on public.salesmen for all to authenticated
  using (is_acct_user()) with check (is_acct_user());
drop policy if exists self_read on public.salesmen;
create policy self_read on public.salesmen for select to authenticated
  using (email = lower(coalesce(auth.jwt()->>'email','')));

create or replace function public.is_salesman() returns boolean
language sql stable security definer set search_path to 'public' as $$
  select exists(select 1 from salesmen
                 where email = lower(coalesce(auth.jwt()->>'email','')) and active)
$$;

-- same slug the app builds: client_ref = 'sm-<slug>-…'
create or replace function public.sm_slug() returns text
language sql stable as $$
  select left(regexp_replace(lower(coalesce(auth.jwt()->>'email','')), '[^a-z0-9]', '', 'g'), 24)
$$;

-- ---------- read-only catalogue ----------
drop policy if exists sm_read on public.items;
create policy sm_read on public.items for select to authenticated
  using (is_salesman() and is_active and show_in_app);
drop policy if exists sm_read on public.categories;
create policy sm_read on public.categories for select to authenticated
  using (is_salesman());
-- v_stock is an owner-rights view (sale_rate only, no purchase_rate) → no change needed.

-- ---------- own orders only ----------
drop policy if exists sm_read on public.orders;
create policy sm_read on public.orders for select to authenticated
  using (is_salesman() and client_ref like 'sm-' || sm_slug() || '-%');
drop policy if exists sm_read on public.order_lines;
create policy sm_read on public.order_lines for select to authenticated
  using (is_salesman() and exists (select 1 from orders o where o.id = order_id
                                     and o.client_ref like 'sm-' || sm_slug() || '-%'));

-- ---------- dealer balance + overdue sale bills (filtered views) ----------
-- Owner-rights views (security_invoker = false) over the existing views, so
-- salesmen never need SELECT on vouchers / parties. Suppliers and purchase
-- bills are filtered out. Accounts users can read them too.
create or replace view public.sm_parties with (security_invoker = false) as
  select party_id, code, name, kind, phone, city, balance, last_activity
    from v_party_balance
   where kind <> 'supplier' and (is_salesman() or is_acct_user());

create or replace view public.sm_bills with (security_invoker = false) as
  select bill_id, vno, vdate, party_id, total, due, age_days
    from v_bill_outstanding
   where vtype = 'sale' and due > 0 and (is_salesman() or is_acct_user());

revoke all on public.sm_parties, public.sm_bills from anon;
grant select on public.sm_parties, public.sm_bills to authenticated;

-- place_order(jsonb) is already executable by authenticated — nothing to add.
