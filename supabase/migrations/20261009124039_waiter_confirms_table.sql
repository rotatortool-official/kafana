-- A guest's order is unconfirmed until a waiter accepts it at the table.
-- Accepting can MOVE it to the table where the guest really sits, and an
-- unconfirmed order can be REJECTED with a reason. Both are new events;
-- nothing is edited. Once accepted, an order is final as before.

alter table public.events drop constraint events_type_check;
alter table public.events add constraint events_type_check
  check (type in ('round','status','bill_request','close','reset','move','reject'));

create index events_round_ref on public.events (((data->>'round')::bigint)) where type in ('status','move','reject');
create index events_bill_ref  on public.events (((data->>'bill')::bigint))  where type in ('round','close','bill_request');

-- Where every order stands right now: its bill and table after any move,
-- its latest status, and whether it was rejected.
-- (Replaced in 20261009124107: the "by" column is renamed "source".)
create function public.rounds_now()
returns table (seq bigint, bill bigint, tbl int, total numeric, by text, status text, rejected boolean)
language sql stable set search_path = '' as $$
  select r.seq,
         coalesce(m.to_bill, (r.data->>'bill')::bigint),
         coalesce(m.to_table, (r.data->>'table')::int),
         (r.data->>'total')::numeric,
         r.data->>'by',
         coalesce(s.status, 'new'),
         exists (select 1 from public.events x
                 where x.type = 'reject' and (x.data->>'round')::bigint = r.seq)
  from public.events r
  left join lateral (
    select (e.data->>'to_bill')::bigint as to_bill, (e.data->>'to_table')::int as to_table
    from public.events e
    where e.type = 'move' and (e.data->>'round')::bigint = r.seq
    order by e.seq desc limit 1) m on true
  left join lateral (
    select e.data->>'status' as status
    from public.events e
    where e.type = 'status' and (e.data->>'round')::bigint = r.seq
    order by e.seq desc limit 1) s on true
  where r.type = 'round' and r.seq > public.since_reset();
$$;

create or replace function public.open_bill(p_table int) returns bigint
language sql stable set search_path = '' as $$
  select r.bill from public.rounds_now() r
  where r.tbl = p_table and not r.rejected and not public.bill_is_closed(r.bill)
  order by r.seq desc limit 1;
$$;

-- Orders a waiter types in are confirmed by that same waiter on the spot.
create or replace function public.staff_order(p_table int, p_items jsonb, p_waiter text)
returns public.events language plpgsql security definer set search_path = '' as $$
declare
  v_round public.events;
begin
  perform public.require_staff();
  v_round := public.place_round(p_table, p_items, 'waiter', public.clean_waiter(p_waiter));
  perform public.append_event('status', jsonb_build_object(
    'round', v_round.seq, 'status', 'accepted', 'waiter', public.clean_waiter(p_waiter)));
  return v_round;
end $$;

create function public.staff_accept(p_round bigint, p_table int, p_waiter text)
returns public.events language plpgsql security definer set search_path = '' as $$
declare
  v_r      record;
  v_to     bigint;
  v_waiter text := public.clean_waiter(p_waiter);
begin
  perform public.require_staff();
  perform pg_advisory_xact_lock(4242);
  select * into v_r from public.rounds_now() where seq = p_round;
  if not found then raise exception 'Непозната нарачка'; end if;
  if v_r.rejected then raise exception 'Нарачката е одбиена'; end if;
  if v_r.status <> 'new' then raise exception 'Нарачката е веќе прифатена'; end if;
  if public.bill_is_closed(v_r.bill) then raise exception 'Сметката е затворена'; end if;
  if p_table is not null and p_table <> v_r.tbl then
    if p_table < 1 or p_table > 20 then raise exception 'Непозната маса'; end if;
    -- Joins that table's open bill, or opens a new one numbered by this move.
    v_to := coalesce(public.open_bill(p_table),
                     (select coalesce(max(seq), 0) + 1 from public.events));
    perform public.append_event('move', jsonb_build_object(
      'round', p_round, 'from_table', v_r.tbl, 'to_table', p_table,
      'from_bill', v_r.bill, 'to_bill', v_to, 'waiter', v_waiter));
  end if;
  return public.append_event('status', jsonb_build_object(
    'round', p_round, 'status', 'accepted', 'waiter', v_waiter));
end $$;

-- (Replaced in 20261009124107 to read v_r.source instead of v_r.by.)
create function public.staff_reject(p_round bigint, p_reason text, p_waiter text)
returns public.events language plpgsql security definer set search_path = '' as $$
declare
  v_r record;
begin
  perform public.require_staff();
  perform pg_advisory_xact_lock(4242);
  select * into v_r from public.rounds_now() where seq = p_round;
  if not found then raise exception 'Непозната нарачка'; end if;
  if v_r.by <> 'guest' then raise exception 'Само нарачки од гости може да се одбијат'; end if;
  if v_r.rejected then raise exception 'Нарачката е веќе одбиена'; end if;
  if v_r.status <> 'new' then raise exception 'Прифатена нарачка не може да се одбие'; end if;
  if public.bill_is_closed(v_r.bill) then raise exception 'Сметката е затворена'; end if;
  if p_reason is null or length(trim(p_reason)) = 0 then raise exception 'Напишете причина'; end if;
  return public.append_event('reject', jsonb_build_object(
    'round', p_round, 'table', v_r.tbl, 'reason', left(trim(p_reason), 120),
    'waiter', public.clean_waiter(p_waiter)));
end $$;

create or replace function public.staff_status(p_round bigint, p_status text, p_waiter text)
returns public.events language plpgsql security definer set search_path = '' as $$
declare
  v_r     record;
  v_order text[] := array['new','accepted','served'];
begin
  perform public.require_staff();
  perform pg_advisory_xact_lock(4242);
  select * into v_r from public.rounds_now() where seq = p_round;
  if not found then raise exception 'Непозната нарачка'; end if;
  if v_r.rejected then raise exception 'Нарачката е одбиена'; end if;
  if public.bill_is_closed(v_r.bill) then raise exception 'Сметката е затворена'; end if;
  if coalesce(array_position(v_order, p_status), 0) <= array_position(v_order, v_r.status) then
    raise exception 'Статусот оди само напред';
  end if;
  return public.append_event('status', jsonb_build_object(
    'round', p_round, 'status', p_status, 'waiter', public.clean_waiter(p_waiter)));
end $$;

create or replace function public.staff_close(p_bill bigint, p_method text, p_waiter text)
returns public.events language plpgsql security definer set search_path = '' as $$
declare
  v_total  numeric;
  v_number int;
begin
  perform public.require_staff();
  perform pg_advisory_xact_lock(4242);
  if p_method not in ('cash','card') then raise exception 'Изберете начин на плаќање'; end if;
  if public.bill_is_closed(p_bill) then raise exception 'Сметката е веќе затворена'; end if;
  if not exists (select 1 from public.rounds_now() where bill = p_bill and not rejected) then
    raise exception 'Непозната или празна сметка';
  end if;
  if exists (select 1 from public.rounds_now() where bill = p_bill and not rejected and status = 'new') then
    raise exception 'Прво потврдете ги или одбијте ги новите нарачки';
  end if;
  select sum(total) into v_total from public.rounds_now() where bill = p_bill and not rejected;
  select count(*) + 1 into v_number from public.events
   where type = 'close' and seq > public.since_reset();
  return public.append_event('close', jsonb_build_object(
    'bill', p_bill, 'method', p_method, 'total', v_total, 'number', v_number,
    'waiter', public.clean_waiter(p_waiter)));
end $$;

revoke execute on function public.rounds_now() from public, anon, authenticated;
revoke execute on function public.staff_accept(bigint, int, text), public.staff_reject(bigint, text, text) from public, anon;
grant execute on function public.staff_accept(bigint, int, text), public.staff_reject(bigint, text, text) to authenticated;
