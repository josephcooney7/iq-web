-- Gate (OpenGate) numbers on the client report: off per event until staff tick the box.
alter table public.events add column if not exists show_gate boolean not null default false;

-- Tick/untick "Show gate numbers on the client report": Admin + Manager only.
create or replace function public.web_set_show_gate(p_event_id uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(is_staff(), false) then raise exception 'not_allowed' using errcode = '42501'; end if;
  update events set show_gate = coalesce(p_on, false) where id = p_event_id;
end $$;

-- Staff always get the gate numbers (plus the show_gate flag). A client login gets them only for
-- its own approved event, and only when show_gate is on.
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

revoke execute on function public.web_set_show_gate(uuid, boolean), public.web_gate_readings(uuid) from public, anon;
grant execute on function public.web_set_show_gate(uuid, boolean), public.web_gate_readings(uuid) to authenticated;
