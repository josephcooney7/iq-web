-- Functions the website calls with a signed-in user's login.
-- Staff (admin/manager/staff in public.profiles) can set up units and see every event.
-- Client users only see dashboards for their own client's events.
-- Signed-out visitors (anon) can call none of these.

create or replace function public.web_me()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'signed_in', auth.uid() is not null,
    'email', (select email from auth.users where id = auth.uid()),
    'role', (select role from profiles where user_id = auth.uid()),
    'staff', coalesce(is_staff(), false));
$$;

create or replace function public.web_units()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(is_staff(), false) then raise exception 'not_allowed' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(label order by label), '[]'::jsonb) from devices where active);
end $$;

create or replace function public.web_unit_lines(p_label text, p_action text, p_lines jsonb default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  if not coalesce(is_staff(), false) then raise exception 'not_allowed' using errcode = '42501'; end if;
  if p_action not in ('get', 'request_snapshot', 'reset_counts', 'save_all') then raise exception 'bad_action'; end if;
  return iq_unit_lines(p_label, p_action, p_lines);
end $$;

create or replace function public.web_dashboard(p_event_id uuid default null, p_minutes integer default 120)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_client uuid; v_event uuid := p_event_id; r jsonb;
begin
  if auth.uid() is null then raise exception 'not_allowed' using errcode = '42501'; end if;
  p_minutes := least(greatest(coalesce(p_minutes, 120), 15), 1440);
  if coalesce(is_staff(), false) then
    return iq_dashboard(v_event, p_minutes);
  end if;
  v_client := my_client_id();
  if v_client is null then raise exception 'not_allowed' using errcode = '42501'; end if;
  if v_event is not null and not exists (select 1 from events where id = v_event and client_id = v_client) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if v_event is null then
    select id into v_event from events where client_id = v_client
      order by (status = 'live') desc, starts_at desc nulls last limit 1;
    if v_event is null then raise exception 'no_event'; end if;
  end if;
  r := iq_dashboard(v_event, p_minutes);
  r := jsonb_set(r, '{events}', coalesce((
        select jsonb_agg(e) from jsonb_array_elements(coalesce(r->'events', '[]'::jsonb)) e
        where exists (select 1 from events x where x.id::text = e->>'id' and x.client_id = v_client)), '[]'::jsonb));
  return r;
end $$;

revoke all on function public.web_me(), public.web_units(), public.web_unit_lines(text, text, jsonb), public.web_dashboard(uuid, integer) from public, anon;
grant execute on function public.web_me(), public.web_units(), public.web_unit_lines(text, text, jsonb), public.web_dashboard(uuid, integer) to authenticated;
