-- Wait-time estimates (back end only; not shown on the dashboard yet).
--
-- A unit can watch a "line zone": boxes drawn on the setup page over where people
-- stand in line. Every frame it counts the people inside those boxes, and once a
-- minute it sends the average and the most it saw (queue occupancy). The existing
-- counting line gives throughput (people through per minute) at the same checkpoint.
--
--     estimated wait (minutes) = people in line / people through per minute
--
-- One unit can do both, or a second unit can be set to "line only" (role = 'queue')
-- and assigned to the same checkpoint: it sends occupancy and no crossings.
-- Only numbers leave the unit: no pictures, no individuals.

alter table public.device_settings
  add column if not exists queue_zones jsonb not null default '[]'::jsonb,
  add column if not exists role text not null default 'counter';
do $$ begin
  alter table public.device_settings add constraint device_settings_role_check
    check (role in ('counter', 'queue'));
exception when duplicate_object then null; end $$;

-- One row per unit per minute while it has a line zone.
create table if not exists public.queue_samples (
  device_id      uuid not null references public.devices (id),
  minute         timestamptz not null,
  avg_in_line    numeric not null check (avg_in_line >= 0),
  max_in_line    int not null check (max_in_line >= 0),
  frames         int not null default 0,
  event_id       uuid references public.events (id) on delete cascade,
  checkpoint_id  uuid references public.checkpoints (id) on delete cascade,
  received_at    timestamptz not null default now(),
  primary key (device_id, minute)
);
create index if not exists queue_samples_checkpoint_minute on public.queue_samples (checkpoint_id, minute);
alter table public.queue_samples enable row level security;
-- no policies: only the security-definer functions below touch it.

-- Called by the Pi with its own key (like ingest). p_samples:
-- [{"minute": "2026-11-03T15:20:00Z", "avg": 6.4, "max": 9, "frames": 880}, ...]
create or replace function public.ingest_queue(p_device_id uuid, p_device_key text, p_samples jsonb)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_ok boolean; v_rows int;
begin
  select active and key_hash = encode(digest(p_device_key, 'sha256'), 'hex')
    into v_ok from devices where id = p_device_id;
  if v_ok is not true then
    raise exception 'unknown or inactive device' using errcode = '28000';
  end if;
  if jsonb_array_length(coalesce(p_samples, '[]')) > 2000 then
    raise exception 'too many rows in one upload';
  end if;
  insert into queue_samples (device_id, minute, avg_in_line, max_in_line, frames, event_id, checkpoint_id)
  select p_device_id, x.minute, x.avg_in_line, x.max_in_line, x.frames, cp.event_id, a.checkpoint_id
  from (
    select date_trunc('minute', (e->>'minute')::timestamptz) as minute,
           least(greatest(coalesce((e->>'avg')::numeric, 0), 0), 500) as avg_in_line,
           least(greatest(coalesce((e->>'max')::int, 0), 0), 500)     as max_in_line,
           greatest(coalesce((e->>'frames')::int, 0), 0)               as frames
    from jsonb_array_elements(coalesce(p_samples, '[]')) e
  ) x
  left join lateral (
    select checkpoint_id from device_assignments da
    where da.device_id = p_device_id and x.minute >= da.starts_at and x.minute < da.ends_at
    order by da.starts_at desc limit 1
  ) a on true
  left join checkpoints cp on cp.id = a.checkpoint_id
  on conflict (device_id, minute) do update
    set avg_in_line = excluded.avg_in_line, max_in_line = excluded.max_in_line,
        frames = excluded.frames, event_id = excluded.event_id,
        checkpoint_id = excluded.checkpoint_id, received_at = now();
  get diagnostics v_rows = row_count;
  update devices set last_seen_at = now() where id = p_device_id;
  return jsonb_build_object('saved', v_rows);
end $$;
revoke all on function public.ingest_queue(uuid, text, jsonb) from public;
grant execute on function public.ingest_queue(uuid, text, jsonb) to anon;

-- Per-minute wait estimate for every checkpoint of an event.
-- in_line   = sum over the checkpoint's units of their average people in line that minute
--             (draw line zones so two units don't cover the same people).
-- through   = people through per minute, averaged over the last p_window minutes
--             (in_count of all units at the checkpoint; a 'queue' unit sends none).
-- wait_min  = in_line / through; null when nobody is moving (shown as "stalled" later).
create or replace function public.iq_wait_times(p_event_id uuid, p_minutes int default 120, p_window int default 5)
returns table (checkpoint_id uuid, minute timestamptz, in_line numeric, max_in_line int,
               through_per_min numeric, wait_min numeric)
language sql stable security definer set search_path = public as $$
  with q as (
    select qs.checkpoint_id, qs.minute, sum(qs.avg_in_line) as in_line, sum(qs.max_in_line)::int as max_in_line
    from queue_samples qs
    where qs.event_id = p_event_id
      and qs.minute >= date_trunc('minute', now()) - make_interval(mins => least(greatest(p_minutes, 5), 1440))
    group by 1, 2
  ), t as (
    select q.checkpoint_id, q.minute, q.in_line, q.max_in_line,
      (select coalesce(sum(c.in_count), 0)::numeric / greatest(p_window, 1)
         from counts c
        where c.checkpoint_id = q.checkpoint_id
          and c.minute > q.minute - make_interval(mins => greatest(p_window, 1))
          and c.minute <= q.minute) as through_per_min
    from q
  )
  select checkpoint_id, minute, round(in_line, 1), max_in_line, round(through_per_min, 1),
         case when through_per_min > 0 then round(in_line / through_per_min, 1)
              when in_line < 0.5 then 0 end
  from t order by checkpoint_id, minute;
$$;
revoke all on function public.iq_wait_times(uuid, int, int) from public, anon, authenticated;

-- For the website later (staff only for now): latest estimate per checkpoint + recent series.
create or replace function public.web_wait_times(p_event_id uuid, p_minutes int default 120)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(is_staff(), false) then raise exception 'not_allowed' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('checkpoint_id', w.checkpoint_id, 'name', cp.name,
             'latest', (select to_jsonb(x) - 'checkpoint_id' from iq_wait_times(p_event_id, 10) x
                        where x.checkpoint_id = w.checkpoint_id order by x.minute desc limit 1),
             'series', w.series))
    from (select checkpoint_id, jsonb_agg(to_jsonb(x) - 'checkpoint_id' order by minute) as series
            from iq_wait_times(p_event_id, p_minutes) x group by checkpoint_id) w
    join checkpoints cp on cp.id = w.checkpoint_id), '[]'::jsonb);
end $$;
revoke all on function public.web_wait_times(uuid, int) from public, anon;
grant execute on function public.web_wait_times(uuid, int) to authenticated;

-- device_sync: also tell the Pi its line zones and role. (Older Pi software ignores these.)
create or replace function public.device_sync(p_device_id uuid, p_device_key text,
    p_snapshot_b64 text default null, p_applied_version int default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v_ok boolean; s device_settings; v_want boolean;
begin
  select active and key_hash = encode(digest(p_device_key, 'sha256'), 'hex')
    into v_ok from devices where id = p_device_id;
  if v_ok is not true then
    raise exception 'unknown or inactive device' using errcode = '28000';
  end if;
  if p_snapshot_b64 is not null then
    if length(p_snapshot_b64) > 800000 then raise exception 'snapshot too large'; end if;
    insert into device_snapshots (device_id, taken_at, jpeg_b64)
      values (p_device_id, now(), p_snapshot_b64)
      on conflict (device_id) do update set taken_at = now(), jpeg_b64 = excluded.jpeg_b64,
        requested_at = null;
  end if;
  insert into device_settings (device_id) values (p_device_id) on conflict do nothing;
  if p_applied_version is not null then
    update device_settings set applied_version = p_applied_version where device_id = p_device_id;
  end if;
  select * into s from device_settings where device_id = p_device_id;
  select requested_at is not null and requested_at > now() - interval '10 minutes'
    into v_want from device_snapshots where device_id = p_device_id;
  update devices set last_seen_at = now() where id = p_device_id;
  return jsonb_build_object('version', s.version, 'line_y', s.line_y,
    'in_direction', s.in_direction, 'lines', s.lines, 'zones', coalesce(s.zones, '[]'::jsonb),
    'queue_zones', coalesce(s.queue_zones, '[]'::jsonb), 'role', s.role,
    'snapshot_wanted', coalesce(v_want, false));
end $$;

-- Checks a list of up to 4 boxes [x1, y1, x2, y2] (0..1). Null is allowed (= unchanged).
create or replace function public.iq_check_boxes(p_boxes jsonb)
returns void language plpgsql immutable set search_path = public as $$
declare b jsonb;
begin
  if p_boxes is null then return; end if;
  if jsonb_typeof(p_boxes) <> 'array' or jsonb_array_length(p_boxes) > 4 then
    raise exception 'zones must be a list of up to 4 boxes';
  end if;
  for b in select * from jsonb_array_elements(p_boxes) loop
    if jsonb_typeof(b) <> 'array' or jsonb_array_length(b) <> 4
       or exists (select 1 from jsonb_array_elements_text(b) v where v::numeric not between 0 and 1) then
      raise exception 'bad zone: %', b;
    end if;
  end loop;
end $$;
revoke all on function public.iq_check_boxes(jsonb) from public, anon, authenticated;

-- iq_unit_lines: save_all also takes "queue_zones" (up to 4 boxes) and "role";
-- a 'queue' unit may have no counting lines. 'get' also returns people in line now.
create or replace function public.iq_unit_lines(p_label text, p_action text default 'get', p_lines jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d devices; s device_settings; sn device_snapshots; l jsonb; v_from timestamptz;
        v_in int; v_out int; v_lines jsonb; v_zones jsonb; v_qzones jsonb; v_role text; v_q queue_samples;
begin
  select * into d from devices where upper(label) = upper(p_label);
  if d.id is null then raise exception 'no unit called %', p_label; end if;
  insert into device_settings (device_id) values (d.id) on conflict do nothing;
  if p_action = 'request_snapshot' then
    insert into device_snapshots (device_id, requested_at) values (d.id, now())
      on conflict (device_id) do update set requested_at = now();
  elsif p_action = 'reset_counts' then
    update device_settings ds set count_from = now(),
      base_in  = coalesce((select in_count  from counts c where c.device_id = d.id and c.minute = date_trunc('minute', now())), 0),
      base_out = coalesce((select out_count from counts c where c.device_id = d.id and c.minute = date_trunc('minute', now())), 0)
    where ds.device_id = d.id;
  elsif p_action in ('save_lines', 'save_all') then
    -- save_lines: p_lines is the lines array.
    -- save_all: {"lines": [...], "zones": [...], "queue_zones": [...], "role": "counter"|"queue"}
    if p_action = 'save_all' then
      v_lines := coalesce(p_lines->'lines', '[]'::jsonb); v_zones := coalesce(p_lines->'zones', '[]'::jsonb);
      v_qzones := p_lines->'queue_zones'; v_role := p_lines->>'role';
    else
      v_lines := p_lines; v_zones := null;
    end if;
    if v_role is not null and v_role not in ('counter', 'queue') then raise exception 'bad role: %', v_role; end if;
    if jsonb_typeof(v_lines) <> 'array'
       or jsonb_array_length(v_lines) > 4
       or (jsonb_array_length(v_lines) < 1 and coalesce(v_role, 'counter') <> 'queue') then
      raise exception 'lines must be a list of 1 to 4 lines';
    end if;
    for l in select * from jsonb_array_elements(v_lines) loop
      if jsonb_array_length(l->'p') <> 4
         or exists (select 1 from jsonb_array_elements_text(l->'p') v where v::numeric not between 0 and 1)
         or (l->>'dir')::int not in (1, -1)
         or coalesce(l->>'count', '') not in ('both', 'in', 'out') then
        raise exception 'bad line: %', l;
      end if;
    end loop;
    perform iq_check_boxes(v_zones);
    perform iq_check_boxes(v_qzones);
    update device_settings set
      lines = case when jsonb_array_length(v_lines) > 0 then v_lines else lines end,
      zones = coalesce(v_zones, zones),
      queue_zones = coalesce(v_qzones, queue_zones),
      role = coalesce(v_role, role),
      version = version + 1, updated_at = now()
      where device_id = d.id;
  elsif p_action <> 'get' then
    raise exception 'unknown action %', p_action;
  end if;
  select * into s from device_settings where device_id = d.id;
  select * into sn from device_snapshots where device_id = d.id;
  select * into v_q from queue_samples where device_id = d.id and minute >= now() - interval '3 minutes'
    order by minute desc limit 1;
  if s.count_from is not null then
    v_from := date_trunc('minute', s.count_from);
    select greatest(coalesce(sum(in_count),0) - s.base_in, 0), greatest(coalesce(sum(out_count),0) - s.base_out, 0)
      into v_in, v_out from counts where device_id = d.id and minute >= v_from;
  else
    v_from := date_trunc('day', now());
    select coalesce(sum(in_count),0), coalesce(sum(out_count),0)
      into v_in, v_out from counts where device_id = d.id and minute >= v_from;
  end if;
  return jsonb_build_object(
    'label', d.label, 'last_seen_at', d.last_seen_at,
    'online', d.last_seen_at > now() - interval '2 minutes',
    'lines', coalesce(s.lines, jsonb_build_array(jsonb_build_object(
        'p', jsonb_build_array(0, s.line_y, 1, s.line_y),
        'dir', case when s.in_direction = 'down' then 1 else -1 end, 'count', 'both'))),
    'zones', coalesce(s.zones, '[]'::jsonb),
    'queue_zones', coalesce(s.queue_zones, '[]'::jsonb), 'role', s.role,
    'in_line_now', round(v_q.avg_in_line, 1), 'in_line_minute', v_q.minute,
    'version', s.version, 'applied_version', s.applied_version,
    'snapshot_requested_at', sn.requested_at, 'snapshot_taken_at', sn.taken_at,
    'snapshot', case when p_action = 'get' then sn.jpeg_b64 end,
    'count_from', s.count_from, 'today_in', v_in, 'today_out', v_out);
end $$;
