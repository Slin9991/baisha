-- =====================================================================
-- Baisha36 booking core  (Supabase / PostgreSQL 15+)
--
-- Inventory model
--   The estate has two villas (A, B). Each villa is split into three
--   bookable levels (zones):  1F pool-view floor, 2F, 3F.
--   Every room type is a SET of zones (see room_type_levels), so
--   "whole estate" automatically blocks every other room type, and
--   "pool-view two-room" (1F) and "sea-view duplex" (2F+3F) can be sold
--   at the same time in the same villa.
--
--   Double booking is prevented by the database itself: an EXCLUDE
--   constraint on booking_zones refuses two active bookings for the same
--   zone on overlapping nights, no matter how many guests / staff click at
--   the same moment.
--
-- Stay ranges are [check_in, check_out) -> same-day turnover is allowed.
-- All "today" logic uses Asia/Taipei.
-- =====================================================================

create extension if not exists btree_gist;

-- ---------------------------------------------------------------------
-- Reference data
-- ---------------------------------------------------------------------
create table public.zones (
  id       text primary key,                 -- 'A1', 'A2', ...
  villa    text not null,                    -- 'A' | 'B'
  level    int  not null check (level between 1 and 3),
  label_zh text not null,
  label_en text not null,
  unique (villa, level)
);

create table public.room_types (
  id              text primary key,          -- 'estate','villa','villa_small','pool_two','sea_duplex'
  sort            int  not null,
  scope           text not null check (scope in ('estate', 'one_villa')),
  name_zh         text not null,
  name_en         text not null,
  min_guests      int  not null check (min_guests >= 1),
  max_guests      int  not null check (max_guests >= min_guests),
  min_nights      int  not null default 1 check (min_nights >= 1),
  base_price      numeric(10,0),             -- NT$ per night; NULL = "contact us"
  deposit_percent int check (deposit_percent between 0 and 100),   -- NULL = not defined yet
  active          boolean not null default true
);

-- Which levels of ONE villa a room type consumes (ignored for scope='estate').
create table public.room_type_levels (
  room_type_id text not null references public.room_types(id) on delete cascade,
  level        int  not null check (level between 1 and 3),
  primary key (room_type_id, level)
);

-- Optional per-night price override (weekends, holidays, seasons).
create table public.daily_prices (
  room_type_id text not null references public.room_types(id) on delete cascade,
  stay_date    date not null,
  price        numeric(10,0) not null check (price >= 0),
  primary key (room_type_id, stay_date)
);

create table public.app_settings (
  key   text primary key,
  value text not null
);

-- Staff allow-list. Rows are created by the owner (SQL editor) for each
-- Supabase Auth user that may use /admin.
create table public.staff (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email   text not null,
  role    text not null default 'staff' check (role in ('staff', 'owner'))
);

-- ---------------------------------------------------------------------
-- Bookings
-- ---------------------------------------------------------------------
create type public.booking_status as enum
  ('pending', 'confirmed', 'cancelled', 'expired', 'blocked');

create sequence public.booking_seq;

create table public.bookings (
  id               uuid primary key default gen_random_uuid(),
  ref              text not null unique,                -- B36-261126-0001
  access_token     uuid not null default gen_random_uuid(),
  status           public.booking_status not null,
  source           text not null default 'web'
                     check (source in ('web', 'staff', 'airbnb', 'ical')),
  room_type_id     text references public.room_types(id),   -- NULL for pure blocks
  check_in         date not null,
  check_out        date not null,
  guests           int,
  guest_name       text,
  guest_phone      text,
  guest_email      text,
  guest_note       text,
  lang             text not null default 'zh' check (lang in ('zh', 'en')),
  total_price      numeric(10,0),
  deposit_due      numeric(10,0),
  deposit_paid_at  timestamptz,
  expires_at       timestamptz,                         -- only for pending holds
  external_uid     text,                                -- iCal UID for imported blocks
  staff_note       text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  check (check_out > check_in),
  check (status = 'blocked' or guest_name is not null)
);

create index bookings_status_idx   on public.bookings (status, check_in);
create index bookings_pending_idx  on public.bookings (expires_at) where status = 'pending';
create unique index bookings_external_uid_idx
  on public.bookings (source, external_uid) where external_uid is not null;

-- One row per zone a booking occupies. THIS is what guarantees no double booking.
create table public.booking_zones (
  booking_id uuid      not null references public.bookings(id) on delete cascade,
  zone_id    text      not null references public.zones(id),
  stay       daterange not null,
  active     boolean   not null default true,
  primary key (booking_id, zone_id),
  constraint no_double_booking
    exclude using gist (zone_id with =, stay with &&) where (active)
);

-- Keep booking_zones in step with the booking (cancel / expire frees the zones).
create or replace function public.bookings_sync_zones()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.booking_zones
     set active = new.status in ('pending', 'confirmed', 'blocked'),
         stay   = daterange(new.check_in, new.check_out, '[)')
   where booking_id = new.id;
  return new;
end $$;

create trigger trg_bookings_sync_zones
  after update of status, check_in, check_out on public.bookings
  for each row execute function public.bookings_sync_zones();

create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

create trigger trg_bookings_touch
  before update on public.bookings
  for each row execute function public.touch_updated_at();

-- ---------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------
create or replace function public.today_tpe()
returns date language sql stable as $$
  select (now() at time zone 'Asia/Taipei')::date
$$;

create or replace function public.is_staff()
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.staff where user_id = auth.uid())
$$;

create or replace function public._err(p_code text, p_extra jsonb default '{}'::jsonb)
returns jsonb language sql immutable as $$
  select jsonb_build_object('ok', false, 'error', p_code) || p_extra
$$;

-- Returns the zones a booking of this type would occupy, or NULL if it
-- cannot be placed. For one-villa types it tries each villa and prefers
-- the villa that is already the busiest ("best fit"), which keeps the
-- other villa whole for larger bookings.
create or replace function public.find_allocation(p_room_type text, p_in date, p_out date)
returns text[]
language plpgsql stable set search_path = public as $$
declare
  v_scope     text;
  v_levels    int[];
  v_range     daterange := daterange(p_in, p_out, '[)');
  v_villa     text;
  v_ids       text[];
  v_best      text[];
  v_best_load int := -1;
  v_load      int;
begin
  select scope into v_scope from room_types where id = p_room_type and active;
  if v_scope is null then
    return null;
  end if;

  if v_scope = 'estate' then
    select array_agg(id order by id) into v_ids from zones;
    if exists (select 1 from booking_zones bz
                where bz.active and bz.zone_id = any (v_ids) and bz.stay && v_range) then
      return null;
    end if;
    return v_ids;
  end if;

  select array_agg(level order by level) into v_levels
    from room_type_levels where room_type_id = p_room_type;

  for v_villa in select distinct villa from zones order by villa loop
    select array_agg(id order by level) into v_ids
      from zones where villa = v_villa and level = any (v_levels);
    if v_ids is null then
      continue;
    end if;

    if exists (select 1 from booking_zones bz
                where bz.active and bz.zone_id = any (v_ids) and bz.stay && v_range) then
      continue;
    end if;

    select count(distinct bz.zone_id) into v_load
      from booking_zones bz join zones z on z.id = bz.zone_id
     where bz.active and z.villa = v_villa and bz.stay && v_range;

    if v_load > v_best_load then
      v_best := v_ids;
      v_best_load := v_load;
    end if;
  end loop;

  return v_best;
end $$;

-- Sum of nightly prices; NULL if any night has no price (=> "contact us").
create or replace function public.calc_total(p_room_type text, p_in date, p_out date)
returns numeric
language sql stable set search_path = public as $$
  select case when count(*) filter (where n.price is null) > 0 then null
              else sum(n.price) end
    from (
      select coalesce(dp.price, rt.base_price) as price
        from generate_series(0, p_out - p_in - 1) g
        join room_types rt on rt.id = p_room_type
        left join daily_prices dp
               on dp.room_type_id = rt.id and dp.stay_date = p_in + g
    ) n
$$;

-- Releases pending holds whose time ran out. Called by cron and before each booking.
create or replace function public.expire_pending()
returns int
language plpgsql security definer set search_path = public as $$
declare v_count int;
begin
  update bookings set status = 'expired'
   where status = 'pending' and expires_at is not null and expires_at < now();
  get diagnostics v_count = row_count;
  return v_count;
end $$;

-- ---------------------------------------------------------------------
-- Public read API (anon): availability + quote
-- ---------------------------------------------------------------------

-- One row per night x room type. "available" = a ONE-night stay starting
-- that date could be placed. The real multi-night check is quote_stay().
create or replace function public.get_availability(p_from date, p_to date)
returns table (stay_date date, room_type_id text, available boolean, price numeric)
language sql stable security definer set search_path = public as $$
  select (p_from + g)                                                    as stay_date,
         rt.id                                                           as room_type_id,
         ((p_from + g) >= public.today_tpe()
           and public.find_allocation(rt.id, p_from + g, p_from + g + 1) is not null) as available,
         coalesce(dp.price, rt.base_price)                               as price
    from generate_series(0, least(p_to - p_from, 400)) g
    cross join public.room_types rt
    left join public.daily_prices dp
           on dp.room_type_id = rt.id and dp.stay_date = p_from + g
   where rt.active
   order by 1, rt.sort
$$;

create or replace function public.quote_stay(p_room_type text, p_in date, p_out date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_rt     room_types%rowtype;
  v_total  numeric;
  v_nights int;
begin
  select * into v_rt from room_types where id = p_room_type and active;
  if not found then
    return _err('unknown_room');
  end if;
  if p_in is null or p_out is null or p_out <= p_in
     or p_in < today_tpe() or p_out - p_in > 30 then
    return _err('invalid_dates');
  end if;
  v_nights := p_out - p_in;
  if v_nights < v_rt.min_nights then
    return _err('min_nights', jsonb_build_object('min_nights', v_rt.min_nights));
  end if;
  if find_allocation(p_room_type, p_in, p_out) is null then
    return _err('unavailable');
  end if;
  v_total := calc_total(p_room_type, p_in, p_out);
  return jsonb_build_object(
    'ok', true,
    'nights', v_nights,
    'total', v_total,
    'deposit', case when v_total is not null and v_rt.deposit_percent is not null
                    then round(v_total * v_rt.deposit_percent / 100.0) end
  );
end $$;

-- Guest status page: needs the booking ref AND its secret token.
create or replace function public.get_booking(p_ref text, p_token uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare b bookings%rowtype; v_rt room_types%rowtype;
begin
  select * into b from bookings
   where ref = p_ref and access_token = p_token and status <> 'blocked';
  if not found then
    return _err('not_found');
  end if;
  select * into v_rt from room_types where id = b.room_type_id;
  return jsonb_build_object(
    'ok', true, 'ref', b.ref, 'status', b.status,
    'room_type', b.room_type_id, 'room_name_zh', v_rt.name_zh, 'room_name_en', v_rt.name_en,
    'check_in', b.check_in, 'check_out', b.check_out, 'guests', b.guests,
    'guest_name', b.guest_name, 'guest_phone', b.guest_phone, 'guest_email', b.guest_email,
    'guest_note', b.guest_note,
    'total', b.total_price, 'deposit', b.deposit_due, 'deposit_paid_at', b.deposit_paid_at,
    'expires_at', b.expires_at, 'created_at', b.created_at
  );
end $$;

-- ---------------------------------------------------------------------
-- Booking creation (internal core + two entry points)
-- ---------------------------------------------------------------------
create or replace function public._make_booking(
  p_room_type text, p_in date, p_out date, p_guests int,
  p_name text, p_phone text, p_email text, p_note text, p_lang text,
  p_source text, p_status public.booking_status)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_rt      room_types%rowtype;
  v_alloc   text[];
  v_total   numeric;
  v_deposit numeric;
  v_id      uuid := gen_random_uuid();
  v_ref     text;
  v_token   uuid;
  v_expires timestamptz;
  v_hold    int;
begin
  perform expire_pending();

  select * into v_rt from room_types where id = p_room_type and active;
  if not found then
    return _err('unknown_room');
  end if;

  if p_in is null or p_out is null or p_out <= p_in or p_out - p_in > 30 then
    return _err('invalid_dates');
  end if;
  if p_source = 'web' and p_in < today_tpe() then
    return _err('invalid_dates');
  end if;
  if p_guests is null or p_guests < 1 then
    return _err('guests_out_of_range');
  end if;
  if p_name is null or length(btrim(p_name)) not between 1 and 80
     or length(coalesce(p_note, '')) > 1000 then
    return _err('invalid_contact');
  end if;

  if p_source = 'web' then
    if p_guests < v_rt.min_guests or p_guests > v_rt.max_guests then
      return _err('guests_out_of_range',
                  jsonb_build_object('min', v_rt.min_guests, 'max', v_rt.max_guests));
    end if;
    if p_out - p_in < v_rt.min_nights then
      return _err('min_nights', jsonb_build_object('min_nights', v_rt.min_nights));
    end if;
    if p_phone is null or p_phone !~ '^[0-9+()\- ]{8,20}$'
       or p_email is null or p_email !~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
      return _err('invalid_contact');
    end if;
    -- cheap abuse guard: a person cannot hold unlimited dates
    if (select count(*) from bookings
         where status = 'pending'
           and (lower(guest_email) = lower(p_email) or guest_phone = p_phone)) >= 3 then
      return _err('too_many_pending');
    end if;
  end if;

  -- serialise creation (volume is low); the EXCLUDE constraint is the real guard
  perform pg_advisory_xact_lock(724801);

  v_alloc := find_allocation(p_room_type, p_in, p_out);
  if v_alloc is null then
    return _err('unavailable');
  end if;

  v_total   := calc_total(p_room_type, p_in, p_out);
  v_deposit := case when v_total is not null and v_rt.deposit_percent is not null
                    then round(v_total * v_rt.deposit_percent / 100.0) end;
  v_hold    := coalesce((select value::int from app_settings where key = 'hold_hours'), 24);
  v_expires := case when p_status = 'pending' then now() + make_interval(hours => v_hold) end;
  v_ref     := 'B36-' || to_char(now() at time zone 'Asia/Taipei', 'YYMMDD')
               || '-' || lpad(nextval('booking_seq')::text, 4, '0');

  begin
    insert into bookings (id, ref, status, source, room_type_id, check_in, check_out, guests,
                          guest_name, guest_phone, guest_email, guest_note, lang,
                          total_price, deposit_due, expires_at)
    values (v_id, v_ref, p_status, p_source, p_room_type, p_in, p_out, p_guests,
            btrim(p_name), nullif(btrim(coalesce(p_phone, '')), ''),
            nullif(btrim(coalesce(p_email, '')), ''), nullif(btrim(coalesce(p_note, '')), ''),
            case when p_lang = 'en' then 'en' else 'zh' end,
            v_total, v_deposit, v_expires)
    returning access_token into v_token;

    insert into booking_zones (booking_id, zone_id, stay)
    select v_id, z, daterange(p_in, p_out, '[)') from unnest(v_alloc) z;
  exception when exclusion_violation then
    return _err('unavailable');
  end;

  return jsonb_build_object(
    'ok', true, 'ref', v_ref, 'access_token', v_token, 'status', p_status,
    'room_type', p_room_type, 'check_in', p_in, 'check_out', p_out,
    'total', v_total, 'deposit', v_deposit, 'expires_at', v_expires,
    'zones', to_jsonb(v_alloc));
end $$;

-- Guest booking: called ONLY by the create-booking Edge Function
-- (after the bot check), never directly from the browser.
create or replace function public.create_booking(
  p_room_type text, p_in date, p_out date, p_guests int,
  p_name text, p_phone text, p_email text,
  p_note text default null, p_lang text default 'zh')
returns jsonb
language sql security definer set search_path = public as $$
  select public._make_booking(p_room_type, p_in, p_out, p_guests,
                              p_name, p_phone, p_email, p_note, p_lang,
                              'web', 'pending')
$$;

-- Staff booking (phone / LINE orders) from the admin page.
create or replace function public.staff_create_booking(
  p_room_type text, p_in date, p_out date, p_guests int,
  p_name text, p_phone text, p_email text,
  p_note text default null, p_status text default 'confirmed')
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not is_staff() then
    return _err('forbidden');
  end if;
  if p_status not in ('pending', 'confirmed') then
    return _err('invalid_status');
  end if;
  return _make_booking(p_room_type, p_in, p_out, p_guests, p_name, p_phone, p_email,
                       p_note, 'zh', 'staff', p_status::booking_status);
end $$;

-- Staff block: close zones for maintenance, owner stay, etc.
create or replace function public.staff_block(
  p_zone_ids text[], p_in date, p_out date, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id  uuid := gen_random_uuid();
  v_ref text;
begin
  if not is_staff() then
    return _err('forbidden');
  end if;
  if p_in is null or p_out is null or p_out <= p_in
     or p_zone_ids is null or cardinality(p_zone_ids) = 0
     or exists (select 1 from unnest(p_zone_ids) z where z not in (select id from zones)) then
    return _err('invalid_request');
  end if;

  perform pg_advisory_xact_lock(724801);
  v_ref := 'BLK-' || to_char(now() at time zone 'Asia/Taipei', 'YYMMDD')
           || '-' || lpad(nextval('booking_seq')::text, 4, '0');
  begin
    insert into bookings (id, ref, status, source, check_in, check_out, staff_note)
    values (v_id, v_ref, 'blocked', 'staff', p_in, p_out, p_note);
    insert into booking_zones (booking_id, zone_id, stay)
    select v_id, z, daterange(p_in, p_out, '[)') from unnest(p_zone_ids) z;
  exception when exclusion_violation then
    return _err('unavailable');
  end;
  return jsonb_build_object('ok', true, 'ref', v_ref, 'id', v_id);
end $$;

-- ---------------------------------------------------------------------
-- Row Level Security + privileges
--   anon          : may read public price/room data and call the read API.
--   authenticated : only staff (allow-list) get access to booking data.
--   service_role  : Edge Functions (bypasses RLS).
-- ---------------------------------------------------------------------
alter table public.zones            enable row level security;
alter table public.room_types       enable row level security;
alter table public.room_type_levels enable row level security;
alter table public.daily_prices     enable row level security;
alter table public.app_settings     enable row level security;
alter table public.staff            enable row level security;
alter table public.bookings         enable row level security;
alter table public.booking_zones    enable row level security;

revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

-- public reference data
grant select on public.room_types, public.daily_prices to anon, authenticated;
create policy room_types_read   on public.room_types   for select to anon, authenticated using (active);
create policy daily_prices_read on public.daily_prices for select to anon, authenticated using (true);

-- staff
grant select on public.zones, public.room_type_levels, public.app_settings,
                public.staff, public.booking_zones to authenticated;
grant select, update on public.bookings to authenticated;
grant insert, update, delete on public.daily_prices to authenticated;
grant update on public.room_types to authenticated;
grant insert, update on public.app_settings to authenticated;

create policy zones_staff            on public.zones            for select to authenticated using (public.is_staff());
create policy room_type_levels_staff on public.room_type_levels for select to authenticated using (public.is_staff());
create policy app_settings_staff_r   on public.app_settings     for select to authenticated using (public.is_staff());
create policy app_settings_staff_w   on public.app_settings     for all    to authenticated using (public.is_staff()) with check (public.is_staff());
create policy staff_self             on public.staff            for select to authenticated using (user_id = auth.uid());
create policy bookings_staff_r       on public.bookings         for select to authenticated using (public.is_staff());
create policy bookings_staff_u       on public.bookings         for update to authenticated using (public.is_staff()) with check (public.is_staff());
create policy booking_zones_staff    on public.booking_zones    for select to authenticated using (public.is_staff());
create policy daily_prices_staff_w   on public.daily_prices     for all    to authenticated using (public.is_staff()) with check (public.is_staff());
create policy room_types_staff_all   on public.room_types       for all    to authenticated using (public.is_staff()) with check (public.is_staff());

-- functions: nothing is callable unless granted below
revoke all on function
  public.bookings_sync_zones(), public.touch_updated_at(), public.today_tpe(),
  public.is_staff(), public._err(text, jsonb),
  public.find_allocation(text, date, date), public.calc_total(text, date, date),
  public.expire_pending(),
  public.get_availability(date, date), public.quote_stay(text, date, date),
  public.get_booking(text, uuid),
  public._make_booking(text, date, date, int, text, text, text, text, text, text, public.booking_status),
  public.create_booking(text, date, date, int, text, text, text, text, text),
  public.staff_create_booking(text, date, date, int, text, text, text, text, text),
  public.staff_block(text[], date, date, text)
from public, anon, authenticated;

grant execute on function public.is_staff()                          to authenticated;
grant execute on function public.get_availability(date, date)        to anon, authenticated;
grant execute on function public.quote_stay(text, date, date)        to anon, authenticated;
grant execute on function public.get_booking(text, uuid)             to anon, authenticated;
grant execute on function public.staff_create_booking(text, date, date, int, text, text, text, text, text) to authenticated;
grant execute on function public.staff_block(text[], date, date, text) to authenticated;
-- service_role (Edge Functions / cron) keeps full access:
grant execute on function public.create_booking(text, date, date, int, text, text, text, text, text) to service_role;
grant execute on function public.expire_pending() to service_role;

-- ---------------------------------------------------------------------
-- Realtime: staff browsers get live changes (RLS still applies).
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.bookings, public.booking_zones;
  end if;
end $$;
