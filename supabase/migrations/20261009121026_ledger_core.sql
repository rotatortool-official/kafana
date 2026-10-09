-- KAFANA LEDGER
-- One append-only list of events. Nothing in it is ever updated or deleted;
-- the only way in is through the functions below, which apply the rules.

create table public.events (
  seq   bigint primary key,
  at    timestamptz not null,
  type  text not null check (type in ('round','status','bill_request','close','reset')),
  data  jsonb not null,
  prev  text not null,
  hash  text not null
);

-- The menu's prices live here. Guests and waiters send names and
-- quantities; the price always comes from this table.
create table public.menu_items (
  name     text primary key,
  price    numeric(10,2) not null check (price > 0),
  category text not null default '',
  active   boolean not null default true
);

-- Who may use the till. A signed-in account is staff only if its email is here.
create table public.staff (
  email text primary key
);

-- ---- IMMUTABILITY ----
create function public.ledger_is_append_only() returns trigger
language plpgsql as $$
begin
  raise exception 'The ledger is append-only: events cannot be changed or deleted';
end $$;

create trigger events_no_update before update or delete on public.events
  for each row execute function public.ledger_is_append_only();
create trigger events_no_truncate before truncate on public.events
  for each statement execute function public.ledger_is_append_only();

-- ---- ACCESS ----
alter table public.events enable row level security;
alter table public.menu_items enable row level security;
alter table public.staff enable row level security;

create policy "anyone reads the ledger" on public.events for select to anon, authenticated using (true);
create policy "anyone reads the menu" on public.menu_items for select to anon, authenticated using (true);
-- staff: no policies, so nobody reads or writes it through the API.

revoke insert, update, delete, truncate on public.events from anon, authenticated;
revoke insert, update, delete, truncate on public.menu_items from anon, authenticated;
revoke all on public.staff from anon, authenticated;

alter publication supabase_realtime add table public.events;
