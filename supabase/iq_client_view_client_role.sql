-- Client logins open Client view (Joe, 2026-11-04). A client sees only its own company's events that
-- Joe approved, and only the updates marked "Show to client" (no staff names or photos).
-- Staff (admin, manager) see the same as before. Incident tools stay staff-only.

create or replace function public.web_client_view(p_event_id uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_event uuid := p_event_id; v_from timestamptz; v_to timestamptz; v_now timestamptz := now();
  v_admin boolean := exists (select 1 from profiles where user_id = auth.uid() and role = 'admin');
  v_staff boolean := coalesce(is_staff(), false);
  -- A client login sees only its own company's approved events, and only shared updates.
  v_client uuid := case when not coalesce(is_staff(), false) and exists (select 1 from profiles where user_id = auth.uid() and role = 'client') then my_client_id() end;
begin
  if not v_staff and v_client is null then raise exception 'not_allowed' using errcode = '42501'; end if;
  if v_event is not null and not exists (select 1 from events where id = v_event and client_view_approved and (v_staff or client_id = v_client)) then
    v_event := null;  -- not approved (or gone): fall back to the default approved event
  end if;
  if v_event is null then
    select e.id into v_event from events e where e.client_view_approved and (v_staff or e.client_id = v_client)
     order by (e.status = 'live') desc, (select max(c.received_at) from counts c where c.event_id = e.id) desc nulls last, e.starts_at desc
     limit 1;
  end if;
  if v_event is null then
    return jsonb_build_object('now', v_now, 'event', null, 'events', '[]'::jsonb, 'checkpoints', '[]'::jsonb,
      'buckets', '[]'::jsonb, 'wait_buckets', '[]'::jsonb, 'updates', '[]'::jsonb, 'categories', '[]'::jsonb,
      'can_approve', v_admin, 'pending', case when v_admin then (select coalesce(jsonb_agg(jsonb_build_object(
        'id', e.id, 'name', e.name, 'status', e.status, 'starts_at', e.starts_at, 'client', cl.name) order by e.starts_at desc), '[]')
        from events e join clients cl on cl.id = e.client_id where not e.client_view_approved and e.status <> 'cancelled') else '[]'::jsonb end);
  end if;

  -- The span the charts cover: from the first count to the last (at most the last 24 hours of it).
  select max(minute) into v_to from counts where event_id = v_event;
  v_to := coalesce(v_to, least(v_now, (select ends_at from events where id = v_event)));
  select greatest(min(minute), v_to - interval '24 hours') into v_from from counts where event_id = v_event;
  v_from := coalesce(v_from, v_to - interval '2 hours');

  return jsonb_build_object(
    'now', v_now,
    'event', (select jsonb_build_object('id', e.id, 'name', e.name, 'venue', e.venue, 'status', e.status,
                'starts_at', e.starts_at, 'ends_at', e.ends_at, 'client', cl.name,
                'last_received', (select max(received_at) from counts where event_id = e.id))
              from events e join clients cl on cl.id = e.client_id where e.id = v_event),
    'events', (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'name', e.name, 'status', e.status,
                  'starts_at', e.starts_at, 'client', cl.name,
                  'total_in', coalesce((select sum(in_count) from counts where event_id = e.id), 0))
                  order by (e.status = 'live') desc, e.starts_at desc), '[]')
               from events e join clients cl on cl.id = e.client_id where e.status <> 'cancelled' and e.client_view_approved and (v_staff or e.client_id = v_client)),
    -- events waiting for Joe's OK (admins only)
    'can_approve', v_admin,
    'pending', case when v_admin then (select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'name', e.name,
                  'status', e.status, 'starts_at', e.starts_at, 'client', cl.name) order by e.starts_at desc), '[]')
               from events e join clients cl on cl.id = e.client_id
               where not e.client_view_approved and e.status <> 'cancelled') else '[]'::jsonb end,
    'checkpoints', (select coalesce(jsonb_agg(jsonb_build_object('id', cp.id, 'name', cp.name, 'kind', cp.kind,
                  'total_in', coalesce((select sum(in_count) from counts where checkpoint_id = cp.id), 0),
                  'last15_in', coalesce((select sum(in_count) from counts where checkpoint_id = cp.id and minute > v_to - interval '15 minutes'), 0),
                  'wait_now', (select w.wait_min from iq_wait_times(v_event, 15) w where w.checkpoint_id = cp.id order by w.minute desc limit 1),
                  'has_unit', exists (select 1 from device_assignments da where da.checkpoint_id = cp.id))
                  order by cp.sort_order, cp.name), '[]')
               from checkpoints cp where cp.event_id = v_event),
    -- people through screening per 15 minutes
    'buckets', (select coalesce(jsonb_agg(jsonb_build_object('t', b.t, 'n', b.n) order by b.t), '[]') from (
                  select g.t, coalesce(sum(c.in_count), 0) n
                  from generate_series(date_bin('15 minutes', v_from, 'epoch'), v_to, interval '15 minutes') g(t)
                  left join counts c on c.event_id = v_event and c.minute >= g.t and c.minute < g.t + interval '15 minutes'
                  group by g.t) b),
    -- average estimated wait (minutes) per 15 minutes, across checkpoints with a line camera
    'wait_buckets', (select coalesce(jsonb_agg(jsonb_build_object('t', w.t, 'wait', w.wait) order by w.t), '[]') from (
                  select date_bin('15 minutes', x.minute, 'epoch') t, round(avg(x.wait_min), 1) wait
                  from iq_wait_times(v_event, greatest(15, ceil(extract(epoch from v_now - v_from) / 60)::int)) x
                  where x.wait_min is not null and x.minute >= v_from
                  group by 1) w),
    'updates', (select coalesce(jsonb_agg(jsonb_build_object('id', u.id, 'at', u.occurred_at, 'category', u.category,
                  'category_label', ic.label, 'note', u.note, 'checkpoint', cp.name, 'location', u.location,
                  'severity', u.severity, 'action_taken', u.action_taken, 'police_notified', u.police_notified,
                  'has_photo', v_staff and u.photo_b64 is not null, 'by_name', case when v_staff then u.by_name end, 'visible_to_client', u.visible_to_client)
                  order by u.occurred_at desc), '[]')
                from staff_updates u left join incident_categories ic on ic.code = u.category
                left join checkpoints cp on cp.id = u.checkpoint_id where u.event_id = v_event and (v_staff or u.visible_to_client)),
    'categories', case when v_staff then (select coalesce(jsonb_agg(jsonb_build_object('code', code, 'label', label) order by sort_order), '[]')
                   from incident_categories) else '[]'::jsonb end);
end $$;

