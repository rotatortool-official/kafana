-- "by" is a reserved word and cannot be read back from a record; call it source.
drop function public.rounds_now();
create function public.rounds_now()
returns table (seq bigint, bill bigint, tbl int, total numeric, source text, status text, rejected boolean)
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
revoke execute on function public.rounds_now() from public, anon, authenticated;

create or replace function public.staff_reject(p_round bigint, p_reason text, p_waiter text)
returns public.events language plpgsql security definer set search_path = '' as $$
declare
  v_r record;
begin
  perform public.require_staff();
  perform pg_advisory_xact_lock(4242);
  select * into v_r from public.rounds_now() where seq = p_round;
  if not found then raise exception 'Непозната нарачка'; end if;
  if v_r.source <> 'guest' then raise exception 'Само нарачки од гости може да се одбијат'; end if;
  if v_r.rejected then raise exception 'Нарачката е веќе одбиена'; end if;
  if v_r.status <> 'new' then raise exception 'Прифатена нарачка не може да се одбие'; end if;
  if public.bill_is_closed(v_r.bill) then raise exception 'Сметката е затворена'; end if;
  if p_reason is null or length(trim(p_reason)) = 0 then raise exception 'Напишете причина'; end if;
  return public.append_event('reject', jsonb_build_object(
    'round', p_round, 'table', v_r.tbl, 'reason', left(trim(p_reason), 120),
    'waiter', public.clean_waiter(p_waiter)));
end $$;
