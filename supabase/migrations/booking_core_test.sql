-- Booking core tests (52 checks). Run against a THROWAWAY database only: it inserts bookings.
-- Order: 00_local_stub.sql (plain Postgres only) -> migrations -> seed.sql -> this file (psql, not a GUI: uses \gset).
\set QUIET on
create temp table results(name text, ok boolean);
grant all on results to public;
create function pg_temp.t(name text, cond boolean) returns void language plpgsql as $$
begin insert into results values (name, coalesce(cond,false));
  raise notice '% : %', case when coalesce(cond,false) then 'PASS' else 'FAIL' end, name; end $$;
create function pg_temp.mk(t text, i int, o int, g int, n int) returns jsonb language sql as $$
  select public.create_booking(t, public.today_tpe()+i, public.today_tpe()+o, g, 'Guest '||n, '0912'||lpad(n::text,6,'0'), 'g'||n||'@example.com') $$;
create function pg_temp.q(t text, i int, o int) returns jsonb language sql as $$
  select public.quote_stay(t, public.today_tpe()+i, public.today_tpe()+o) $$;

-- T1 availability shape
select pg_temp.t('availability: 3 nights x 5 types, all open',
  (select count(*)=15 and bool_and(available) from public.get_availability(public.today_tpe()+40, public.today_tpe()+42)));

-- T2-T4 allocation + best-fit packing
select pg_temp.t('sea_duplex -> villa A 2F+3F', (pg_temp.mk('sea_duplex',40,42,4,1)->'zones') = '["A2","A3"]'::jsonb);
select pg_temp.t('pool_two packs into busier villa A (A1)', (pg_temp.mk('pool_two',40,42,2,2)->'zones') = '["A1"]'::jsonb);
select pg_temp.t('villa goes to villa B', (pg_temp.mk('villa',40,42,10,3)->'zones') = '["B1","B2","B3"]'::jsonb);
select pg_temp.t('villa A + B full: every type unavailable on those nights',
  (select bool_and(pg_temp.q(id,40,42)->>'error' = 'unavailable') from public.room_types));
select pg_temp.t('availability calendar shows none open', 
  (select not bool_or(available) from public.get_availability(public.today_tpe()+40, public.today_tpe()+41)));
select pg_temp.t('same-day turnover allowed (check-in on previous check-out)', (pg_temp.mk('villa',42,44,10,4)->>'ok')::boolean);
select pg_temp.t('overlapping villa request lands in the OTHER villa', (pg_temp.mk('villa',43,45,10,5)->'zones') = '["B1","B2","B3"]'::jsonb);
select pg_temp.t('third overlapping villa request refused (only 2 villas)', pg_temp.mk('villa',43,44,10,55)->>'error' = 'unavailable');

-- T7 cancel frees inventory
update public.bookings set status='cancelled' where guest_name='Guest 3';
select pg_temp.t('cancel frees villa B', (pg_temp.q('villa',40,42)->>'ok')::boolean);
select pg_temp.t('cancel frees zones in booking_zones', (select not active from public.booking_zones bz join public.bookings b on b.id=bz.booking_id where b.guest_name='Guest 3' limit 1));
update public.bookings set status='pending' where guest_name='Guest 3';
select pg_temp.t('re-activating a freed booking works when nothing conflicts', (select active from public.booking_zones bz join public.bookings b on b.id=bz.booking_id where b.guest_name='Guest 3' limit 1));

-- T8 estate blocks everything
select pg_temp.t('estate books all 6 zones', jsonb_array_length(pg_temp.mk('estate',50,52,20,6)->'zones') = 6);
select pg_temp.t('after estate, pool_two unavailable same nights', pg_temp.q('pool_two',50,52)->>'error'='unavailable');
select pg_temp.t('after estate, pool_two ok the night it checks out', (pg_temp.q('pool_two',52,53)->>'ok')::boolean);
select pg_temp.t('estate refused when one zone busy', pg_temp.mk('estate',40,41,20,7)->>'error'='unavailable');

-- T9 DB-level guard, bypassing the functions
do $$ begin
  insert into public.bookings(ref,status,source,room_type_id,check_in,check_out,guest_name)
    values('RAW-1','confirmed','staff','pool_two',public.today_tpe()+40,public.today_tpe()+41,'raw');
  insert into public.booking_zones(booking_id,zone_id,stay)
    select id,'A1',daterange(check_in,check_out,'[)') from public.bookings where ref='RAW-1';
  perform pg_temp.t('EXCLUDE constraint blocks raw double insert', false);
exception when exclusion_violation then perform pg_temp.t('EXCLUDE constraint blocks raw double insert', true);
end $$;

-- T11 expiry
select pg_temp.mk('pool_two',60,62,2,8) as r \gset
update public.bookings set expires_at = now() - interval '1 minute' where guest_name='Guest 8';
select pg_temp.t('expire_pending releases overdue hold', public.expire_pending() >= 1 and (pg_temp.q('pool_two',60,62)->>'ok')::boolean);
select pg_temp.t('expired booking marked expired', (select status='expired' from public.bookings where guest_name='Guest 8'));

-- T12 validation
select pg_temp.t('bad phone rejected', public.create_booking('pool_two', public.today_tpe()+70, public.today_tpe()+71, 2,'X','abc','a@b.co')->>'error'='invalid_contact');
select pg_temp.t('bad email rejected', public.create_booking('pool_two', public.today_tpe()+70, public.today_tpe()+71, 2,'X','0912345678','nope')->>'error'='invalid_contact');
select pg_temp.t('too many guests rejected', pg_temp.mk('pool_two',70,71,5,9)->>'error'='guests_out_of_range');
select pg_temp.t('past date rejected', pg_temp.mk('pool_two',-3,-1,2,10)->>'error'='invalid_dates');
select pg_temp.t('checkout before checkin rejected', pg_temp.mk('pool_two',72,71,2,11)->>'error'='invalid_dates');
select pg_temp.t('31-night stay rejected', pg_temp.mk('pool_two',80,111,2,12)->>'error'='invalid_dates');
select pg_temp.t('unknown room rejected', pg_temp.mk('nope',70,71,2,13)->>'error'='unknown_room');
select public.create_booking('pool_two', public.today_tpe()+90, public.today_tpe()+91, 2,'S','0911111111','same@x.co') \g /dev/null
select public.create_booking('pool_two', public.today_tpe()+92, public.today_tpe()+93, 2,'S','0911111112','same@x.co') \g /dev/null
select public.create_booking('pool_two', public.today_tpe()+94, public.today_tpe()+95, 2,'S','0911111113','same@x.co') \g /dev/null
select pg_temp.t('4th pending hold by same email refused',
  public.create_booking('pool_two', public.today_tpe()+96, public.today_tpe()+97, 2,'S','0911111114','same@x.co')->>'error'='too_many_pending');

-- T15 pricing
update public.room_types set base_price=5000, deposit_percent=30 where id='pool_two';
insert into public.daily_prices values ('pool_two', public.today_tpe()+100, 8000);
select pg_temp.t('price: 5000 + 8000 override = 13000, deposit 30% = 3900',
  (pg_temp.q('pool_two',99,101)->>'total')::numeric=13000 and (pg_temp.q('pool_two',99,101)->>'deposit')::numeric=3900);
select pg_temp.t('no price -> total null (contact us)', pg_temp.q('sea_duplex',99,101)->'total' = 'null'::jsonb);

-- T14 get_booking
select pg_temp.mk('pool_two',120,122,2,14)->>'access_token' as tok \gset
select pg_temp.t('get_booking works with correct token', (public.get_booking((select ref from public.bookings where guest_name='Guest 14'), :'tok'::uuid)->>'ok')::boolean);
select pg_temp.t('get_booking refuses wrong token', public.get_booking((select ref from public.bookings where guest_name='Guest 14'), gen_random_uuid())->>'error'='not_found');

-- T13 permissions
insert into auth.users values ('00000000-0000-0000-0000-0000000000a1'), ('00000000-0000-0000-0000-0000000000b2');
insert into public.staff values ('00000000-0000-0000-0000-0000000000a1','staff@baisha36.co','staff');

do $$
declare n int; r jsonb;
begin
  -- anon
  set local role anon;
  begin perform 1 from public.bookings limit 1; perform pg_temp.t('anon cannot read bookings', false);
  exception when insufficient_privilege then perform pg_temp.t('anon cannot read bookings', true); end;
  begin perform 1 from public.booking_zones limit 1; perform pg_temp.t('anon cannot read booking_zones', false);
  exception when insufficient_privilege then perform pg_temp.t('anon cannot read booking_zones', true); end;
  begin perform public.create_booking('pool_two', current_date+200, current_date+201, 2,'a','0912345678','a@b.co'); perform pg_temp.t('anon cannot call create_booking', false);
  exception when insufficient_privilege then perform pg_temp.t('anon cannot call create_booking', true); end;
  begin perform public.expire_pending(); perform pg_temp.t('anon cannot call expire_pending', false);
  exception when insufficient_privilege then perform pg_temp.t('anon cannot call expire_pending', true); end;
  begin perform public.find_allocation('villa', current_date+1, current_date+2); perform pg_temp.t('anon cannot call find_allocation', false);
  exception when insufficient_privilege then perform pg_temp.t('anon cannot call find_allocation', true); end;
  select count(*) into n from public.get_availability(current_date+1, current_date+2);
  perform pg_temp.t('anon can read availability', n > 0);
  select count(*) into n from public.room_types;
  perform pg_temp.t('anon can read room types', n = 5);
  reset role;
end $$;

do $$
declare n int; r jsonb;
begin
  -- logged-in but NOT staff
  perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000b2', true);
  set local role authenticated;
  select count(*) into n from public.bookings;
  perform pg_temp.t('non-staff user sees 0 bookings', n = 0);
  r := public.staff_create_booking('pool_two', current_date+150, current_date+151, 2,'x','0912345678','a@b.co');
  perform pg_temp.t('non-staff cannot staff_create_booking', r->>'error'='forbidden');
  r := public.staff_block(array['A1'], current_date+150, current_date+151);
  perform pg_temp.t('non-staff cannot staff_block', r->>'error'='forbidden');
  update public.bookings set status='cancelled';
  get diagnostics n = row_count;
  perform pg_temp.t('non-staff cannot update bookings', n = 0);
  reset role;
end $$;

do $$
declare n int; r jsonb; bid uuid;
begin
  -- staff
  perform set_config('request.jwt.claim.sub','00000000-0000-0000-0000-0000000000a1', true);
  set local role authenticated;
  select count(*) into n from public.bookings;
  perform pg_temp.t('staff sees bookings', n > 5);
  select count(*) into n from public.booking_zones;
  perform pg_temp.t('staff sees booking_zones', n > 5);
  r := public.staff_create_booking('pool_two', current_date+150, current_date+152, 3,'電話客人','0922333444',null,'LINE 訂房','confirmed');
  perform pg_temp.t('staff can create phone booking (no email)', (r->>'ok')::boolean);
  r := public.staff_block(array['B2','B3'], current_date+160, current_date+163, '維修');
  perform pg_temp.t('staff can block zones', (r->>'ok')::boolean);
  r := public.staff_block(array['B2'], current_date+161, current_date+162, 'again');
  perform pg_temp.t('blocking an already-blocked zone is refused', r->>'error'='unavailable');
  update public.bookings set status='confirmed', deposit_paid_at=now() where guest_name='Guest 14';
  get diagnostics n = row_count;
  perform pg_temp.t('staff can confirm a booking', n = 1);
  update public.bookings set status='cancelled' where guest_name='電話客人';
  get diagnostics n = row_count;
  perform pg_temp.t('staff can cancel a booking (trigger frees zones under RLS)', n = 1);
  begin perform public.create_booking('pool_two', current_date+200, current_date+201, 2,'a','0912345678','a@b.co'); perform pg_temp.t('staff cannot call web create_booking', false);
  exception when insufficient_privilege then perform pg_temp.t('staff cannot call web create_booking', true); end;
  begin insert into public.bookings(ref,status,check_in,check_out,guest_name) values('X','pending',current_date,current_date+1,'x'); perform pg_temp.t('staff cannot raw-insert bookings', false);
  exception when insufficient_privilege then perform pg_temp.t('staff cannot raw-insert bookings', true); end;
  reset role;
end $$;

do $$
declare r jsonb;
begin
  set local role service_role;
  r := public.create_booking('sea_duplex', current_date+300, current_date+302, 2,'svc','0912345678','svc@b.co');
  perform pg_temp.t('service_role can create_booking', (r->>'ok')::boolean);
  reset role;
end $$;

select count(*) filter (where ok) as passed, count(*) filter (where not ok) as failed from results;
