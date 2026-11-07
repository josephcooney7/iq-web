-- Schedule, part 2: threat level is a number 1-10 (new column "threat"; the old Low/Medium/High column is left unused).
-- Lead is picked from Joe / Kievon / Paul on the page; the database keeps it as text.
alter table public.schedule_events add column if not exists threat smallint check (threat between 1 and 10);

create or replace function public.sched_json(s schedule_events) returns jsonb
language sql stable set search_path = public as $$
  select jsonb_build_object('id', s.id, 'start_date', s.start_date, 'end_date', s.end_date, 'client', s.client,
    'contact', s.contact, 'services', s.services, 'times', s.times, 'location', s.location, 'lead', s.lead,
    'staffing', s.staffing, 'threat_level', s.threat, 'notes', s.notes,
    'updated_at', s.updated_at, 'updated_by', s.updated_by);
$$;

create or replace function public.web_sched_save(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v schedule_events; v_id uuid := nullif(p->>'id', '')::uuid;
        v_threat smallint := nullif(trim(p->>'threat_level'), '')::smallint;
begin
  if not coalesce(is_staff(), false) then raise exception 'not_allowed' using errcode = '42501'; end if;
  if sched_clean(p->>'client') is null then raise exception 'client_needed'; end if;
  if sched_clean(p->>'start_date') is null then raise exception 'date_needed'; end if;
  if v_id is null then
    insert into schedule_events (start_date, end_date, client, contact, services, times, location, lead, staffing, threat, notes, updated_by)
    values ((p->>'start_date')::date, coalesce(sched_clean(p->>'end_date'), p->>'start_date')::date, trim(p->>'client'),
            sched_clean(p->>'contact'), sched_clean(p->>'services'), sched_clean(p->>'times'), sched_clean(p->>'location'),
            sched_clean(p->>'lead'), sched_clean(p->>'staffing'), v_threat, sched_clean(p->>'notes'), sched_my_name())
    returning * into v;
  else
    update schedule_events set
      start_date = (p->>'start_date')::date,
      end_date = coalesce(sched_clean(p->>'end_date'), p->>'start_date')::date,
      client = trim(p->>'client'), contact = sched_clean(p->>'contact'), services = sched_clean(p->>'services'),
      times = sched_clean(p->>'times'), location = sched_clean(p->>'location'), lead = sched_clean(p->>'lead'),
      staffing = sched_clean(p->>'staffing'), threat = v_threat, notes = sched_clean(p->>'notes'),
      updated_at = now(), updated_by = sched_my_name()
    where id = v_id and not archived returning * into v;
    if v.id is null then raise exception 'unknown_event'; end if;
  end if;
  return sched_json(v);
end $$;
