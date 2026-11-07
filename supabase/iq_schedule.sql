-- Schedule: every Stapleton event (the "Special Events Security Tracker" sheet) in the app.
-- Admin + Manager only (is_staff()). Clients and Field Techs never see it.
-- Lead, staffing and threat level start blank until Joe, Paul or Kievon fill them in.
-- Removing an event only hides it (archived), nothing is ever thrown away.

create table if not exists public.schedule_events (
  id            uuid primary key default gen_random_uuid(),
  start_date    date not null,
  end_date      date not null,
  client        text not null check (char_length(client) between 1 and 200),
  contact       text check (char_length(contact) <= 500),
  services      text check (char_length(services) <= 200),
  times         text check (char_length(times) <= 1000),
  location      text check (char_length(location) <= 300),
  lead          text check (char_length(lead) <= 120),
  staffing      text check (staffing in ('Staffed', 'Unstaffed')),
  threat_level  text check (threat_level in ('Low', 'Medium', 'High')),
  notes         text check (char_length(notes) <= 2000),
  archived      boolean not null default false,
  created_by    uuid default auth.uid(),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  updated_by    text,
  check (end_date >= start_date)
);
create index if not exists schedule_events_dates on public.schedule_events (start_date) where not archived;

-- No direct table access: the pages only use the web_sched_* functions below.
alter table public.schedule_events enable row level security;
revoke all on table public.schedule_events from anon, authenticated;

-- Name shown as "last changed by".
create or replace function public.sched_my_name() returns text
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(trim(p.full_name), ''), nullif(trim(u.raw_user_meta_data->>'full_name'), ''), split_part(u.email, '@', 1))
  from auth.users u left join profiles p on p.user_id = u.id where u.id = auth.uid();
$$;

create or replace function public.sched_json(s schedule_events) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object('id', s.id, 'start_date', s.start_date, 'end_date', s.end_date, 'client', s.client,
    'contact', s.contact, 'services', s.services, 'times', s.times, 'location', s.location, 'lead', s.lead,
    'staffing', s.staffing, 'threat_level', s.threat_level, 'notes', s.notes,
    'updated_at', s.updated_at, 'updated_by', s.updated_by);
$$;

create or replace function public.sched_clean(t text) returns text
language sql immutable as $$ select nullif(trim(t), '') $$;

-- All events still on the schedule, oldest first.
create or replace function public.web_sched_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(is_staff(), false) then raise exception 'not_allowed' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(sched_json(s) order by s.start_date, s.client), '[]')
          from schedule_events s where not s.archived);
end $$;

-- Add (no id) or change (with id) one event. Returns the saved event.
create or replace function public.web_sched_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v schedule_events; v_id uuid := nullif(p->>'id', '')::uuid;
begin
  if not coalesce(is_staff(), false) then raise exception 'not_allowed' using errcode = '42501'; end if;
  if sched_clean(p->>'client') is null then raise exception 'client_needed'; end if;
  if sched_clean(p->>'start_date') is null then raise exception 'date_needed'; end if;
  if v_id is null then
    insert into schedule_events (start_date, end_date, client, contact, services, times, location, lead, staffing, threat_level, notes, updated_by)
    values ((p->>'start_date')::date, coalesce(sched_clean(p->>'end_date'), p->>'start_date')::date, trim(p->>'client'),
            sched_clean(p->>'contact'), sched_clean(p->>'services'), sched_clean(p->>'times'), sched_clean(p->>'location'),
            sched_clean(p->>'lead'), sched_clean(p->>'staffing'), sched_clean(p->>'threat_level'), sched_clean(p->>'notes'), sched_my_name())
    returning * into v;
  else
    update schedule_events set
      start_date = (p->>'start_date')::date,
      end_date = coalesce(sched_clean(p->>'end_date'), p->>'start_date')::date,
      client = trim(p->>'client'), contact = sched_clean(p->>'contact'), services = sched_clean(p->>'services'),
      times = sched_clean(p->>'times'), location = sched_clean(p->>'location'), lead = sched_clean(p->>'lead'),
      staffing = sched_clean(p->>'staffing'), threat_level = sched_clean(p->>'threat_level'), notes = sched_clean(p->>'notes'),
      updated_at = now(), updated_by = sched_my_name()
    where id = v_id and not archived returning * into v;
    if v.id is null then raise exception 'unknown_event'; end if;
  end if;
  return sched_json(v);
end $$;

-- Take an event off the schedule (kept, just hidden).
create or replace function public.web_sched_remove(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(is_staff(), false) then raise exception 'not_allowed' using errcode = '42501'; end if;
  update schedule_events set archived = true, updated_at = now(), updated_by = sched_my_name() where id = p_id;
end $$;

-- Import many rows at once (from a spreadsheet). Skips rows already on the schedule
-- (same start date and same client). Returns how many were added and skipped.
create or replace function public.web_sched_import(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r jsonb; n_add int := 0; n_skip int := 0;
begin
  if not coalesce(is_staff(), false) then raise exception 'not_allowed' using errcode = '42501'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 500 then raise exception 'bad_rows'; end if;
  for r in select * from jsonb_array_elements(p_rows) loop
    if sched_clean(r->>'client') is null or sched_clean(r->>'start_date') is null then n_skip := n_skip + 1; continue; end if;
    if exists (select 1 from schedule_events s where not s.archived and s.start_date = (r->>'start_date')::date
               and lower(trim(s.client)) = lower(trim(r->>'client'))) then n_skip := n_skip + 1; continue; end if;
    perform web_sched_save(r - 'id');
    n_add := n_add + 1;
  end loop;
  return jsonb_build_object('added', n_add, 'skipped', n_skip);
end $$;

revoke execute on function public.web_sched_list(), public.web_sched_save(jsonb), public.web_sched_remove(uuid),
  public.web_sched_import(jsonb), public.sched_my_name(), public.sched_json(schedule_events) from public, anon;
grant execute on function public.web_sched_list(), public.web_sched_save(jsonb), public.web_sched_remove(uuid),
  public.web_sched_import(jsonb) to authenticated;

-- Joe's Q4 2026 tracker (the two Nov 9 Hilton Midtown rows are one event).
insert into public.schedule_events (start_date, end_date, client, contact, services, times, location, updated_by)
select v.* from (values
  ('2026-10-04'::date, '2026-10-04'::date, 'New York Road Runners (NYRR)', 'Will Ceja (646-627-5311) / Jacob Zive (jzive@nyrr.org, 929-909-6893)', 'Canine Teams', '07:00 - 13:00 (7:00 AM - 1:00 PM)', 'Christopher Columbus Drive and Greene Street, Jersey City, NJ', 'Imported'),
  ('2026-10-08', '2026-10-16', 'Allied Universal / Microsoft', 'Cheri Doyle (v-cheridoyle@microsoft.com, 253-282-6401)', 'Physical Security Personnel', '24 Hours (07:00 - 07:00) & Event Days 14:00 - 22:00 (Oct 13 & 15)', 'New York, NY (Manhattan / Brooklyn)', 'Imported'),
  ('2026-10-11', '2026-10-11', 'New York Road Runners (NYRR)', 'Megan Cespedes (646-627-4898) / Jacob Zive (jzive@nyrr.org, 929-909-6893)', 'Canine Teams', '06:00 - 13:00 (6:00 AM - 1:00 PM)', 'Richmond Terrace and Wall Street, Staten Island, NY', 'Imported'),
  ('2026-10-13', '2026-10-13', 'Mike Zimet Protective Services', 'Mike Zimet (917-763-7051)', 'Security Screening Equipment', '07:00 AM setup (Doors open 08:00 AM)', 'The Times Center, 242 West 41st St, New York, NY', 'Imported'),
  ('2026-10-21', '2026-10-21', 'Mike Zimet Protective Services (Blue Square Alliance Gala)', 'Mike Zimet (917-763-7051)', 'Security Screening Equipment & Canine Teams', 'Mags show ready by 15:30 (16:30 - 22:30); K9 sweep at 16:30', 'Waldorf Astoria, Park Ave & 50th St, New York, NY', 'Imported'),
  ('2026-10-29', '2026-10-29', 'TIME (TIME100 Next Gala)', 'Dean Vaknin (deanvaknin@time.com)', 'Security Screening Equipment & Canine Teams', 'Operational by 12:00 PM (12:00 PM K9 sweep)', 'Pier 59, Chelsea Piers, New York, NY', 'Imported'),
  ('2026-11-09', '2026-11-09', 'T&M USA, LLC (AIPAC Event)', 'Peter Godshall (pgodshall@tmusallc.com, 347-907-4761) / Pete Quinn', 'Physical Security Personnel & Security Screening Equipment', '08:00 - 16:00 (Delivery 08:30, Go Live 10:00, Event 11:30 - 13:00). 2 OpenGates, 4 operators 08:00 - 16:00', 'Hilton Midtown, New York, NY', 'Imported'),
  ('2026-11-11', '2026-11-12', 'Javits Center (International Tax Conference E&Y 2026)', 'Martin Murphy (mmurphy@javitscenter.com, 212-216-2143)', 'Physical Security Personnel', 'Nov 11 (06:00 - 06:00 Atrium 24 hrs, 07:00 - 19:00 Level 4 Pre Function 12 hrs); Nov 12 (06:00 - 06:00 Atrium 24 hrs, 07:00 - 19:00 Level 4 Pre Function 12 hrs, 07:00 - 13:00 Level 5 Pre Function 6 hrs)', 'Javits Center, 655 W. 34th Street, New York, NY', 'Imported')
) as v(start_date, end_date, client, contact, services, times, location, updated_by)
where not exists (select 1 from public.schedule_events);
