-- OpenGate (CEIA) metal detector readings, brought in from a NetID Anywhere report export (CSV).
-- Staff upload the report for one checkpoint of an event; each time row becomes vendor_readings
-- rows (vendor 'ceia', metrics transits_in / transits_out / alarms_in / alarms_out).
-- Internal only: clients never see these (no client policy on vendor_readings, and the read
-- function below is staff-only).

-- Uploading the same report twice replaces the numbers instead of doubling them.
create unique index if not exists vendor_readings_gate_uniq
  on public.vendor_readings (event_id, checkpoint_id, vendor, metric, recorded_at);

-- p_rows: [{"t": "2026-11-11T14:00:00Z", "transits_in": 10, "transits_out": 0, "alarms_in": 2, "alarms_out": 0}, ...]
-- p_source: small description of the file (name, interval), kept in raw for reference.
create or replace function public.web_gate_import(p_event_id uuid, p_checkpoint_id uuid, p_rows jsonb, p_source jsonb default null)
returns integer
language plpgsql security definer set search_path = public as $$
declare r jsonb; m text; n integer := 0; v numeric; t timestamptz;
begin
  if not coalesce(is_staff(), false) then raise exception 'not_allowed' using errcode = '42501'; end if;
  if not exists (select 1 from checkpoints c where c.id = p_checkpoint_id and c.event_id = p_event_id) then
    raise exception 'bad_checkpoint';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 or jsonb_array_length(p_rows) > 5000 then
    raise exception 'bad_rows';
  end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    t := (r->>'t')::timestamptz;
    foreach m in array array['transits_in', 'transits_out', 'alarms_in', 'alarms_out'] loop
      v := nullif(r->>m, '')::numeric;
      if v is null then continue; end if;
      if v < 0 or v > 1000000 then raise exception 'bad_value'; end if;
      insert into vendor_readings (event_id, checkpoint_id, vendor, metric, value, recorded_at, raw)
      values (p_event_id, p_checkpoint_id, 'ceia', m, v, t, p_source)
      on conflict (event_id, checkpoint_id, vendor, metric, recorded_at)
      do update set value = excluded.value, raw = excluded.raw;
      n := n + 1;
    end loop;
  end loop;
  return n;
end $$;

-- Gate numbers for an event: totals per checkpoint plus a time series. Staff only.
create or replace function public.web_gate_readings(p_event_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(is_staff(), false) then return null; end if;
  return jsonb_build_object(
    'checkpoints', coalesce((
      select jsonb_agg(x order by x->>'name') from (
        select jsonb_build_object(
          'checkpoint_id', c.id, 'name', c.name,
          'transits', sum(v.value) filter (where v.metric = 'transits_in'),
          'transits_out', sum(v.value) filter (where v.metric = 'transits_out'),
          'alarms', sum(v.value) filter (where v.metric = 'alarms_in'),
          'alarms_out', sum(v.value) filter (where v.metric = 'alarms_out'),
          'first', min(v.recorded_at), 'last', max(v.recorded_at),
          'uploaded', max(v.raw->>'uploaded_at')) as x
        from vendor_readings v join checkpoints c on c.id = v.checkpoint_id
        where v.event_id = p_event_id and v.vendor = 'ceia'
        group by c.id, c.name) s), '[]'::jsonb),
    'series', coalesce((
      select jsonb_agg(jsonb_build_object('t', recorded_at, 'transits', tr, 'alarms', al) order by recorded_at) from (
        select recorded_at,
               sum(value) filter (where metric = 'transits_in') tr,
               sum(value) filter (where metric = 'alarms_in') al
        from vendor_readings
        where event_id = p_event_id and vendor = 'ceia'
        group by recorded_at) s), '[]'::jsonb));
end $$;

revoke execute on function public.web_gate_import(uuid, uuid, jsonb, jsonb), public.web_gate_readings(uuid) from public, anon;
grant execute on function public.web_gate_import(uuid, uuid, jsonb, jsonb), public.web_gate_readings(uuid) to authenticated;
