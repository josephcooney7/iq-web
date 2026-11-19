-- Evolv and X-ray numbers on the client report, next to OpenGate.
-- vendor_readings rows: vendor 'ceia' (OpenGate) or 'evolv' use metrics transits_in / alarms_in (people);
-- vendor 'xray' uses metric 'bags' (bags/items screened). Hand-entered or imported per hour.
create or replace function public.web_gate_readings(p_event_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_show boolean; v_ok boolean;
begin
  select e.show_gate,
         coalesce(is_staff(), false)
         or (e.show_gate and e.client_view_approved
             and e.client_id = (select p.client_id from profiles p where p.user_id = auth.uid() and p.role = 'client'))
    into v_show, v_ok
    from events e where e.id = p_event_id;
  if not coalesce(v_ok, false) then return null; end if;
  return jsonb_build_object(
    'show_gate', v_show,
    'checkpoints', coalesce((
      select jsonb_agg(x order by x->>'name') from (
        select jsonb_build_object(
          'checkpoint_id', c.id, 'name', c.name,
          'vendor', min(v.vendor),
          'transits', sum(v.value) filter (where v.metric = 'transits_in'),
          'transits_out', sum(v.value) filter (where v.metric = 'transits_out'),
          'alarms', sum(v.value) filter (where v.metric = 'alarms_in'),
          'alarms_out', sum(v.value) filter (where v.metric = 'alarms_out'),
          'bags', sum(v.value) filter (where v.metric = 'bags'),
          'first', min(v.recorded_at), 'last', max(v.recorded_at),
          'uploaded', max(v.raw->>'uploaded_at')) as x
        from vendor_readings v join checkpoints c on c.id = v.checkpoint_id
        where v.event_id = p_event_id and v.vendor in ('ceia', 'evolv', 'xray')
        group by c.id, c.name) s), '[]'::jsonb),
    'series', coalesce((
      select jsonb_agg(jsonb_build_object('t', recorded_at, 'transits', tr, 'alarms', al, 'bags', bg) order by recorded_at) from (
        select recorded_at,
               sum(value) filter (where metric = 'transits_in') tr,
               sum(value) filter (where metric = 'alarms_in') al,
               sum(value) filter (where metric = 'bags') bg
        from vendor_readings
        where event_id = p_event_id and vendor in ('ceia', 'evolv', 'xray')
        group by recorded_at) s), '[]'::jsonb));
end $$;

revoke execute on function public.web_gate_readings(uuid) from public, anon;
grant execute on function public.web_gate_readings(uuid) to authenticated;
