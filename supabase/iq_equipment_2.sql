-- Equipment sign-out, part 2: batteries, write-in location, date out / date back.
-- Additive only: one new table (one row per sign-out or return "sheet") and one new save function.
-- Existing functions are replaced with versions that also return the new details.
-- No drop statements (Supabase asks for an extra confirm on those).

create table if not exists public.equipment_batches (
  id          uuid primary key,                      -- same as equipment_moves.batch_id
  action      text not null check (action in ('out', 'back')),
  event_name  text not null check (char_length(event_name) between 1 and 200),
  location    text check (char_length(location) <= 200),
  batteries   int check (batteries between 0 and 500),
  date_out    date,
  date_back   date,
  by_user     uuid not null references auth.users (id),
  by_name     text not null,
  at          timestamptz not null default now()
);
create index if not exists equipment_batches_event on public.equipment_batches (event_name, at desc);
alter table public.equipment_batches enable row level security;
create policy staff_read on public.equipment_batches for select to authenticated using (is_staff());

-- Batch details for one move, as JSON (null for moves saved before this change).
create or replace function public.gear_batch_json(p_batch uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('location', b.location, 'batteries', b.batteries, 'date_out', b.date_out, 'date_back', b.date_back)
  from equipment_batches b where b.id = p_batch;
$$;
revoke all on function public.gear_batch_json(uuid) from public, anon, authenticated;

-- Save a sign-out or return. One call = one sheet.
-- p: {"action":"out"|"back", "event_name":"...", "location":"...", "batteries":4,
--     "date_out":"2026-11-03", "date_back":"2026-11-05",
--     "items":[{"id":"...", "condition":"ok"|"damaged", "note":"...", "photo_b64":"..."}]}
create or replace function public.web_gear_save(p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_batch uuid := gen_random_uuid(); v_name text; v_event uuid; it jsonb; v_id uuid; v_n int := 0;
  v_action text := p->>'action'; v_ev text := nullif(trim(p->>'event_name'), '');
  v_out date; v_back date; v_bat int;
begin
  if not coalesce(is_staff(), false) then raise exception 'not_allowed' using errcode = '42501'; end if;
  if v_action is null or v_action not in ('out', 'back') then raise exception 'bad_action'; end if;
  if v_ev is null then raise exception 'need_event'; end if;
  if jsonb_typeof(p->'items') is distinct from 'array' or jsonb_array_length(p->'items') = 0 then raise exception 'no_items'; end if;
  v_out := nullif(p->>'date_out', '')::date;
  v_back := nullif(p->>'date_back', '')::date;
  if v_out is not null and abs(v_out - current_date) > 400 then raise exception 'bad_date'; end if;
  if v_back is not null and abs(v_back - current_date) > 400 then raise exception 'bad_date'; end if;
  if v_out is not null and v_back is not null and v_back < v_out then raise exception 'back_before_out'; end if;
  v_bat := nullif(p->>'batteries', '')::int;
  v_name := gear_my_name();
  select id into v_event from events where name = v_ev order by (status = 'live') desc, starts_at desc limit 1;
  insert into equipment_batches (id, action, event_name, location, batteries, date_out, date_back, by_user, by_name)
  values (v_batch, v_action, v_ev, nullif(trim(p->>'location'), ''), v_bat, v_out, v_back, auth.uid(), v_name);
  for it in select * from jsonb_array_elements(p->'items') loop
    v_id := (it->>'id')::uuid;
    if not exists (select 1 from equipment where id = v_id and active) then raise exception 'unknown_item'; end if;
    insert into equipment_moves (equipment_id, action, condition, note, photo_b64, event_id, event_name, by_user, by_name, batch_id)
    values (v_id, v_action, coalesce(nullif(it->>'condition', ''), 'ok'), nullif(trim(it->>'note'), ''),
            nullif(it->>'photo_b64', ''), v_event, v_ev, auth.uid(), v_name, v_batch);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('batch_id', v_batch, 'count', v_n, 'by_name', v_name);
end $$;

-- Scan page data, now also with: IQ events to pick from (with venue), and the sheet the unit last went out on.
create or replace function public.web_gear_item(p_code text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v equipment; v_event text; v_last uuid;
begin
  if not coalesce(is_staff(), false) then raise exception 'not_allowed' using errcode = '42501'; end if;
  select * into v from equipment where code = upper(trim(p_code));
  if v.id is null then raise exception 'unknown_item'; end if;
  select event_name into v_event from equipment_moves
    where by_user = auth.uid() and at > now() - interval '18 hours' order by at desc limit 1;
  if v_event is null then
    select name into v_event from events where status = 'live' order by starts_at desc limit 1;
  end if;
  select batch_id into v_last from equipment_moves where equipment_id = v.id and action = 'out' order by at desc limit 1;
  return jsonb_build_object(
    'item', gear_status_json(v),
    'my_name', gear_my_name(),
    'needs_name', not exists (select 1 from auth.users u left join profiles p on p.user_id = u.id where u.id = auth.uid()
                    and coalesce(nullif(trim(p.full_name), ''), nullif(trim(u.raw_user_meta_data->>'full_name'), '')) is not null),
    'suggested_event', v_event,
    'last_out', gear_batch_json(v_last),
    'same_kind', (select coalesce(jsonb_agg(gear_status_json(e) order by e.serial), '[]') from equipment e
                   where e.kind = v.kind and e.active and e.id <> v.id),
    'history', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'action', m.action, 'condition', m.condition,
                  'note', m.note, 'has_photo', m.photo_b64 is not null, 'event_name', m.event_name,
                  'by_name', m.by_name, 'at', m.at, 'batch', gear_batch_json(m.batch_id)) order by m.at desc), '[]')
                from (select * from equipment_moves where equipment_id = v.id order by at desc limit 50) m),
    'events', (select coalesce(jsonb_agg(jsonb_build_object('name', name, 'venue', venue) order by (status = 'live') desc, starts_at desc), '[]')
               from events where status in ('planned', 'live')),
    'event_names', (select coalesce(jsonb_agg(n), '[]') from (
                  select event_name n from equipment_moves group by 1 order by max(at) desc limit 15) y));
end $$;

-- History for one unit or one event, now with each sheet's location, batteries and dates.
create or replace function public.web_gear_history(p_code text default null, p_event_name text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(is_staff(), false) then raise exception 'not_allowed' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'code', e.code, 'kind', e.kind, 'serial', e.serial,
            'action', m.action, 'condition', m.condition, 'note', m.note, 'has_photo', m.photo_b64 is not null,
            'event_name', m.event_name, 'by_name', m.by_name, 'at', m.at, 'batch_id', m.batch_id,
            'batch', gear_batch_json(m.batch_id)) order by m.at), '[]')
          from equipment_moves m join equipment e on e.id = m.equipment_id
          where (p_code is null or e.code = upper(trim(p_code)))
            and (p_event_name is null or m.event_name = p_event_name)
            and (p_code is not null or p_event_name is not null));
end $$;

revoke all on function public.web_gear_save(jsonb) from public, anon;
grant execute on function public.web_gear_save(jsonb) to authenticated;
