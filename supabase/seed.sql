-- Baisha36 seed data. Safe to re-run on an empty database.
-- Values marked [請確認] come from the website copy or are placeholders.

insert into public.zones (id, villa, level, label_zh, label_en) values
  ('A1', 'A', 1, 'A棟 1F 泳池層', 'Villa A · 1F pool level'),
  ('A2', 'A', 2, 'A棟 2F',        'Villa A · 2F'),
  ('A3', 'A', 3, 'A棟 3F',        'Villa A · 3F'),
  ('B1', 'B', 1, 'B棟 1F 泳池層', 'Villa B · 1F pool level'),
  ('B2', 'B', 2, 'B棟 2F',        'Villa B · 2F'),
  ('B3', 'B', 3, 'B棟 3F',        'Villa B · 3F')
on conflict do nothing;

-- capacities taken from index.html; prices / deposit / min nights are placeholders
insert into public.room_types
  (id, sort, scope, name_zh, name_en, min_guests, max_guests, min_nights, base_price, deposit_percent) values
  ('estate',      1, 'estate',    '全館包棟',       'The whole estate',               16, 24, 1, null, null),  -- [請填 房價/訂金]
  ('villa',       2, 'one_villa', '泳池Villa包棟',  'Private Villa',                   8, 12, 1, null, null),
  ('villa_small', 3, 'one_villa', '泳池Villa小包棟', 'Small-Group Villa',               6, 10, 1, null, null),
  ('pool_two',    4, 'one_villa', '泳池景觀雙房',   'Pool View Two-Room Stay',          2,  4, 1, null, null),
  ('sea_duplex',  5, 'one_villa', '海景樓中樓雙房', 'Sea View Duplex Two-Room Stay',    2,  6, 1, null, null)
on conflict do nothing;

-- Levels of ONE villa that each type uses  [請確認 這個對應是否符合實際房況]
insert into public.room_type_levels (room_type_id, level) values
  ('villa', 1), ('villa', 2), ('villa', 3),      -- whole villa
  ('villa_small', 1), ('villa_small', 2),        -- 3F suite not offered
  ('pool_two', 1),                               -- 1F, two bedrooms, pool view
  ('sea_duplex', 2), ('sea_duplex', 3)           -- 2F + 3F duplex
on conflict do nothing;

insert into public.app_settings (key, value) values
  ('hold_hours', '24')                           -- [請確認] how long a pending request holds the dates
on conflict do nothing;
