-- =====================================================================
-- AADHAYA TEAM HUB — Slack jaisa kaam/message
--
-- Yatin (admin) sends a task or message to: everyone, one or more
-- departments, or chosen people. Each member sees "Aaj ka kaam" in the
-- Sales app, marks it done, and replies in a thread.
-- Additive only. Existing tables untouched. Audit trigger on every table.
-- =====================================================================

create table if not exists public.team_members (
  id         bigserial primary key,
  email      text unique check (email = lower(email)),
  name       text not null,
  phone      text,
  role       text not null default 'staff' check (role in ('admin','salesman','staff')),
  depts      text[] not null default '{}',          -- sales, production, packing, marketing, office
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.team_posts (
  id         bigserial primary key,
  created_at timestamptz not null default now(),
  created_by bigint not null references team_members(id),
  kind       text not null default 'message' check (kind in ('message','task')),
  title      text,
  body       text,
  to_all     boolean not null default false,
  to_depts   text[] not null default '{}',
  to_people  bigint[] not null default '{}',
  due_date   date,
  priority   text not null default 'normal' check (priority in ('normal','urgent')),
  check (kind <> 'task' or coalesce(title,'') <> ''),
  check (to_all or cardinality(to_depts) > 0 or cardinality(to_people) > 0)
);
create index if not exists team_posts_created on public.team_posts (created_at desc);

create table if not exists public.team_task_status (
  post_id    bigint not null references team_posts(id) on delete cascade,
  member_id  bigint not null references team_members(id),
  status     text not null default 'pending' check (status in ('pending','doing','done')),
  updated_at timestamptz not null default now(),
  primary key (post_id, member_id)
);

create table if not exists public.team_replies (
  id         bigserial primary key,
  post_id    bigint not null references team_posts(id) on delete cascade,
  member_id  bigint not null references team_members(id),
  body       text not null check (length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);

create table if not exists public.team_reads (
  post_id    bigint not null references team_posts(id) on delete cascade,
  member_id  bigint not null references team_members(id),
  read_at    timestamptz not null default now(),
  primary key (post_id, member_id)
);

-- ---------- helpers ----------
-- The caller's team row. Any Accounts login (acct_users: Yatin's several emails) acts as the admin row.
create or replace function public.team_me() returns team_members
language sql stable security definer set search_path to 'public' as $$
  select m.* from team_members m
   where m.active and (m.email = lower(coalesce(auth.jwt()->>'email','')) or (m.role = 'admin' and is_acct_user()))
   order by coalesce(m.email = lower(coalesce(auth.jwt()->>'email','')), false) desc, m.id limit 1
$$;
create or replace function public.team_is_admin() returns boolean
language sql stable security definer set search_path to 'public' as $$
  select is_acct_user() or coalesce((select role = 'admin' from team_members where email = lower(coalesce(auth.jwt()->>'email','')) and active), false)
$$;
create or replace function public.team_can_see(p team_posts) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select team_is_admin() or exists (
    select 1 from team_members m where m.email = lower(coalesce(auth.jwt()->>'email','')) and m.active
      and (p.created_by = m.id or p.to_all or m.id = any(p.to_people) or m.depts && p.to_depts))
$$;

-- ---------- row-level security ----------
alter table public.team_members     enable row level security;
alter table public.team_posts       enable row level security;
alter table public.team_task_status enable row level security;
alter table public.team_replies     enable row level security;
alter table public.team_reads       enable row level security;

create policy tm_read  on public.team_members for select to authenticated using ((team_me()).id is not null);
create policy tm_admin on public.team_members for all    to authenticated using (team_is_admin()) with check (team_is_admin());

create policy tp_read on public.team_posts for select to authenticated using (team_can_see(team_posts));
-- inserts only through team_send(); no direct insert/update/delete policy

create policy ts_read on public.team_task_status for select to authenticated
  using (team_is_admin() or member_id = (team_me()).id
         or exists (select 1 from team_posts p where p.id = post_id and team_can_see(p)));

create policy tr_read on public.team_replies for select to authenticated
  using (exists (select 1 from team_posts p where p.id = post_id and team_can_see(p)));
create policy tr_ins  on public.team_replies for insert to authenticated
  with check (member_id = (team_me()).id and exists (select 1 from team_posts p where p.id = post_id and team_can_see(p)));

create policy trd_own on public.team_reads for all to authenticated
  using (member_id = (team_me()).id) with check (member_id = (team_me()).id);

-- ---------- write paths ----------
-- Admin: any kind, any audience. Member: messages only, to their own departments / everyone / admin.
create or replace function public.team_send(p jsonb) returns json
language plpgsql security definer set search_path to 'public' as $$
declare me team_members; pid bigint; k text := coalesce(p->>'kind','message');
        deps text[] := coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p->'to_depts','[]')) x), '{}');
        ppl bigint[] := coalesce((select array_agg(x::bigint) from jsonb_array_elements_text(coalesce(p->'to_people','[]')) x), '{}');
begin
  me := team_me();
  if me.id is null then raise exception 'Aap team me nahi ho'; end if;
  if me.role <> 'admin' then
    if k = 'task' then raise exception 'Kaam sirf admin assign kar sakta hai'; end if;
    if not (deps <@ me.depts) then raise exception 'Sirf apne department me message kar sakte ho'; end if;
    if exists (select 1 from unnest(ppl) x where x not in (select id from team_members where role = 'admin'))
      then raise exception 'Direct message sirf admin ko'; end if;
  end if;
  perform pg_advisory_xact_lock(hashtext('team_send:' || me.id));
  -- double tap: same text from same person within 10 s = same post
  select id into pid from team_posts where created_by = me.id and coalesce(title,'') = coalesce(p->>'title','')
     and coalesce(body,'') = coalesce(p->>'body','') and created_at > now() - interval '10 seconds' limit 1;
  if pid is not null then return json_build_object('ok', true, 'id', pid, 'dup', true); end if;
  insert into team_posts(created_by, kind, title, body, to_all, to_depts, to_people, due_date, priority)
  values (me.id, k, nullif(left(p->>'title',200),''), nullif(left(p->>'body',4000),''),
          coalesce((p->>'to_all')::boolean,false), deps, ppl,
          nullif(p->>'due_date','')::date, coalesce(nullif(p->>'priority',''),'normal'))
  returning id into pid;
  return json_build_object('ok', true, 'id', pid);
end $$;

create or replace function public.team_set_status(p_post bigint, p_status text) returns json
language plpgsql security definer set search_path to 'public' as $$
declare me team_members; po team_posts;
begin
  me := team_me();
  select * into po from team_posts where id = p_post;
  if me.id is null or po.id is null or po.kind <> 'task' then raise exception 'Kaam nahi mila'; end if;
  if not (po.to_all or me.id = any(po.to_people) or me.depts && po.to_depts) then raise exception 'Ye kaam aapka nahi hai'; end if;
  insert into team_task_status(post_id, member_id, status) values (p_post, me.id, p_status)
  on conflict (post_id, member_id) do update set status = excluded.status, updated_at = now();
  return json_build_object('ok', true);
end $$;

revoke all on function public.team_send(jsonb), public.team_set_status(bigint,text) from anon;

-- audit like every other business table
create trigger trg_audit after insert or update or delete on public.team_posts       for each row execute function audit_row();
create trigger trg_audit after insert or update or delete on public.team_members     for each row execute function audit_row();

-- live updates in the app
alter publication supabase_realtime add table public.team_posts, public.team_task_status, public.team_replies;

-- ---------- seed: the current team ----------
-- Test phase: only Jemil. Bhavesh (7359204601) and Prashant (8200738802) are added once their emails arrive.
insert into team_members(email, name, phone, role, depts) values
  ('somnathcoating@gmail.com', 'Yatin',         null,         'admin',    '{sales,production,packing,marketing,office}'),
  ('jemilgoswami9@gmail.com',  'Jemil Goswami', '6352102610', 'salesman', '{sales}')
on conflict do nothing;
