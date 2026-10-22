-- =====================================================================
-- AADHAYA LEADS — city-wise pipeline + visiting cards
-- Requires 20261022_team_hub.sql (team_members, team_me, team_is_admin).
-- Leads are private to the salesman who created them; admin sees all.
-- They never appear in parties / Order App / Accounts until admin promotes one.
-- =====================================================================

create table if not exists public.prospects (
  id              bigserial primary key,
  owner_id        bigint not null references team_members(id),
  firm            text,
  person          text,
  designation     text,
  mobile          text check (mobile is null or mobile ~ '^[6-9][0-9]{9}$'),
  mobile2         text,
  email           text,
  website         text,
  address         text,
  area            text,
  city            text not null,
  state           text default 'Gujarat',
  pincode         text check (pincode is null or pincode ~ '^[0-9]{6}$'),
  gstin           text,
  biz_type        text,
  stage           text not null default 'new' check (stage in ('new','interested','followup','won','lost')),
  next_follow_up  date,
  notes           text,
  card_path       text,                 -- storage: visiting-cards/<owner_id>/<file>.jpg
  maps_url        text,
  lat             numeric(9,6),
  lng             numeric(9,6),
  loc_source      text check (loc_source in ('gps','maps_link','verified')),  -- never geocoded from an address
  promoted_party_id bigint references parties(id),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  check (coalesce(firm,'') <> '' or coalesce(person,'') <> '')
);
create index if not exists prospects_city on public.prospects (lower(city));
create index if not exists prospects_mobile on public.prospects (mobile);

create table if not exists public.lead_visits (
  id             bigserial primary key,
  prospect_id    bigint not null references prospects(id) on delete cascade,
  member_id      bigint not null references team_members(id),
  note           text not null,
  next_follow_up date,
  lat            numeric(9,6),
  lng            numeric(9,6),
  created_at     timestamptz not null default now()
);

alter table public.prospects   enable row level security;
alter table public.lead_visits enable row level security;
create policy pr_read on public.prospects for select to authenticated using (team_is_admin() or owner_id = (team_me()).id);
create policy lv_read on public.lead_visits for select to authenticated
  using (exists (select 1 from prospects p where p.id = prospect_id and (team_is_admin() or p.owner_id = (team_me()).id)));
-- writes only via the functions below

-- owner name for the admin view (and duplicate hints)
create or replace view public.v_prospects with (security_invoker = true) as
  select p.*, m.name as owner_name from prospects p join team_members m on m.id = p.owner_id;

create or replace function public.lead_save(p jsonb) returns json
language plpgsql security definer set search_path to 'public' as $$
declare me team_members; rid bigint := nullif(p->>'id','')::bigint; cur prospects;
begin
  me := team_me(); if me.id is null then raise exception 'Aap team me nahi ho'; end if;
  if rid is not null then
    select * into cur from prospects where id = rid for update;
    if cur.id is null or (cur.owner_id <> me.id and me.role <> 'admin') then raise exception 'Ye lead aapka nahi hai'; end if;
    if p->>'stage' = 'won' and me.role <> 'admin' then raise exception 'Customer sirf admin bana sakta hai'; end if;
  end if;
  insert into prospects as x (id, owner_id, firm, person, designation, mobile, mobile2, email, website, address, area, city, state,
                              pincode, gstin, biz_type, stage, next_follow_up, notes, card_path, maps_url, lat, lng, loc_source)
  values (coalesce(rid, nextval('prospects_id_seq')), coalesce(cur.owner_id, me.id),
          nullif(p->>'firm',''), nullif(p->>'person',''), nullif(p->>'designation',''), nullif(p->>'mobile',''), nullif(p->>'mobile2',''),
          nullif(p->>'email',''), nullif(p->>'website',''), nullif(p->>'address',''), nullif(p->>'area',''), initcap(trim(p->>'city')),
          coalesce(nullif(p->>'state',''),'Gujarat'), nullif(p->>'pincode',''), nullif(upper(p->>'gstin'),''), nullif(p->>'biz_type',''),
          coalesce(nullif(p->>'stage',''),'new'), nullif(p->>'next_follow_up','')::date, nullif(p->>'notes',''),
          nullif(p->>'card_path',''), nullif(p->>'maps_url',''), nullif(p->>'lat','')::numeric, nullif(p->>'lng','')::numeric,
          nullif(p->>'loc_source',''))
  on conflict (id) do update set firm=excluded.firm, person=excluded.person, designation=excluded.designation, mobile=excluded.mobile,
     mobile2=excluded.mobile2, email=excluded.email, website=excluded.website, address=excluded.address, area=excluded.area,
     city=excluded.city, state=excluded.state, pincode=excluded.pincode, gstin=excluded.gstin, biz_type=excluded.biz_type,
     stage=excluded.stage, next_follow_up=excluded.next_follow_up, notes=excluded.notes,
     card_path=coalesce(excluded.card_path, x.card_path), maps_url=excluded.maps_url,
     lat=coalesce(excluded.lat, x.lat), lng=coalesce(excluded.lng, x.lng), loc_source=coalesce(excluded.loc_source, x.loc_source),
     updated_at=now()
  returning id into rid;
  return json_build_object('ok', true, 'id', rid);
end $$;

-- duplicate check across ALL leads + customers, returning only firm + owner (no contact details of other salesmen's leads)
create or replace function public.lead_dup(p_mobile text) returns json
language sql stable security definer set search_path to 'public' as $$
  select coalesce(json_agg(json_build_object('id', p.id, 'firm', p.firm, 'person', p.person, 'owner_name', m.name)), '[]')
    from prospects p join team_members m on m.id = p.owner_id
   where (team_me()).id is not null and right(regexp_replace(coalesce(p_mobile,''),'\D','','g'),10) in (p.mobile, p.mobile2)
$$;

create or replace function public.lead_visit(p jsonb) returns json
language plpgsql security definer set search_path to 'public' as $$
declare me team_members; pr prospects;
begin
  me := team_me(); select * into pr from prospects where id = (p->>'prospect_id')::bigint;
  if me.id is null or pr.id is null or (pr.owner_id <> me.id and me.role <> 'admin') then raise exception 'Ye lead aapka nahi hai'; end if;
  insert into lead_visits(prospect_id, member_id, note, next_follow_up, lat, lng)
  values (pr.id, me.id, left(p->>'note',2000), nullif(p->>'next_follow_up','')::date, nullif(p->>'lat','')::numeric, nullif(p->>'lng','')::numeric);
  update prospects set next_follow_up = nullif(p->>'next_follow_up','')::date,
         stage = case when stage = 'new' then 'followup' else stage end, updated_at = now() where id = pr.id;
  return json_build_object('ok', true);
end $$;

revoke all on function public.lead_save(jsonb), public.lead_dup(text), public.lead_visit(jsonb) from anon;
create trigger trg_audit after insert or update or delete on public.prospects for each row execute function audit_row();

-- private bucket for card photos: each salesman reads/writes only their own folder; admin reads all
insert into storage.buckets (id, name, public) values ('visiting-cards','visiting-cards', false) on conflict (id) do nothing;
create policy vc_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'visiting-cards' and (storage.foldername(name))[1] = (public.team_me()).id::text);
create policy vc_select on storage.objects for select to authenticated
  using (bucket_id = 'visiting-cards' and (public.team_is_admin() or (storage.foldername(name))[1] = (public.team_me()).id::text));
