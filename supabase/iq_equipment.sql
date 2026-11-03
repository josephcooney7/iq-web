-- Equipment sign-out by QR sticker (replaces the paper OpenGate sign-out sheet).
-- Additive only: two new tables + new web_gear_* functions. Nothing existing is changed.
--
-- equipment       one row per physical piece of gear (each has a QR sticker pointing at /g/<code>)
-- equipment_moves one row every time something is signed out or returned (never edited or deleted)
--
-- Who did it and when come from the login and the clock, not from what the phone sends.

create table if not exists public.equipment (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,                -- what the sticker points at, e.g. OG-49000
  kind        text not null,                       -- e.g. OpenGate, X-ray
  serial      text not null,                       -- kept as text so 04501 keeps its leading zero
  label       text,                                -- optional nickname
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  unique (kind, serial)
);

create table if not exists public.equipment_moves (
  id           uuid primary key default gen_random_uuid(),
  equipment_id uuid not null references public.equipment (id),
  action       text not null check (action in ('out', 'back')),
  condition    text not null default 'ok' check (condition in ('ok', 'damaged')),
  note         text check (char_length(note) <= 1000),
  photo_b64    text check (char_length(photo_b64) <= 700000),  -- small JPEG, only when damaged
  event_id     uuid references public.events (id),
  event_name   text not null check (char_length(event_name) between 1 and 200),
  by_user      uuid not null references auth.users (id),
  by_name      text not null,
  batch_id     uuid not null,                       -- moves made together share one batch (one "sheet")
  at           timestamptz not null default now()
);
create index if not exists equipment_moves_item_at on public.equipment_moves (equipment_id, at desc);
create index if not exists equipment_moves_event on public.equipment_moves (event_name, at desc);
create index if not exists equipment_moves_batch on public.equipment_moves (batch_id);

alter table public.equipment       enable row level security;
alter table public.equipment_moves enable row level security;
create policy staff_all on public.equipment       for all to authenticated using (is_staff()) with check (is_staff());
create policy staff_read on public.equipment_moves for select to authenticated using (is_staff());
-- No insert/update/delete policy on moves: the website writes them only through web_gear_move,
-- so nobody can back-date or change history.

-- Starting gear: the 8 CEIA OpenGates from the paper sheet.
insert into public.equipment (code, kind, serial) values
  ('OG-49000', 'OpenGate', '49000'), ('OG-49001', 'OpenGate', '49001'),
  ('OG-49016', 'OpenGate', '49016'), ('OG-04501', 'OpenGate', '04501'),
  ('OG-04507', 'OpenGate', '04507'), ('OG-04508', 'OpenGate', '04508'),
  ('OG-49427', 'OpenGate', '49427'), ('OG-49502', 'OpenGate', '49502')
on conflict (code) do nothing;

-- Where every item is right now (latest move per item).
create or replace function public.gear_status_json(p_item public.equipment)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', p_item.id, 'code', p_item.code, 'kind', p_item.kind, 'serial', p_item.serial, 'label', p_item.label,
    'state', coalesce(m.action, 'back'),
    'event_name', m.event_name, 'by_name', m.by_name, 'at', m.at,
    'condition', m.condition, 'note', m.note,
    -- damaged at any point since it last came back OK
    'flag_damaged', exists (select 1 from equipment_moves d where d.equipment_id = p_item.id and d.condition = 'damaged'
                             and d.at > coalesce((select max(o.at) from equipment_moves o where o.equipment_id = p_item.id
                                                  and o.action = 'back' and o.condition = 'ok'), '-infinity')))
  from (select 1) one
  left join lateral (select * from equipment_moves where equipment_id = p_item.id order by at desc limit 1) m on true;
$$;
revoke all on function public.gear_status_json(public.equipment) from public, anon, authenticated;

-- Who is signed in, for "Taken out by" / "Returned by".
create or replace function public.gear_my_name()
returns text language sql stable security definer set search_path = public as $$
  select coalesce(nullif(trim(p.full_name), ''), nullif(trim(u.raw_user_meta_data->>'full_name'), ''), split_part(u.email, '@', 1))
  from auth.users u left join profiles p on p.user_id = u.id where u.id = auth.uid();
$$;
revoke all on function public.gear_my_name() from public, anon, authenticated;

-- Save the signed-in person's own name (asked once, the first time they scan).
create or replace function public.web_set_my_name(p_name text)
returns text language plpgsql volatile security definer set search_path = public as $$
begin
  if not coalesce(is_staff(), false) then raise exception 'not_allowed' using errcode = '42501'; end if;
  p_name := regexp_replace(trim(coalesce(p_name, '')), '\s+', ' ', 'g');
  if char_length(p_name) < 2 or char_length(p_name) > 80 then raise exception 'bad_name'; end if;
  update profiles set full_name = p_name where user_id = auth.uid();
  return p_name;
end $$;

-- Everything the scan page needs for one sticker: the item, the rest of its kind, history,
-- and a suggested event (the last one this person used today, else a live IQ event).
create or replace function public.web_gear_item(p_code text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v equipment; v_event text;
begin
  if not coalesce(is_staff(), false) then raise exception 'not_allowed' using errcode = '42501'; end if;
  select * into v from equipment where code = upper(trim(p_code));
  if v.id is null then raise exception 'unknown_item'; end if;
  select event_name into v_event from equipment_moves
    where by_user = auth.uid() and at > now() - interval '18 hours' order by at desc limit 1;
  if v_event is null then
    select name into v_event from events where status = 'live' order by starts_at desc limit 1;
  end if;
  return jsonb_build_object(
    'item', gear_status_json(v),
    'my_name', gear_my_name(),
    'needs_name', not exists (select 1 from auth.users u left join profiles p on p.user_id = u.id where u.id = auth.uid()
                    and coalesce(nullif(trim(p.full_name), ''), nullif(trim(u.raw_user_meta_data->>'full_name'), '')) is not null),
    'suggested_event', v_event,
    'same_kind', (select coalesce(jsonb_agg(gear_status_json(e) order by e.serial), '[]') from equipment e
                   where e.kind = v.kind and e.active and e.id <> v.id),
    'history', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'action', m.action, 'condition', m.condition,
                  'note', m.note, 'has_photo', m.photo_b64 is not null, 'event_name', m.event_name,
                  'by_name', m.by_name, 'at', m.at) order by m.at desc), '[]')
                from (select * from equipment_moves where equipment_id = v.id order by at desc limit 50) m),
    'event_names', (select coalesce(jsonb_agg(n), '[]') from (
                  select n from (select event_name n, max(at) t from equipment_moves group by 1
                                 union all select name, coalesce(starts_at, created_at) from events where status in ('planned', 'live')) x
                  group by n order by max(t) desc limit 15) y));
end $$;

-- Sign out or return one or more items in one go. Returns the batch id (for the printable sheet).
-- p_items: [{"id": "...", "condition": "ok"|"damaged", "note": "...", "photo_b64": "..."}]
create or replace function public.web_gear_move(p_action text, p_event_name text, p_items jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_batch uuid := gen_random_uuid(); v_name text; v_event uuid; it jsonb; v_id uuid; v_n int := 0;
begin
  if not coalesce(is_staff(), false) then raise exception 'not_allowed' using errcode = '42501'; end if;
  if p_action not in ('out', 'back') then raise exception 'bad_action'; end if;
  p_event_name := nullif(trim(p_event_name), '');
  if p_event_name is null then raise exception 'need_event'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'no_items'; end if;
  v_name := gear_my_name();
  select id into v_event from events where name = p_event_name order by (status = 'live') desc, starts_at desc limit 1;
  for it in select * from jsonb_array_elements(p_items) loop
    v_id := (it->>'id')::uuid;
    if not exists (select 1 from equipment where id = v_id and active) then raise exception 'unknown_item'; end if;
    insert into equipment_moves (equipment_id, action, condition, note, photo_b64, event_id, event_name, by_user, by_name, batch_id)
    values (v_id, p_action, coalesce(nullif(it->>'condition', ''), 'ok'), nullif(trim(it->>'note'), ''),
            nullif(it->>'photo_b64', ''), v_event, p_event_name, auth.uid(), v_name, v_batch);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('batch_id', v_batch, 'count', v_n, 'by_name', v_name);
end $$;

-- All gear with where it is now, for the equipment page. Also the list of event names.
create or replace function public.web_gear_list()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(is_staff(), false) then raise exception 'not_allowed' using errcode = '42501'; end if;
  return jsonb_build_object(
    'items', (select coalesce(jsonb_agg(gear_status_json(e) order by e.kind, e.serial), '[]') from equipment e where e.active),
    'event_names', (select coalesce(jsonb_agg(n), '[]') from (
                  select event_name n from equipment_moves group by 1 order by max(at) desc limit 30) y));
end $$;

-- Full history for one item, or every move for one event (for the printable sheet).
create or replace function public.web_gear_history(p_code text default null, p_event_name text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(is_staff(), false) then raise exception 'not_allowed' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'code', e.code, 'kind', e.kind, 'serial', e.serial,
            'action', m.action, 'condition', m.condition, 'note', m.note, 'has_photo', m.photo_b64 is not null,
            'event_name', m.event_name, 'by_name', m.by_name, 'at', m.at, 'batch_id', m.batch_id) order by m.at), '[]')
          from equipment_moves m join equipment e on e.id = m.equipment_id
          where (p_code is null or e.code = upper(trim(p_code)))
            and (p_event_name is null or m.event_name = p_event_name)
            and (p_code is not null or p_event_name is not null));
end $$;

-- One damage photo.
create or replace function public.web_gear_photo(p_move_id uuid)
returns text language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(is_staff(), false) then raise exception 'not_allowed' using errcode = '42501'; end if;
  return (select photo_b64 from equipment_moves where id = p_move_id);
end $$;

revoke all on function public.web_gear_item(text), public.web_gear_move(text, text, jsonb), public.web_gear_list(),
  public.web_gear_history(text, text), public.web_gear_photo(uuid), public.web_set_my_name(text) from public, anon;
grant execute on function public.web_gear_item(text), public.web_gear_move(text, text, jsonb), public.web_gear_list(),
  public.web_gear_history(text, text), public.web_gear_photo(uuid), public.web_set_my_name(text) to authenticated;
