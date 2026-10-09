-- ---- FASTER SERVICE ----
-- One tap confirms every new order on a table.
create function public.staff_accept_table(p_table int, p_waiter text)
returns int language plpgsql security definer set search_path = '' as $$
declare
  v_r      record;
  v_n      int := 0;
  v_waiter text := public.clean_waiter(p_waiter);
begin
  perform public.require_staff();
  perform pg_advisory_xact_lock(4242);
  for v_r in select * from public.rounds_now()
             where bill = public.open_bill(p_table) and not rejected and status = 'new'
             order by seq loop
    perform public.append_event('status', jsonb_build_object(
      'round', v_r.seq, 'status', 'accepted', 'waiter', v_waiter));
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

-- Taking the money confirms whatever is still unconfirmed, in the name of
-- the waiter who takes it, then closes the bill. One tap at the register.
create or replace function public.staff_close(p_bill bigint, p_method text, p_waiter text)
returns public.events language plpgsql security definer set search_path = '' as $$
declare
  v_r      record;
  v_total  numeric;
  v_number int;
  v_waiter text := public.clean_waiter(p_waiter);
begin
  perform public.require_staff();
  perform pg_advisory_xact_lock(4242);
  if p_method not in ('cash','card') then raise exception 'Изберете начин на плаќање'; end if;
  if public.bill_is_closed(p_bill) then raise exception 'Сметката е веќе затворена'; end if;
  if not exists (select 1 from public.rounds_now() where bill = p_bill and not rejected) then
    raise exception 'Непозната или празна сметка';
  end if;
  for v_r in select * from public.rounds_now()
             where bill = p_bill and not rejected and status = 'new' order by seq loop
    perform public.append_event('status', jsonb_build_object(
      'round', v_r.seq, 'status', 'accepted', 'waiter', v_waiter));
  end loop;
  select sum(total) into v_total from public.rounds_now() where bill = p_bill and not rejected;
  select count(*) + 1 into v_number from public.events
   where type = 'close' and seq > public.since_reset();
  return public.append_event('close', jsonb_build_object(
    'bill', p_bill, 'method', p_method, 'total', v_total, 'number', v_number,
    'waiter', v_waiter));
end $$;

revoke execute on function public.staff_accept_table(int, text) from public, anon;
grant execute on function public.staff_accept_table(int, text) to authenticated;

-- ---- RESERVATIONS (staff only) ----
-- Bookings are not money, so they can be changed; they are never deleted,
-- only marked cancelled or no-show, and every change keeps who and when.
create extension if not exists btree_gist with schema extensions;

create table public.reservations (
  id          bigint generated always as identity primary key,
  table_no    int not null check (table_no between 1 and 20),
  starts_at   timestamptz not null,
  ends_at     timestamptz not null,
  guest_name  text not null check (length(trim(guest_name)) between 1 and 80),
  people      int not null default 2 check (people between 1 and 60),
  phone       text check (phone is null or length(phone) <= 30),
  note        text check (note is null or length(note) <= 200),
  status      text not null default 'booked' check (status in ('booked','seated','cancelled','no_show')),
  created_by  text not null,
  created_at  timestamptz not null default now(),
  updated_by  text,
  updated_at  timestamptz,
  check (ends_at > starts_at),
  -- One table cannot hold two live bookings at the same time.
  constraint reservations_no_overlap exclude using gist (
    table_no with =, tstzrange(starts_at, ends_at) with &&
  ) where (status in ('booked','seated'))
);
create index reservations_day on public.reservations (starts_at);

alter table public.reservations enable row level security;
create policy "staff read bookings" on public.reservations for select to authenticated using (public.is_staff());
create policy "staff add bookings" on public.reservations for insert to authenticated with check (public.is_staff());
create policy "staff change bookings" on public.reservations for update to authenticated using (public.is_staff()) with check (public.is_staff());
revoke all on public.reservations from anon;
revoke delete, truncate on public.reservations from authenticated;

create function public.reservation_stamp() returns trigger
language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    new.updated_at := now();
    new.created_by := old.created_by;
    new.created_at := old.created_at;
  end if;
  return new;
end $$;
create trigger reservations_stamp before update on public.reservations
  for each row execute function public.reservation_stamp();

alter publication supabase_realtime add table public.reservations;
