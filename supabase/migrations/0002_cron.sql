-- Releases pending holds automatically every 5 minutes.
-- Needs the pg_cron extension (Supabase: Dashboard -> Database -> Extensions -> pg_cron).
-- NOT yet tested on a real Supabase project (pg_cron is not available in plain local Postgres).
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron;
    perform cron.schedule('expire-pending-holds', '*/5 * * * *', 'select public.expire_pending()');
  else
    raise notice 'pg_cron is not available: enable it, then re-run this file.';
  end if;
end $$;
