-- Equipment sign-out, part 7: keep the IQ "Test Client" events (Bench test) out of the sign-out event list.
-- Also suggests today's planned event when nothing is live. Only replaces web_gear_item.

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
    select e.name into v_event from events e join clients c on c.id = e.client_id
      where c.name <> 'Test Client' and (e.status = 'live' or (e.status = 'planned' and e.starts_at < now() + interval '18 hours' and e.ends_at > now()))
      order by (e.status = 'live') desc, e.starts_at limit 1;
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
    'events', (select coalesce(jsonb_agg(jsonb_build_object('name', e.name, 'venue', e.venue) order by (e.status = 'live') desc, e.starts_at), '[]')
               from events e join clients c on c.id = e.client_id
               where e.status in ('planned', 'live') and c.name <> 'Test Client'),
    'event_names', (select coalesce(jsonb_agg(n), '[]') from (
                  select event_name n from equipment_moves group by 1 order by max(at) desc limit 15) y));
end $$;
