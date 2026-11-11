-- Applied 2026-11-11 as Supabase migration iq_gate_camera_events.
-- An IQ unit watching an OpenGate's lights (separate from people-count assignments, so its counts never mix in).
create table if not exists public.gate_cameras (
  id uuid primary key default gen_random_uuid(),
  device_id uuid not null references public.devices(id),
  checkpoint_id uuid not null references public.checkpoints(id),
  starts_at timestamptz not null default now(),
  ends_at timestamptz
);
-- One row per alarm / clear pass the camera saw. No images, ever.
create table if not exists public.gate_events (
  id bigint generated always as identity primary key,
  device_id uuid not null references public.devices(id),
  event_id uuid references public.events(id),
  checkpoint_id uuid references public.checkpoints(id),
  kind text not null check (kind in ('alarm', 'clear')),
  at timestamptz not null,
  meta jsonb,
  received_at timestamptz not null default now()
);
create index if not exists gate_events_event_at on public.gate_events (event_id, at);
alter table public.gate_cameras enable row level security;
alter table public.gate_events enable row level security;

-- Pi (device key) reports one alarm/clear; checkpoint/event come from its current gate_cameras row.
create or replace function public.ingest_gate_event(p_device_id uuid, p_device_key text, p_kind text, p_at timestamptz, p_meta jsonb default null)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare v_ok boolean; v_cp uuid; v_ev uuid; v_at timestamptz;
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
  values (p_device_id, v_ev, v_cp, p_kind, v_at, p_meta);
  return jsonb_build_object('ok', true, 'event_id', v_ev, 'checkpoint_id', v_cp);
end $$;

-- Gate screen: camera-seen alarms/clears for an event after p_after_id. Staff only.
create or replace function public.web_gate_events(p_event_id uuid, p_after_id bigint default 0)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(is_staff(), false) then return null; end if;
  return jsonb_build_object(
    'events', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'kind', x.kind, 'at', x.at, 'checkpoint', x.cp) order by x.id)
      from (select g.id, g.kind, g.at, c.name cp from gate_events g left join checkpoints c on c.id = g.checkpoint_id
             where g.event_id = p_event_id and g.id > coalesce(p_after_id, 0) order by g.id desc limit 200) x), '[]'::jsonb),
    'today', (select jsonb_build_object(
        'alarms', count(*) filter (where kind = 'alarm'),
        'clears', count(*) filter (where kind = 'clear'),
        'alarms_15m', count(*) filter (where kind = 'alarm' and at > now() - interval '15 minutes'),
        'last_alarm', max(at) filter (where kind = 'alarm'),
        'max_id', max(id))
      from gate_events where event_id = p_event_id),
    'cameras', coalesce((select jsonb_agg(jsonb_build_object('device', d.label, 'checkpoint', c.name, 'last_seen', d.last_seen_at))
      from gate_cameras g join checkpoints c on c.id = g.checkpoint_id join devices d on d.id = g.device_id
      where c.event_id = p_event_id and g.starts_at <= now() and (g.ends_at is null or g.ends_at > now())), '[]'::jsonb));
end $$;

revoke execute on function public.ingest_gate_event(uuid, text, text, timestamptz, jsonb), public.web_gate_events(uuid, bigint) from public;
grant execute on function public.ingest_gate_event(uuid, text, text, timestamptz, jsonb) to anon, authenticated;
grant execute on function public.web_gate_events(uuid, bigint) to authenticated;
