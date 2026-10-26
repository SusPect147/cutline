-- CUTLINE: fast payouts.
-- Before: payouts ran only when a player's app nudged the server (every 20-30 s at best), so a withdrawal waited
-- for one nudge to be sent and another to be confirmed. Now:
--   * the database itself calls the game function (pg_net) the moment a withdrawal becomes pending;
--   * a pg_cron job re-checks every 15 s, but calls the function only while something is waiting to be paid;
--   * the function holds a lock while it works (payout_lock / payout_unlock) instead of a fixed 20 s gap,
--     sends, waits for the transfer on chain and marks it paid in the same run, then takes the next request.

create extension if not exists pg_net;
create extension if not exists pg_cron;

alter table private.payout_state add column if not exists busy_until timestamptz not null default 'epoch';

create or replace function public.payout_lock(p_secs int) returns boolean
language sql security definer set search_path = '' as $$
  update private.payout_state set busy_until = now() + make_interval(secs => p_secs), last_run = now()
   where id = 1 and busy_until < now()
  returning true
$$;

create or replace function public.payout_unlock() returns void
language sql security definer set search_path = '' as $$
  update private.payout_state set busy_until = 'epoch' where id = 1
$$;

revoke execute on function public.payout_lock(int), public.payout_unlock() from public, anon, authenticated;
grant execute on function public.payout_lock(int), public.payout_unlock() to service_role;

-- asks the game function to run payouts (the request goes out after the current transaction commits)
create or replace function private.kick_payouts() returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform net.http_post(
    url := 'https://lyuvjhzbcpeazzsvyida.supabase.co/functions/v1/game',
    body := '{"action":"payouts"}'::jsonb,
    headers := '{"Content-Type":"application/json"}'::jsonb,
    timeout_milliseconds := 5000);
exception when others then
  raise warning 'kick_payouts: %', sqlerrm;    -- never let a failed nudge break the withdrawal itself
end $$;
revoke execute on function private.kick_payouts() from public, anon, authenticated;

create or replace function private.withdrawal_kick() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'pending' and new.send_at is null and not new.auto_hold then
    perform private.kick_payouts();
  end if;
  return null;
end $$;
revoke execute on function private.withdrawal_kick() from public, anon, authenticated;

create or replace trigger withdrawal_kick after insert or update of status, auto_hold, send_at on private.withdrawals
  for each row execute function private.withdrawal_kick();

-- safety net: every 15 s, but only while a payout is waiting or in flight (and nobody is working on it right now)
create or replace function private.payouts_tick() returns void
language plpgsql security definer set search_path = '' as $$
declare cfg jsonb; mx numeric; cap numeric; day_sum numeric;
begin
  if (select busy_until from private.payout_state where id = 1) >= now() then return; end if;
  select value into cfg from public.app_config where key = 'wallet';
  if coalesce((cfg->>'auto_payout')::boolean, true) is not true then return; end if;
  mx := coalesce((cfg->>'auto_max')::numeric, 50);
  cap := coalesce((cfg->>'daily_cap')::numeric, 300);
  select coalesce(sum(coalesce(payout, amount)), 0) into day_sum from private.withdrawals where send_at > now() - interval '24 hours';
  -- in flight, or something the function may actually pay (requests above the limits wait for the owner: no calls)
  if exists (select 1 from private.withdrawals where status = 'pending' and not auto_hold
              and (send_at is not null or (coalesce(payout, amount) <= mx and day_sum + coalesce(payout, amount) <= cap))) then
    perform private.kick_payouts();
  end if;
end $$;
revoke execute on function private.payouts_tick() from public, anon, authenticated;

select cron.schedule('cutline-payouts', '15 seconds', 'select private.payouts_tick()');

-- the 15 s job writes a log row per run: keep only the last two days
select cron.schedule('cutline-cron-log-cleanup', '17 3 * * *',
  $$delete from cron.job_run_details where end_time < now() - interval '2 days'$$);
