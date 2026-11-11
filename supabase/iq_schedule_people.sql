-- Schedule, part 3: "Who's where". One square per person per day for Joe, Paul and Kievon:
-- an event from the schedule, Office, Day off, Vacation, Sick, or something typed in.
-- Admin + Manager only (is_staff()), like the rest of the schedule.
-- Clearing a square keeps the row with no place (kind = null), so nothing is ever deleted.

create table if not exists public.schedule_people_days (
  person      text not null check (person in ('Joe', 'Paul', 'Kievon')),
  day         date not null,
  kind        text check (kind in ('event', 'office', 'off', 'vacation', 'sick', 'other')),
  event_id    uuid references public.schedule_events (id),
  note        text check (char_length(note) <= 200),
  updated_at  timestamptz not null default now(),
  updated_by  text,
  primary key (person, day),
  check (kind is distinct from 'event' or event_id is not null)
);

alter table public.schedule_people_days enable row level security;
revoke all on table public.schedule_people_days from anon, authenticated;

-- Every square set between two dates (at most about 3 months at a time).
create or replace function public.web_sched_who(p_from date, p_to date) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not coalesce(is_staff(), false) then raise exception 'not_allowed' using errcode = '42501'; end if;
  if p_to < p_from or p_to - p_from > 100 then raise exception 'bad_range'; end if;
  return (select coalesce(jsonb_agg(jsonb_build_object(
            'person', d.person, 'day', d.day, 'kind', d.kind, 'event_id', d.event_id, 'note', d.note,
            'updated_by', d.updated_by, 'updated_at', d.updated_at) order by d.day, d.person), '[]')
          from schedule_people_days d
          where d.day between p_from and p_to and d.kind is not null);
end $$;

-- Set one person's place for one day or a run of days (p_to null = just p_from).
-- p_kind null or '' clears the squares.
create or replace function public.web_sched_who_set(p_person text, p_from date, p_to date, p_kind text,
                                                    p_event_id uuid default null, p_note text default null)
returns int
language plpgsql security definer set search_path = public as $$
declare v_to date := coalesce(p_to, p_from); v_kind text := nullif(trim(p_kind), ''); v_n int;
begin
  if not coalesce(is_staff(), false) then raise exception 'not_allowed' using errcode = '42501'; end if;
  if p_person not in ('Joe', 'Paul', 'Kievon') then raise exception 'unknown_person'; end if;
  if p_from is null or v_to < p_from or v_to - p_from > 62 then raise exception 'bad_range'; end if;
  if v_kind = 'event' and not exists (select 1 from schedule_events where id = p_event_id and not archived) then
    raise exception 'unknown_event';
  end if;
  insert into schedule_people_days (person, day, kind, event_id, note, updated_at, updated_by)
  select p_person, g::date, v_kind, case when v_kind = 'event' then p_event_id end,
         case when v_kind is null then null else nullif(trim(p_note), '') end, now(), sched_my_name()
  from generate_series(p_from, v_to, interval '1 day') g
  on conflict (person, day) do update set
    kind = excluded.kind, event_id = excluded.event_id, note = excluded.note,
    updated_at = excluded.updated_at, updated_by = excluded.updated_by;
  get diagnostics v_n = row_count;
  return v_n;
end $$;

revoke execute on function public.web_sched_who(date, date), public.web_sched_who_set(text, date, date, text, uuid, text) from public, anon;
grant execute on function public.web_sched_who(date, date), public.web_sched_who_set(text, date, date, text, uuid, text) to authenticated;
