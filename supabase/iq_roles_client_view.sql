-- Logins and the client page.
--
-- 1. Roles: admin and manager see everything. The old "staff" role is now "field_tech" (Field Tech),
--    which gets the Equipment pages only (no dashboard, unit setup or client page). Clients unchanged.
-- 2. Incident reports: extra details on staff_updates (severity, what was done, police/EMS, photo, where).
-- 3. web_client_view / web_incident_*: the client page and incident form. Admin and manager only for now.
--
-- Nobody had the "staff" role when this was written, so no logins change.

-- ---------- 1. roles ----------
alter table public.profiles drop constraint profiles_role_check;
alter table public.profiles add constraint profiles_role_check
  check (role in ('admin', 'manager', 'field_tech', 'client'));

-- Office staff: everything (dashboard, unit setup, client page, equipment).
create or replace function public.is_staff() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where user_id = auth.uid() and role in ('admin', 'manager'));
$$;

-- Can use the Equipment pages: office staff and Field Techs.
create or replace function public.is_field() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where user_id = auth.uid() and role in ('admin', 'manager', 'field_tech'));
$$;
revoke execute on function public.is_field() from public, anon;
grant execute on function public.is_field() to authenticated;

create or replace function public.web_me()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'signed_in', auth.uid() is not null,
    'email', (select email from auth.users where id = auth.uid()),
    'role', (select role from profiles where user_id = auth.uid()),
    'staff', coalesce(is_staff(), false),
    'field', coalesce(is_field(), false));
$$;

-- The equipment functions let Field Techs in too: swap their is_staff() check for is_field().
do $$
declare f record;
begin
  for f in select p.oid from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and (p.proname like 'web_gear\_%' or p.proname = 'web_set_my_name') loop
    execute replace(pg_get_functiondef(f.oid), 'is_staff()', 'is_field()');
  end loop;
end $$;

-- ---------- 2. incident details ----------
alter table public.staff_updates
  add column if not exists location        text check (char_length(location) <= 80),
  add column if not exists severity        text check (severity in ('low', 'medium', 'high')),
  add column if not exists action_taken    text check (char_length(action_taken) <= 80),
  add column if not exists police_notified boolean not null default false,
  add column if not exists photo_b64       text,
  add column if not exists by_name         text,
  add column if not exists created_at      timestamptz not null default now();

-- ---------- 3. client page ----------
create or replace function public.web_client_view(p_event_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_event uuid := p_event_id; v_from timestamptz; v_to timestamptz; v_now timestamptz := now();
begin
  if not coalesce(is_staff(), false) then raise exception 'not_allowed' using errcode = '42501'; end if;
  if v_event is null then
    select e.id into v_event from events e
     order by (e.status = 'live') desc, (select max(c.received_at) from counts c where c.event_id = e.id) desc nulls last, e.starts_at desc
     limit 1;
  end if;
  if v_event is null then raise exception 'no_event'; end if;

  -- The span the charts cover: from the first count to the last (at most the last 24 hours of it).
  select max(minute) into v_to from counts where event_id = v_event;
  v_to := coalesce(v_to, least(v_now, (select ends_at from events where id = v_event)));
  select greatest(min(minute), v_to - interval '24 hours') into v_from from counts where event_id = v_event;
  v_from := coalesce(v_from, v_to - interval '2 hours');

  return jsonb_build_object(
    'now', v_now,
    'event', (select jsonb_build_object('id', e.id, 'name', e.name, 'venue', e.venue, 'status', e.status,
                'starts_at', e.starts_at, 'ends_at', e.ends_at, 'client', cl.name,
                'last_received', (select max(received_at) from counts where event_id = e.id))
              from events e join clients cl on cl.id = e.client_id where e.id = v_event),
    'events', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'name', e.name, 'status', e.status,
                  'starts_at', e.starts_at, 'client', cl.name,
                  'total_in', coalesce((select sum(in_count) from counts where event_id = e.id), 0))
                  order by (e.status = 'live') desc, e.starts_at desc), '[]')
               from events e join clients cl on cl.id = e.client_id where e.status <> 'cancelled'),
    'checkpoints', (select coalesce(jsonb_agg(jsonb_build_object('id', cp.id, 'name', cp.name, 'kind', cp.kind,
                  'total_in', coalesce((select sum(in_count) from counts where checkpoint_id = cp.id), 0),
                  'last15_in', coalesce((select sum(in_count) from counts where checkpoint_id = cp.id and minute > v_to - interval '15 minutes'), 0),
                  'wait_now', (select w.wait_min from iq_wait_times(v_event, 15) w where w.checkpoint_id = cp.id order by w.minute desc limit 1),
                  'has_unit', exists (select 1 from device_assignments da where da.checkpoint_id = cp.id))
                  order by cp.sort_order, cp.name), '[]')
               from checkpoints cp where cp.event_id = v_event),
    -- people through screening per 15 minutes
    'buckets', (select coalesce(jsonb_agg(jsonb_build_object('t', b.t, 'n', b.n) order by b.t), '[]') from (
                  select g.t, coalesce(sum(c.in_count), 0) n
                  from generate_series(date_bin('15 minutes', v_from, 'epoch'), v_to, interval '15 minutes') g(t)
                  left join counts c on c.event_id = v_event and c.minute >= g.t and c.minute < g.t + interval '15 minutes'
                  group by g.t) b),
    -- average estimated wait (minutes) per 15 minutes, across checkpoints with a line camera
    'wait_buckets', (select coalesce(jsonb_agg(jsonb_build_object('t', w.t, 'wait', w.wait) order by w.t), '[]') from (
                  select date_bin('15 minutes', x.minute, 'epoch') t, round(avg(x.wait_min), 1) wait
                  from iq_wait_times(v_event, greatest(15, ceil(extract(epoch from v_now - v_from) / 60)::int)) x
                  where x.wait_min is not null and x.minute >= v_from
                  group by 1) w),
    'updates', (select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'at', u.occurred_at, 'category', u.category,
                  'category_label', ic.label, 'note', u.note, 'checkpoint', cp.name, 'location', u.location,
                  'severity', u.severity, 'action_taken', u.action_taken, 'police_notified', u.police_notified,
                  'has_photo', u.photo_b64 is not null, 'by_name', u.by_name, 'visible_to_client', u.visible_to_client)
                  order by u.occurred_at desc), '[]')
                from staff_updates u left join incident_categories ic on ic.code = u.category
                left join checkpoints cp on cp.id = u.checkpoint_id where u.event_id = v_event),
    'categories', (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'label', label) order by sort_order), '[]')
                   from incident_categories));
end $$;

create or replace function public.web_incident_save(p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_id uuid; v_event uuid := nullif(p->>'event_id', '')::uuid; v_cp uuid := nullif(p->>'checkpoint_id', '')::uuid;
  v_at timestamptz := coalesce(nullif(p->>'occurred_at', '')::timestamptz, now());
  v_photo text := nullif(p->>'photo_b64', '');
begin
  if not coalesce(is_staff(), false) then raise exception 'not_allowed' using errcode = '42501'; end if;
  if v_event is null or not exists (select 1 from events where id = v_event) then raise exception 'need_event'; end if;
  if v_cp is not null and not exists (select 1 from checkpoints where id = v_cp and event_id = v_event) then raise exception 'bad_checkpoint'; end if;
  if not exists (select 1 from incident_categories where code = p->>'category') then raise exception 'need_category'; end if;
  if abs(extract(epoch from v_at - now())) > 7 * 86400 then raise exception 'bad_date'; end if;
  if v_photo is not null and length(v_photo) > 900000 then raise exception 'photo_too_big'; end if;
  insert into staff_updates (event_id, checkpoint_id, location, category, severity, action_taken, note,
                             police_notified, visible_to_client, occurred_at, photo_b64, author_id, by_name)
  values (v_event, v_cp, left(nullif(trim(p->>'location'), ''), 80), p->>'category',
          coalesce(nullif(p->>'severity', ''), 'low'), left(nullif(trim(p->>'action_taken'), ''), 80),
          left(nullif(trim(p->>'note'), ''), 2000), coalesce((p->>'police_notified')::boolean, false),
          coalesce((p->>'visible_to_client')::boolean, false), v_at, v_photo, auth.uid(), gear_my_name())
  returning id into v_id;
  return jsonb_build_object('id', v_id);
end $$;

-- Show or hide one report on the client's page.
create or replace function public.web_incident_share(p_id uuid, p_visible boolean)
returns boolean language plpgsql volatile security definer set search_path = public as $$
begin
  if not coalesce(is_staff(), false) then raise exception 'not_allowed' using errcode = '42501'; end if;
  update staff_updates set visible_to_client = coalesce(p_visible, false) where id = p_id;
  return coalesce(p_visible, false);
end $$;

create or replace function public.web_incident_photo(p_id uuid)
returns text language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(is_staff(), false) then raise exception 'not_allowed' using errcode = '42501'; end if;
  return (select photo_b64 from staff_updates where id = p_id);
end $$;

revoke execute on function public.web_client_view(uuid), public.web_incident_save(jsonb),
  public.web_incident_share(uuid, boolean), public.web_incident_photo(uuid) from public, anon;
grant execute on function public.web_client_view(uuid), public.web_incident_save(jsonb),
  public.web_incident_share(uuid, boolean), public.web_incident_photo(uuid) to authenticated;
