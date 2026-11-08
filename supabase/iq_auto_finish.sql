-- Events finish by themselves: once an event's end time passes it becomes 'finished'
-- (off the dashboard, still under All events for its report). A planned event becomes 'live' at its start time.
-- No scheduler needed: the website calls this whenever someone signed in opens a page.
create or replace function public.web_close_ended_events() returns void
language sql volatile security definer set search_path = public as $$
  update events set status = 'finished' where status in ('live', 'planned') and ends_at <= now();
  update events set status = 'live' where status = 'planned' and starts_at <= now() and ends_at > now();
$$;
revoke execute on function public.web_close_ended_events() from public, anon;
grant execute on function public.web_close_ended_events() to authenticated;
