-- ---- SEAL ----
create function public.event_seal(p_seq bigint, p_at timestamptz, p_type text, p_data jsonb, p_prev text)
returns text language sql immutable set search_path = '' as $$
  select encode(extensions.digest(convert_to(
    p_seq::text || '|' || to_char(p_at at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US') || '|' ||
    p_type || '|' || p_data::text || '|' || p_prev, 'UTF8'), 'sha256'), 'hex');
$$;

-- The one place that writes. Callers hold the lock (taken here too) so the
-- chain never forks.
create function public.append_event(p_type text, p_data jsonb)
returns public.events language plpgsql security definer set search_path = '' as $$
declare
  v_last public.events;
  v_row  public.events;
begin
  perform pg_advisory_xact_lock(4242);
  select * into v_last from public.events order by seq desc limit 1;
  v_row.seq  := coalesce(v_last.seq, 0) + 1;
  v_row.at   := clock_timestamp();
  v_row.type := p_type;
  v_row.data := p_data;
  v_row.prev := coalesce(v_last.hash, '0');
  v_row.hash := public.event_seal(v_row.seq, v_row.at, v_row.type, v_row.data, v_row.prev);
  insert into public.events values (v_row.*);
  return v_row;
end $$;

-- ---- STATE HELPERS (everything since the last test reset) ----
create function public.since_reset() returns bigint
language sql stable set search_path = '' as $$
  select coalesce(max(seq), 0) from public.events where type = 'reset';
$$;

create function public.bill_is_closed(p_bill bigint) returns boolean
language sql stable set search_path = '' as $$
  select exists (select 1 from public.events
                 where type = 'close' and (data->>'bill')::bigint = p_bill);
$$;

create function public.open_bill(p_table int) returns bigint
language sql stable set search_path = '' as $$
  select (e.data->>'bill')::bigint from public.events e
  where e.type = 'round' and (e.data->>'table')::int = p_table
    and e.seq > public.since_reset()
    and not public.bill_is_closed((e.data->>'bill')::bigint)
  order by e.seq desc limit 1;
$$;

create function public.is_staff() returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.staff
                 where lower(email) = lower(coalesce(auth.jwt()->>'email', '')));
$$;

-- Prices from the menu table, duplicate names merged, nothing taken on trust.
create function public.priced_items(p_items jsonb)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  v_item  jsonb;
  v_qty   int;
  v_menu  public.menu_items;
  v_merge jsonb := '{}'::jsonb;
  v_out   jsonb := '[]'::jsonb;
  v_key   text;
begin
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Празна нарачка';
  end if;
  if jsonb_array_length(p_items) > 40 then raise exception 'Премногу ставки'; end if;
  for v_item in select * from jsonb_array_elements(p_items) loop
    begin
      v_qty := (v_item->>'qty')::int;
    exception when others then
      raise exception 'Неважечка количина';
    end;
    if v_qty is null or v_qty < 1 or v_qty > 50 then raise exception 'Неважечка количина'; end if;
    select * into v_menu from public.menu_items where name = v_item->>'name' and active;
    if not found then raise exception 'Непозната ставка: %', v_item->>'name'; end if;
    v_merge := jsonb_set(v_merge, array[v_menu.name],
      to_jsonb(coalesce((v_merge->>v_menu.name)::int, 0) + v_qty));
  end loop;
  for v_key in select jsonb_object_keys(v_merge) loop
    select * into v_menu from public.menu_items where name = v_key;
    v_qty := (v_merge->>v_key)::int;
    if v_qty > 50 then raise exception 'Неважечка количина'; end if;
    v_out := v_out || jsonb_build_object('name', v_menu.name, 'price', v_menu.price,
                                         'qty', v_qty, 'category', v_menu.category);
  end loop;
  return v_out;
end $$;

create function public.place_round(p_table int, p_items jsonb, p_by text, p_waiter text)
returns public.events language plpgsql security definer set search_path = '' as $$
declare
  v_items jsonb;
  v_total numeric;
  v_bill  bigint;
begin
  if p_table is null or p_table < 1 or p_table > 20 then raise exception 'Непозната маса'; end if;
  v_items := public.priced_items(p_items);
  select sum((i->>'price')::numeric * (i->>'qty')::int) into v_total from jsonb_array_elements(v_items) i;
  perform pg_advisory_xact_lock(4242);
  v_bill := coalesce(public.open_bill(p_table),
                     (select coalesce(max(seq), 0) + 1 from public.events));
  return public.append_event('round', jsonb_strip_nulls(jsonb_build_object(
    'table', p_table, 'bill', v_bill, 'items', v_items, 'total', v_total,
    'by', p_by, 'waiter', p_waiter)));
end $$;

create function public.clean_waiter(p_waiter text) returns text
language plpgsql immutable set search_path = '' as $$
begin
  if p_waiter is null or length(trim(p_waiter)) = 0 then raise exception 'Изберете келнер'; end if;
  return left(trim(p_waiter), 40);
end $$;

create function public.require_staff() returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_staff() then raise exception 'Само за персонал — најавете се'; end if;
end $$;

-- ---- GUEST API ----
create function public.guest_order(p_table int, p_items jsonb)
returns public.events language sql security definer set search_path = '' as $$
  select public.place_round(p_table, p_items, 'guest', null);
$$;

create function public.guest_request_bill(p_table int)
returns public.events language plpgsql security definer set search_path = '' as $$
declare
  v_bill bigint;
begin
  perform pg_advisory_xact_lock(4242);
  v_bill := public.open_bill(p_table);
  if v_bill is null then raise exception 'Нема отворена сметка'; end if;
  if exists (select 1 from public.events where type = 'bill_request'
             and (data->>'bill')::bigint = v_bill) then
    return null;   -- already called; once is enough
  end if;
  return public.append_event('bill_request', jsonb_build_object('bill', v_bill, 'table', p_table));
end $$;

-- ---- STAFF API ----
create function public.staff_order(p_table int, p_items jsonb, p_waiter text)
returns public.events language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_staff();
  return public.place_round(p_table, p_items, 'waiter', public.clean_waiter(p_waiter));
end $$;

create function public.staff_status(p_round bigint, p_status text, p_waiter text)
returns public.events language plpgsql security definer set search_path = '' as $$
declare
  v_round  public.events;
  v_cur    text;
  v_order  text[] := array['new','accepted','served'];
begin
  perform public.require_staff();
  perform pg_advisory_xact_lock(4242);
  select * into v_round from public.events
   where seq = p_round and type = 'round' and seq > public.since_reset();
  if not found then raise exception 'Непозната нарачка'; end if;
  if public.bill_is_closed((v_round.data->>'bill')::bigint) then raise exception 'Сметката е затворена'; end if;
  select coalesce((select data->>'status' from public.events
                   where type = 'status' and (data->>'round')::bigint = p_round
                   order by seq desc limit 1), 'new') into v_cur;
  if coalesce(array_position(v_order, p_status), 0) <= array_position(v_order, v_cur) then
    raise exception 'Статусот оди само напред';
  end if;
  return public.append_event('status', jsonb_build_object(
    'round', p_round, 'status', p_status, 'waiter', public.clean_waiter(p_waiter)));
end $$;

create function public.staff_close(p_bill bigint, p_method text, p_waiter text)
returns public.events language plpgsql security definer set search_path = '' as $$
declare
  v_total  numeric;
  v_number int;
begin
  perform public.require_staff();
  perform pg_advisory_xact_lock(4242);
  if p_method not in ('cash','card') then raise exception 'Изберете начин на плаќање'; end if;
  if not exists (select 1 from public.events where type = 'round'
                 and (data->>'bill')::bigint = p_bill and seq > public.since_reset()) then
    raise exception 'Непозната сметка';
  end if;
  if public.bill_is_closed(p_bill) then raise exception 'Сметката е веќе затворена'; end if;
  select sum((data->>'total')::numeric) into v_total from public.events
   where type = 'round' and (data->>'bill')::bigint = p_bill;
  select count(*) + 1 into v_number from public.events
   where type = 'close' and seq > public.since_reset();
  return public.append_event('close', jsonb_build_object(
    'bill', p_bill, 'method', p_method, 'total', v_total, 'number', v_number,
    'waiter', public.clean_waiter(p_waiter)));
end $$;

-- Test environment only: starts the screens from zero WITHOUT deleting
-- anything. Old events stay in the ledger, below a 'reset' line.
create function public.staff_reset_test(p_waiter text)
returns public.events language plpgsql security definer set search_path = '' as $$
begin
  perform public.require_staff();
  return public.append_event('reset', jsonb_build_object('waiter', public.clean_waiter(p_waiter)));
end $$;

-- First event whose seal does not match, or null when the chain is intact.
create function public.verify_ledger() returns bigint
language plpgsql stable security definer set search_path = '' as $$
declare
  v_e    public.events;
  v_prev text := '0';
  v_n    bigint := 0;
begin
  for v_e in select * from public.events order by seq loop
    v_n := v_n + 1;
    if v_e.seq <> v_n or v_e.prev <> v_prev
       or v_e.hash <> public.event_seal(v_e.seq, v_e.at, v_e.type, v_e.data, v_e.prev) then
      return v_e.seq;
    end if;
    v_prev := v_e.hash;
  end loop;
  return null;
end $$;

-- ---- GRANTS ----
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.guest_order(int, jsonb), public.guest_request_bill(int),
  public.verify_ledger(), public.is_staff() to anon, authenticated;
grant execute on function public.staff_order(int, jsonb, text), public.staff_status(bigint, text, text),
  public.staff_close(bigint, text, text), public.staff_reset_test(text) to authenticated;
