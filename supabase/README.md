# Kafana database (Supabase)

Test environment: project **kafana** (`zrlszhpesifpuikwgxnk`, Frankfurt, free plan),
in the rotatortool-official organisation. Created 2026-10-09.

- `migrations/` — everything that built the database, in order.
- `seed_menu.sql` — the menu's names, prices and categories.

## When the menu changes

Prices on the bill come from the `menu_items` table, **not** from `index.html`.
After changing a dish or a price in `index.html`, run the same change in the
Supabase SQL editor, for example:

```sql
update public.menu_items set price = 190 where name = 'Шопска Салата';
insert into public.menu_items (name, price, category) values ('Нова Ставка', 200, 'main');
update public.menu_items set active = false where name = 'Стара Ставка';   -- never delete
```

A dish that is on the page but not in the table is refused when a guest
sends it ("Непозната ставка").

## Staff accounts

Only emails listed in `public.staff` can use the till. Add the login in
Authentication → Users → Add user (auto-confirm), then:

```sql
insert into public.staff (email) values ('someone@example.com');
```

## What cannot be done, by design

The `events` table refuses UPDATE, DELETE and TRUNCATE for everyone.
"Почни тест од почеток" on the till only adds a `reset` line; the old
events stay. A production copy should drop `staff_reset_test`.
