-- IQ Units page: every unit with online status and the event / checkpoint it's assigned to right now.
create or replace function public.web_units_status() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(is_staff(), false) then raise exception 'not_allowed' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
      'label', d.label,
      'last_seen_at', d.last_seen_at,
      'online', d.last_seen_at > now() - interval '2 minutes',
      'event', a.event_name,
      'checkpoint', a.checkpoint_name) order by d.label), '[]'::jsonb)
    from devices d
    left join lateral (
      select e.name as event_name, c.name as checkpoint_name
      from device_assignments da
      join checkpoints c on c.id = da.checkpoint_id
      join events e on e.id = c.event_id
      where da.device_id = d.id and da.starts_at <= now() and (da.ends_at is null or da.ends_at > now())
      order by da.starts_at desc limit 1) a on true
    where d.active);
end $$;
revoke execute on function public.web_units_status() from public, anon;
grant execute on function public.web_units_status() to authenticated;
