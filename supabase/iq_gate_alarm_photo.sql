-- Latest red-alarm photo per gate camera (one row per device, overwritten by each new alarm).
create table if not exists public.gate_alarm_photos (
  device_id uuid primary key references public.devices(id),
  gate_event_id bigint not null references public.gate_events(id),
  taken_at timestamptz not null default now(),
  jpeg_b64 text not null
);
alter table public.gate_alarm_photos enable row level security;

-- Now also returns the new row id so the Pi can attach the photo.
create or replace function public.ingest_gate_event(p_device_id uuid, p_device_key text, p_kind text, p_at timestamptz, p_meta jsonb default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_ok boolean; v_cp uuid; v_ev uuid; v_at timestamptz; v_id bigint;
begin
  select active and key_hash = encode(digest(p_device_key, 'sha256'), 'hex') into v_ok from devices where id = p_device_id;
  if v_ok is not true then raise exception 'unknown or inactive device' using errcode = '28000'; end if;
  if p_kind not in ('alarm', 'clear') then raise exception 'bad_kind'; end if;
  if p_meta is not null and length(p_meta::text) > 2000 then raise exception 'meta_too_large'; end if;
  v_at := least(greatest(coalesce(p_at, now()), now() - interval '1 day'), now() + interval '1 minute');
  select g.checkpoint_id, c.event_id into v_cp, v_ev
    from gate_cameras g join checkpoints c on c.id = g.checkpoint_id
   where g.device_id = p_device_id and g.starts_at <= v_at and (g.ends_at is null or g.ends_at > v_at)
   order by g.starts_at desc limit 1;
  insert into gate_events (device_id, event_id, checkpoint_id, kind, at, meta)
  values (p_device_id, v_ev, v_cp, p_kind, v_at, p_meta) returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id, 'event_id', v_ev, 'checkpoint_id', v_cp);
end $$;

-- Pi attaches the photo for one of its own red alarms. Replaces that camera's previous photo.
create or replace function public.attach_gate_photo(p_device_id uuid, p_device_key text, p_gate_event_id bigint, p_jpeg_b64 text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_ok boolean;
begin
  select active and key_hash = encode(digest(p_device_key, 'sha256'), 'hex') into v_ok from devices where id = p_device_id;
  if v_ok is not true then raise exception 'unknown or inactive device' using errcode = '28000'; end if;
  if not exists (select 1 from gate_events where id = p_gate_event_id and device_id = p_device_id and kind = 'alarm') then raise exception 'bad_gate_event'; end if;
  if p_jpeg_b64 is null or length(p_jpeg_b64) > 300000 then raise exception 'photo_too_large'; end if;
  insert into gate_alarm_photos (device_id, gate_event_id, taken_at, jpeg_b64)
  values (p_device_id, p_gate_event_id, now(), p_jpeg_b64)
  on conflict (device_id) do update set gate_event_id = excluded.gate_event_id, taken_at = excluded.taken_at, jpeg_b64 = excluded.jpeg_b64;
  return jsonb_build_object('ok', true);
end $$;

-- Gate screen: the photo for one alarm, staff only, only while it's the latest and under 10 minutes old.
create or replace function public.web_gate_photo(p_gate_event_id bigint)
returns text
language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(is_staff(), false) then return null; end if;
  return (select jpeg_b64 from gate_alarm_photos where gate_event_id = p_gate_event_id and taken_at > now() - interval '10 minutes');
end $$;

revoke execute on function public.attach_gate_photo(uuid, text, bigint, text), public.web_gate_photo(bigint) from public;
grant execute on function public.attach_gate_photo(uuid, text, bigint, text) to anon, authenticated;
grant execute on function public.web_gate_photo(bigint) to authenticated;
