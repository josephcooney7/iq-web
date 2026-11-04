-- Equipment sign-out, part 6: record that the person read the SOP when signing out.
-- Additive: one new column on equipment_batches; two functions replaced to save and return it.

alter table public.equipment_batches add column if not exists sop_read text;

create or replace function public.gear_batch_json(p_batch uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('location', b.location, 'batteries', b.batteries, 'date_out', b.date_out,
                            'date_back', b.date_back, 'extras', b.extras, 'sop_read', b.sop_read)
  from equipment_batches b where b.id = p_batch;
$$;

create or replace function public.web_gear_save(p jsonb)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_batch uuid := gen_random_uuid(); v_name text; v_event uuid; it jsonb; v_id uuid; v_n int := 0;
  v_action text := p->>'action'; v_ev text := nullif(trim(p->>'event_name'), '');
  v_out date; v_back date; v_bat int; v_extras jsonb; v_sop text := left(nullif(trim(p->>'sop_read'), ''), 60);
begin
  if not coalesce(is_staff(), false) then raise exception 'not_allowed' using errcode = '42501'; end if;
  if v_action is null or v_action not in ('out', 'back') then raise exception 'bad_action'; end if;
  if v_ev is null then raise exception 'need_event'; end if;
  if jsonb_typeof(p->'items') is distinct from 'array' or jsonb_array_length(p->'items') = 0 then raise exception 'no_items'; end if;
  v_out := nullif(p->>'date_out', '')::date;
  v_back := nullif(p->>'date_back', '')::date;
  if v_out is not null and abs(v_out - current_date) > 400 then raise exception 'bad_date'; end if;
  if v_back is not null and abs(v_back - current_date) > 400 then raise exception 'bad_date'; end if;
  if v_out is not null and v_back is not null and v_back < v_out then raise exception 'back_before_out'; end if;
  v_bat := nullif(p->>'batteries', '')::int;
  -- extras: [{"name": "Table", "qty": 2}, ...] (a plain "Table" still counts as 1). Qty 0 is dropped.
  v_extras := coalesce((select jsonb_agg(jsonb_build_object('name', n, 'qty', q) order by n) from (
                 select left(trim(case when jsonb_typeof(x) = 'string' then x #>> '{}' else x->>'name' end), 40) n,
                        least(greatest(coalesce(case when jsonb_typeof(x) = 'string' then 1
                                                     else nullif(x->>'qty', '')::int end, 1), 0), 99) q
                 from jsonb_array_elements(case when jsonb_typeof(p->'extras') = 'array' then p->'extras' else '[]'::jsonb end) x) e
               where coalesce(n, '') <> '' and q > 0), '[]'::jsonb);
  if jsonb_array_length(v_extras) > 20 then raise exception 'too_many_extras'; end if;
  v_name := gear_my_name();
  select id into v_event from events where name = v_ev order by (status = 'live') desc, starts_at desc limit 1;
  insert into equipment_batches (id, action, event_name, location, batteries, date_out, date_back, extras, sop_read, by_user, by_name)
  values (v_batch, v_action, v_ev, nullif(trim(p->>'location'), ''), v_bat, v_out, v_back, v_extras, v_sop, auth.uid(), v_name);
  for it in select * from jsonb_array_elements(p->'items') loop
    v_id := (it->>'id')::uuid;
    if not exists (select 1 from equipment where id = v_id and active) then raise exception 'unknown_item'; end if;
    insert into equipment_moves (equipment_id, action, condition, note, photo_b64, event_id, event_name, by_user, by_name, batch_id)
    values (v_id, v_action, coalesce(nullif(it->>'condition', ''), 'ok'), nullif(trim(it->>'note'), ''),
            nullif(it->>'photo_b64', ''), v_event, v_ev, auth.uid(), v_name, v_batch);
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('batch_id', v_batch, 'count', v_n, 'by_name', v_name);
end $$;
