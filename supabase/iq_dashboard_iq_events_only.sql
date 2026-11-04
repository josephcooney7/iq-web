-- IQ dashboard: only list events that have an IQ unit assigned to one of their checkpoints.
-- Equipment-only jobs (e.g. gate sign-outs) stay off the dashboard. Only replaces iq_dashboard.

create or replace function public.iq_dashboard(p_event_id uuid default null, p_minutes integer default 120)
returns jsonb language plpgsql stable security definer set search_path = public as $function$
declare v_event uuid := p_event_id; v_now timestamptz := now(); v_out jsonb;
begin
  p_minutes := least(greatest(coalesce(p_minutes, 120), 15), 720);
  if v_event is null then
    select e.id into v_event from events e
    where e.status = 'live'
      and exists (select 1 from checkpoints cp join device_assignments da on da.checkpoint_id = cp.id where cp.event_id = e.id)
    order by (select max(c.received_at) from counts c where c.event_id = e.id) desc nulls last,
             e.starts_at desc
    limit 1;
  end if;

  select jsonb_build_object(
    'now', v_now,
    'events', (select coalesce(jsonb_agg(jsonb_build_object(
                  'id', e.id, 'name', e.name, 'status', e.status, 'client', cl.name)
                  order by e.starts_at desc), '[]')
               from events e join clients cl on cl.id = e.client_id
               where e.status in ('live', 'planned')
                 and exists (select 1 from checkpoints cp join device_assignments da on da.checkpoint_id = cp.id where cp.event_id = e.id)),
    'event', (select jsonb_build_object('id', e.id, 'name', e.name, 'venue', e.venue,
                  'status', e.status, 'starts_at', e.starts_at, 'ends_at', e.ends_at, 'client', cl.name)
              from events e join clients cl on cl.id = e.client_id where e.id = v_event),
    'window_minutes', p_minutes,
    'checkpoints', (select coalesce(jsonb_agg(to_jsonb(x) order by x.sort_order), '[]') from (
        select cp.id, cp.name, cp.kind, cp.sort_order,
          (select string_agg(d.label, ', ' order by d.label) from device_assignments da join devices d on d.id = da.device_id
             where da.checkpoint_id = cp.id and v_now >= da.starts_at and v_now < da.ends_at) as units,
          coalesce((select sum(in_count) from counts where checkpoint_id = cp.id), 0) as total_in,
          coalesce((select sum(out_count) from counts where checkpoint_id = cp.id), 0) as total_out,
          coalesce((select sum(in_count) from counts where checkpoint_id = cp.id and minute >= v_now - interval '60 minutes'), 0) as last60_in,
          coalesce((select sum(in_count) from counts where checkpoint_id = cp.id and minute >= v_now - interval '15 minutes'), 0) as last15_in,
          (select max(minute) from counts where checkpoint_id = cp.id) as last_minute,
          -- "last heard from": newest of the last count upload and the assigned units' check-ins
          -- (units check in every ~15 s even when nobody walks past)
          greatest((select max(received_at) from counts where checkpoint_id = cp.id),
                   (select max(d.last_seen_at) from device_assignments da join devices d on d.id = da.device_id
                     where da.checkpoint_id = cp.id and v_now >= da.starts_at and v_now < da.ends_at)) as last_received,
          (select jsonb_agg(coalesce(c.in_count, 0) order by g.m)
             from generate_series(date_trunc('minute', v_now) - make_interval(mins => p_minutes),
                                  date_trunc('minute', v_now) - interval '1 minute', interval '1 minute') g(m)
             left join (select minute, sum(in_count) in_count from counts where checkpoint_id = cp.id
                        and minute >= v_now - make_interval(mins => p_minutes + 1) group by minute) c on c.minute = g.m) as series
        from checkpoints cp where cp.event_id = v_event) x)
  ) into v_out;
  return v_out;
end $function$;
