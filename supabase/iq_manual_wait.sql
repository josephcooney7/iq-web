-- Security wait typed in by staff (for events with no line camera), e.g. "Free flow" or "5 min".
-- Shown in Client view and the event summary report.
alter table public.events add column if not exists manual_wait text check (char_length(manual_wait) <= 40);

-- Read it: staff, or a client login for its own approved event.
create or replace function public.web_event_manual_wait(p_event_id uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare v text;
begin
  select e.manual_wait into v from events e
   where e.id = p_event_id
     and (coalesce(is_staff(), false)
          or (e.client_view_approved and e.client_id = (select p.client_id from profiles p where p.user_id = auth.uid() and p.role = 'client')));
  return v;
end $$;

-- Set or clear it (empty = clear): Admin + Manager only.
create or replace function public.web_set_manual_wait(p_event_id uuid, p_text text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not coalesce(is_staff(), false) then raise exception 'not_allowed' using errcode = '42501'; end if;
  update events set manual_wait = nullif(trim(p_text), '') where id = p_event_id;
end $$;

revoke execute on function public.web_event_manual_wait(uuid), public.web_set_manual_wait(uuid, text) from public, anon;
grant execute on function public.web_event_manual_wait(uuid), public.web_set_manual_wait(uuid, text) to authenticated;

update public.events set manual_wait = 'Free flow' where id = '48bac218-a161-437c-a4a3-7f0d6294f1fe';
