-- CUTLINE: before the launch.
-- * A round is settled only with exactly the bets that are in the database (count and sum are checked).
-- * Per-player request limits inside the game functions; a bet without the money is turned away before any lock.
-- * ForFun is switched off on the server.
-- * Withdrawals above review_over (40) wait for the owner: the bot sends who/what/where with Approve / Reject.
-- * /stop and /resume in the bot switch automatic payouts off and on.
-- * Owner profit payouts go through the same exactly-once payout queue, only up to the money that is not the players'.
-- * The bot ignores a Telegram update it has already handled; at most 3 support tickets an hour per person.
-- * Aggregated statistics (no names, ids or addresses) for the bot's /stats and the owner's local stats page.

-- ---------- request limits ----------
create or replace function private.limit_or_fail(p_key text, p_max int, p_secs int) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if public.rate_hit(p_key, p_max, p_secs) is false then raise exception 'rate_limited'; end if;
end $$;
revoke execute on function private.limit_or_fail(text, int, int) from public, anon, authenticated;

-- ---------- bets: real money only, cheap checks first ----------
create or replace function public.place_bet(p_amount numeric, p_room text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); r public.rounds; n int; already boolean; bal numeric; t jsonb;
begin
  if uid is null then raise exception 'auth_required'; end if;
  if p_room is distinct from 'real' then raise exception 'fun_off'; end if;
  p_amount := round(p_amount, 2);
  if p_amount is null or p_amount < 0.1 or p_amount > 100000000000 then raise exception 'bad_amount'; end if;
  -- not enough money: refused without touching the round (spam of failing bets cannot slow the game down)
  select balance into bal from public.wallets where user_id = uid;
  if bal is null or bal < p_amount then raise exception 'no_funds'; end if;
  perform private.limit_or_fail('bet:' || uid, 6, 2);
  select * into r from public.rounds where status = 'betting' and room = 'real' order by id desc limit 1 for update;
  if not found or now() < r.opens_at then raise exception 'not_open'; end if;
  if r.bets_close_at is not null and now() >= r.bets_close_at then raise exception 'closed'; end if;
  select exists(select 1 from public.bets where round_id = r.id and user_id = uid) into already;
  select count(distinct user_id) into n from public.bets where round_id = r.id;
  if not already and n >= 24 then raise exception 'round_full'; end if;
  bal := private.real_change(uid, -p_amount, 'bet', 'round:' || r.id);
  insert into public.bets(round_id, user_id, amount, room) values (r.id, uid, p_amount, 'real');
  if r.bets_close_at is null and not already and n + 1 >= 2 then
    select value into t from public.app_config where key = 'timing';
    update public.rounds set bets_close_at = now() + make_interval(secs => coalesce((t->>'bet_ms')::int, 15000) / 1000.0)
     where id = r.id;
  end if;
  return jsonb_build_object('balance', bal, 'round', r.id, 'room', 'real');
end $$;

create or replace function public.claim_faucet() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  raise exception 'fun_off';
end $$;

-- ---------- limits on the other player functions ----------
create or replace function public.my_wallet()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); w public.wallets; cfg jsonb;
begin
  if uid is null then raise exception 'auth_required'; end if;
  select * into w from public.wallets where user_id = uid;
  if not found then raise exception 'tg_required'; end if;
  perform private.limit_or_fail('wallet:' || uid, 60, 60);
  select value into cfg from public.app_config where key = 'wallet';
  return jsonb_build_object(
    'balance', w.balance, 'fun_balance', w.fun_balance, 'last_faucet_round', w.last_faucet_round,
    'wager_left', w.wager_left, 'withdrawable', greatest(0, w.balance - w.wager_left),
    'code', private.deposit_code(uid), 'address', cfg->>'address',
    'min_deposit', cfg->'min_deposit', 'min_withdraw', cfg->'min_withdraw', 'support', cfg->>'support',
    'wd_fee_pct', coalesce((cfg->>'wd_fee_pct')::numeric, 1),
    'username', (select username from private.tg_accounts where user_id = uid limit 1),
    'stats', (select jsonb_build_object(
        'games', (select count(distinct round_id) from public.bets where user_id = uid and room = 'real'),
        'wins', (select count(*) from public.rounds where winner_id = uid and room = 'real' and status = 'settled'),
        'best', (select coalesce(max(pot - coalesce(fee, 0)), 0) from public.rounds where winner_id = uid and room = 'real' and status = 'settled'),
        'wagered', (select coalesce(sum(amount), 0) from public.bets where user_id = uid and room = 'real'),
        'fun_games', 0)),
    'deposits', coalesce((select jsonb_agg(jsonb_build_object('amount', credited, 'at', tx_time, 'status', status) order by tx_time desc)
        from (select * from private.deposits where user_id = uid order by tx_time desc limit 50) d), '[]'),
    'withdrawals', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'amount', amount, 'fee', fee, 'payout', coalesce(payout, amount),
        'address', address, 'status', status, 'at', created_at, 'tx', payout_tx) order by id desc)
        from (select * from private.withdrawals where user_id = uid order by id desc limit 50) x), '[]'),
    'rewards', coalesce((select jsonb_agg(jsonb_build_object('id', quest_id, 'amount', amount, 'at', created_at) order by created_at desc)
        from (select * from private.quest_claims where user_id = uid order by created_at desc limit 50) q), '[]'));
end $$;

create or replace function public.request_withdrawal(p_amount numeric, p_address text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); cfg jsonb; a jsonb; wid bigint; addr text; open_n int; v_fee numeric; w public.wallets;
begin
  if uid is null then raise exception 'auth_required'; end if;
  perform private.limit_or_fail('wd:' || uid, 10, 60);
  select value into cfg from public.app_config where key = 'wallet';
  addr := btrim(coalesce(p_address, ''));
  if not (addr ~ '^[A-Za-z0-9_-]{48}$' or addr ~ '^(0|-1):[0-9a-fA-F]{64}$') then raise exception 'bad_address'; end if;
  if lower(addr) = lower(cfg->>'address') then raise exception 'bad_address'; end if;
  p_amount := round(p_amount, 2);
  if p_amount is null or p_amount = 'NaN'::numeric or p_amount < coalesce((cfg->>'min_withdraw')::numeric, 1) or p_amount > 1000000000 then
    raise exception 'min_withdraw';
  end if;
  v_fee := private.wd_fee(p_amount);
  if p_amount - v_fee <= 0 then raise exception 'min_withdraw'; end if;
  select * into w from public.wallets where user_id = uid for update;
  if not found then raise exception 'tg_required'; end if;
  if w.balance < p_amount then raise exception 'no_funds'; end if;
  if w.balance - w.wager_left < p_amount then raise exception 'not_wagered'; end if;
  select count(*) into open_n from private.withdrawals where user_id = uid and status in ('pending', 'flagged');
  if open_n >= coalesce((cfg->>'max_pending')::int, 3) then raise exception 'too_many_pending'; end if;
  a := private.audit_user(uid);
  if not (a->>'ok')::boolean then
    insert into private.withdrawals(user_id, amount, fee, payout, address, status, audit)
    values (uid, p_amount, v_fee, p_amount - v_fee, addr, 'flagged', a) returning id into wid;
    return jsonb_build_object('id', wid, 'status', 'flagged', 'fee', v_fee, 'payout', p_amount - v_fee);
  end if;
  insert into private.withdrawals(user_id, amount, fee, payout, address, status, audit)
  values (uid, p_amount, v_fee, p_amount - v_fee, addr, 'pending', a) returning id into wid;
  perform private.real_change(uid, -p_amount, 'withdraw', 'wd:' || wid);
  return jsonb_build_object('id', wid, 'status', 'pending', 'fee', v_fee, 'payout', p_amount - v_fee,
    'balance', (select balance from public.wallets where user_id = uid),
    'withdrawable', (select balance - wager_left from public.wallets where user_id = uid));
end $$;

create or replace function public.claim_quest(p_id text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'auth_required'; end if;
  perform private.limit_or_fail('quest:' || uid, 20, 60);
  return private.quest_claim(uid, left(coalesce(p_id, ''), 32), false);
end $$;

create or replace function public.my_quests() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); cfg jsonb; code text;
begin
  if uid is null then raise exception 'auth_required'; end if;
  if not exists (select 1 from public.wallets where user_id = uid) then raise exception 'tg_required'; end if;
  perform private.limit_or_fail('quests:' || uid, 60, 60);
  select value into cfg from public.app_config where key = 'quests';
  if cfg is null then return jsonb_build_object('enabled', false, 'list', '[]'::jsonb); end if;
  code := private.ref_code(uid);
  return jsonb_build_object(
    'enabled', coalesce((cfg->>'enabled')::boolean, false), 'channel', cfg->>'channel', 'code', code,
    'link', replace(coalesce(cfg->>'ref_link', ''), '{code}', 'r_' || code),
    'friend_min_deposit', cfg->'friend_min_deposit', 'friend_min_rounds', cfg->'friend_min_rounds',
    'friend_min_wager', coalesce(cfg->'friend_min_wager', '0.2'::jsonb),
    'friends', private.ref_stats(uid), 'progress', private.quest_progress(uid),
    'list', (select coalesce(jsonb_agg(jsonb_build_object('id', q->>'id', 'kind', q->>'kind', 'goal', q->'goal', 'reward', q->'reward',
                       'claimed', exists (select 1 from private.quest_claims c where c.user_id = uid and c.quest_id = q->>'id')) order by ord), '[]')
               from jsonb_array_elements(cfg->'list') with ordinality as t(q, ord)));
end $$;

-- ---------- settling: only with exactly the bets in the database ----------
create or replace function public.settle_round2(p_round bigint, p_entropy text, p_mod text, p_mod_forced boolean, p_winner uuid,
  p_cuts integer, p_result jsonb, p_anim_ms integer, p_bet_count integer, p_pot numeric)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare r public.rounds; v_pot numeric; v_n int; v_stake numeric; v_fee numeric; t jsonb; prep_ms int; result_ms int; s text; nid bigint;
begin
  select value into t from public.app_config where key = 'timing';
  prep_ms := coalesce((t->>'prep_ms')::int, 5000);
  result_ms := coalesce((t->>'result_ms')::int, 5400);
  select * into r from public.rounds where id = p_round for update;
  if not found or r.status <> 'betting' or r.bets_close_at is null or r.bets_close_at > now() then
    return jsonb_build_object('ok', false);
  end if;
  -- the round row is locked and betting is closed, so no bet can be added now: the computed result must use all of them
  select count(*), coalesce(sum(amount), 0) into v_n, v_pot from public.bets where round_id = p_round;
  if p_bet_count is distinct from v_n or p_pot is distinct from v_pot then
    return jsonb_build_object('ok', false, 'reason', 'stale_bets');
  end if;
  if not exists (select 1 from public.bets where round_id = p_round and user_id = p_winner) then raise exception 'bad_winner'; end if;
  if p_anim_ms < 0 or p_anim_ms > 300000 then raise exception 'bad_anim'; end if;
  if r.room = 'real' and p_mod_forced then raise exception 'no_forced_mod_in_real'; end if;
  select coalesce(sum(amount), 0) into v_stake from public.bets where round_id = p_round and user_id = p_winner;
  v_fee := case when r.room = 'real' then public.round_fee_v2(v_pot, v_stake) else null end;
  select seed into s from private.round_secrets where round_id = p_round;
  update public.rounds set
     status = 'settled', seed = s, entropy = p_entropy, mod = p_mod, mod_forced = p_mod_forced,
     winner_id = p_winner, pot = v_pot, fee = v_fee, fee_rule = case when r.room = 'real' then 2 end,
     cuts = p_cuts, result = p_result, settled_at = now(),
     prep_until = now() + make_interval(secs => prep_ms / 1000.0),
     anim_end   = now() + make_interval(secs => (prep_ms + p_anim_ms) / 1000.0),
     ends_at    = now() + make_interval(secs => (prep_ms + p_anim_ms + result_ms) / 1000.0)
   where id = p_round;
  if r.room = 'real' then
    perform private.real_change(p_winner, v_pot - v_fee, 'win', 'round:' || p_round);
    insert into private.house_ledger(round_id, fee) values (p_round, v_fee) on conflict (round_id) do nothing;
  else
    update public.wallets set fun_balance = fun_balance + v_pot where user_id = p_winner;
  end if;
  nid := private.new_round(r.room, now() + make_interval(secs => (prep_ms + p_anim_ms + result_ms) / 1000.0));
  return jsonb_build_object('ok', true, 'next', nid);
end $$;
revoke execute on function public.settle_round2(bigint, text, text, boolean, uuid, integer, jsonb, integer, integer, numeric) from public, anon, authenticated;
grant execute on function public.settle_round2(bigint, text, text, boolean, uuid, integer, jsonb, integer, integer, numeric) to service_role;

-- ---------- withdrawals: owner review above review_over, owner payouts, notifications ----------
alter table private.withdrawals alter column user_id drop not null;
alter table private.withdrawals add column if not exists kind text not null default 'player';
alter table private.withdrawals add column if not exists manual_ok boolean not null default false;
alter table private.withdrawals add column if not exists notified_reason text;
do $$ begin
  alter table private.withdrawals add constraint withdrawals_kind_check
    check ((kind = 'player' and user_id is not null) or (kind = 'owner' and user_id is null));
exception when duplicate_object then null; end $$;

update public.app_config set value = value || jsonb_build_object('review_over', 40, 'owner_reserve', 1) where key = 'wallet';

-- why the owner has to look at a withdrawal right now (null: nothing to do)
create or replace function private.wd_reason(w private.withdrawals) returns text
language sql stable security definer set search_path = '' as $$
  select case
    when w.kind <> 'player' then null
    when w.status = 'flagged' then 'flagged'
    when w.status = 'pending' and w.auto_hold then 'held'
    when w.status = 'pending' and w.send_at is null and not w.manual_ok
         and w.amount > coalesce((select (value->>'review_over')::numeric from public.app_config where key = 'wallet'), 40) then 'review'
    else null end
$$;
revoke execute on function private.wd_reason(private.withdrawals) from public, anon, authenticated;

create or replace function private.kick_bot() returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform net.http_post(
    url := 'https://lyuvjhzbcpeazzsvyida.supabase.co/functions/v1/bot?tick=1',
    body := '{}'::jsonb, headers := '{"Content-Type":"application/json"}'::jsonb, timeout_milliseconds := 5000);
exception when others then
  raise warning 'kick_bot: %', sqlerrm;
end $$;
revoke execute on function private.kick_bot() from public, anon, authenticated;

create or replace function private.withdrawal_kick() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'pending' and new.send_at is null and not new.auto_hold then
    perform private.kick_payouts();
  end if;
  if private.wd_reason(new) is distinct from new.notified_reason and private.wd_reason(new) is not null then
    perform private.kick_bot();
  end if;
  return null;
end $$;
create or replace trigger withdrawal_kick after insert or update of status, auto_hold, send_at, manual_ok on private.withdrawals
  for each row execute function private.withdrawal_kick();

-- backup for the notification (every minute, only calls the bot when there is something new)
create or replace function private.notify_tick() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from private.withdrawals w where w.status in ('pending', 'flagged')
              and private.wd_reason(w) is not null and private.wd_reason(w) is distinct from w.notified_reason) then
    perform private.kick_bot();
  end if;
end $$;
revoke execute on function private.notify_tick() from public, anon, authenticated;
select cron.schedule('cutline-notify', '* * * * *', $$select private.notify_tick()$$);

-- the payout queue: big ones wait for the owner, the owner's approved ones skip the automatic limits
create or replace function public.payout_next() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare cfg jsonb; w private.withdrawals; a jsonb; mx numeric; cap numeric; rv numeric; day_sum numeric;
begin
  select value into cfg from public.app_config where key = 'wallet';
  if coalesce((cfg->>'auto_payout')::boolean, true) is not true then return null; end if;
  mx := coalesce((cfg->>'auto_max')::numeric, 50);
  cap := coalesce((cfg->>'daily_cap')::numeric, 300);
  rv := coalesce((cfg->>'review_over')::numeric, 40);
  select coalesce(sum(coalesce(payout, amount)), 0) into day_sum from private.withdrawals
   where send_at > now() - interval '24 hours' and kind = 'player';
  for w in select * from private.withdrawals
            where status = 'pending' and send_at is null and not auto_hold
            order by id loop
    if not w.manual_ok then
      if w.amount > rv or coalesce(w.payout, w.amount) > mx then continue; end if;   -- waits for the owner
      if day_sum + coalesce(w.payout, w.amount) > cap then continue; end if;
    end if;
    if w.kind = 'owner' then
      return jsonb_build_object('id', w.id, 'address', w.address, 'nano', (coalesce(w.payout, w.amount) * 1000000000)::bigint::text, 'deposits', '[]'::jsonb);
    end if;
    a := private.audit_user(w.user_id);
    if not (a->>'ok')::boolean then
      update private.withdrawals set auto_hold = true, admin_note = 'auto: balance does not reconcile' where id = w.id;
      continue;
    end if;
    return jsonb_build_object('id', w.id, 'address', w.address, 'nano', (coalesce(w.payout, w.amount) * 1000000000)::bigint::text,
      'deposits', coalesce((select jsonb_agg(d.tx_hash) from private.deposits d where d.user_id = w.user_id and d.status = 'credited'), '[]'));
  end loop;
  return null;
end $$;

create or replace function public.payout_has_work() returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare cfg jsonb; mx numeric; cap numeric; rv numeric; day_sum numeric;
begin
  select value into cfg from public.app_config where key = 'wallet';
  if coalesce((cfg->>'auto_payout')::boolean, true) is not true then return false; end if;
  mx := coalesce((cfg->>'auto_max')::numeric, 50);
  cap := coalesce((cfg->>'daily_cap')::numeric, 300);
  rv := coalesce((cfg->>'review_over')::numeric, 40);
  select coalesce(sum(coalesce(payout, amount)), 0) into day_sum from private.withdrawals where send_at > now() - interval '24 hours' and kind = 'player';
  return exists (select 1 from private.withdrawals where status = 'pending' and not auto_hold
                  and (send_at is not null or manual_ok
                       or (amount <= rv and coalesce(payout, amount) <= mx and day_sum + coalesce(payout, amount) <= cap)));
end $$;

create or replace function private.payouts_tick() returns void
language plpgsql security definer set search_path = '' as $$
begin
  if (select busy_until from private.payout_state where id = 1) >= now() then return; end if;
  if public.payout_has_work() then perform private.kick_payouts(); end if;
end $$;

-- money that belongs to players right now (balances, withdrawals not yet paid, bets in rounds not yet settled)
create or replace function private.obligations() returns numeric
language sql stable security definer set search_path = '' as $$
  select (select coalesce(sum(balance), 0) from public.wallets)
       + (select coalesce(sum(coalesce(payout, amount)), 0) from private.withdrawals where status = 'pending')
       + (select coalesce(sum(b.amount), 0) from public.bets b join public.rounds r on r.id = b.round_id
           where b.room = 'real' and r.status <> 'settled')
       -- transfers that arrived without a code: someone's money until support assigns or returns it
       + (select coalesce(sum(amount_nano), 0) / 1000000000 from private.deposits where status = 'unmatched')
$$;
revoke execute on function private.obligations() from public, anon, authenticated;

-- ---------- functions for the bot (service role only) ----------
create or replace function public.admin_wd_todo() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(x order by (x->>'id')::bigint), '[]') from (
    select jsonb_build_object('id', w.id, 'reason', private.wd_reason(w), 'amount', w.amount, 'fee', w.fee, 'payout', coalesce(w.payout, w.amount),
      'address', w.address, 'status', w.status, 'note', w.admin_note, 'at', w.created_at,
      'tg_id', a.tg_id, 'username', a.username, 'name', p.name,
      'deposited', (select coalesce(sum(credited), 0) from private.deposits d where d.user_id = w.user_id and d.status in ('credited', 'assigned')),
      'wagered', (select coalesce(sum(amount), 0) from public.bets b where b.user_id = w.user_id and b.room = 'real'),
      'won', (select coalesce(sum(r.pot - coalesce(r.fee, 0)), 0) from public.rounds r where r.winner_id = w.user_id and r.room = 'real' and r.status = 'settled'),
      'withdrawn', (select coalesce(sum(amount), 0) from private.withdrawals o where o.user_id = w.user_id and o.status = 'paid'),
      'audit_ok', coalesce((w.audit->>'ok')::boolean, true)) x
      from private.withdrawals w
      left join private.tg_accounts a on a.user_id = w.user_id
      left join public.profiles p on p.id = w.user_id
     where w.status in ('pending', 'flagged') and private.wd_reason(w) is not null
       and private.wd_reason(w) is distinct from w.notified_reason
     limit 20) s
$$;

create or replace function public.admin_wd_mark(p_id bigint, p_reason text) returns void
language sql security definer set search_path = '' as $$
  update private.withdrawals set notified_reason = p_reason where id = p_id;
$$;

create or replace function public.admin_wd_approve(p_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare w private.withdrawals;
begin
  select * into w from private.withdrawals where id = p_id for update;
  if not found or w.kind <> 'player' then raise exception 'not_found'; end if;
  if w.status = 'flagged' then
    perform private.wd_approve(p_id);              -- takes the money from the balance now
  elsif not (w.status = 'pending' and w.send_at is null) then
    raise exception 'not_open';
  end if;
  update private.withdrawals set manual_ok = true, auto_hold = false, notified_reason = null,
         admin_note = coalesce(admin_note || '; ', '') || 'approved by owner' where id = p_id;
  return jsonb_build_object('id', p_id, 'status', 'pending', 'payout', coalesce(w.payout, w.amount));
end $$;

create or replace function public.admin_wd_reject(p_id bigint) returns text
language plpgsql security definer set search_path = '' as $$
declare w private.withdrawals;
begin
  select * into w from private.withdrawals where id = p_id;
  if not found or w.kind <> 'player' then raise exception 'not_found'; end if;
  return private.wd_reject(p_id, 'rejected by owner');
end $$;

create or replace function public.admin_set_paused(p_paused boolean) returns boolean
language sql security definer set search_path = '' as $$
  update public.app_config set value = value || jsonb_build_object('auto_payout', not p_paused) where key = 'wallet'
  returning not (value->>'auto_payout')::boolean
$$;

-- the owner's profit: never more than the wallet holds above the players' money and the reserve
create or replace function public.owner_payout_create(p_amount numeric, p_chain_nano numeric) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare cfg jsonb; addr text; reserve numeric; obl numeric; avail numeric; amt numeric; wid bigint;
begin
  select value into cfg from public.app_config where key = 'wallet';
  addr := btrim(coalesce(cfg->>'owner_address', ''));
  if not (addr ~ '^[A-Za-z0-9_-]{48}$' or addr ~ '^(0|-1):[0-9a-fA-F]{64}$') then raise exception 'no_owner_address'; end if;
  if lower(addr) = lower(cfg->>'address') then raise exception 'no_owner_address'; end if;
  perform pg_advisory_xact_lock(hashtext('cutline.owner_payout'));
  if exists (select 1 from private.withdrawals where kind = 'owner' and status = 'pending') then raise exception 'owner_pending'; end if;
  reserve := coalesce((cfg->>'owner_reserve')::numeric, 1);
  obl := private.obligations();
  avail := floor(((p_chain_nano / 1000000000) - obl - reserve) * 100) / 100;
  amt := round(coalesce(p_amount, avail), 2);
  if amt is null or amt < 0.1 or amt > avail then raise exception 'not_available'; end if;
  insert into private.withdrawals(user_id, kind, amount, fee, payout, address, status, audit, manual_ok, admin_note)
  values (null, 'owner', amt, 0, amt, addr, 'pending', '{}'::jsonb, true, 'owner profit') returning id into wid;
  return jsonb_build_object('id', wid, 'amount', amt, 'address', addr, 'available', avail);
end $$;

create or replace function public.admin_wd_get(p_id bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', w.id, 'kind', w.kind, 'amount', w.amount, 'payout', coalesce(w.payout, w.amount), 'address', w.address,
    'status', w.status, 'held', w.auto_hold, 'sent', w.send_at is not null, 'tx', w.payout_tx, 'tg_id', a.tg_id, 'username', a.username)
    from private.withdrawals w left join private.tg_accounts a on a.user_id = w.user_id where w.id = p_id
$$;

-- ---------- bot: each Telegram update once; support tickets limited ----------
create table if not exists private.tg_updates (update_id bigint primary key, at timestamptz not null default now());
alter table private.tg_updates enable row level security;
create or replace function public.bot_seen(p_update_id bigint) returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  insert into private.tg_updates(update_id) values (p_update_id) on conflict do nothing;
  return not found;          -- true: this update was handled before
end $$;
select cron.schedule('cutline-tg-updates-cleanup', '53 3 * * *', $$delete from private.tg_updates where at < now() - interval '2 days'$$);

create or replace function public.support_take(p_tg_id bigint, p_group text, p_lang text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s private.support_sessions; tid bigint; am bigint;
begin
  select * into s from private.support_sessions where tg_id = p_tg_id for update;
  if not found or s.until < now() then
    delete from private.support_sessions where tg_id = p_tg_id;
    return jsonb_build_object('state', 'none');
  end if;
  if s.ticket_id is not null then
    if p_group is not null and p_group = s.media_group then
      select admin_msg into am from private.support_tickets where id = s.ticket_id;
      return jsonb_build_object('state', 'album', 'id', s.ticket_id, 'admin_msg', am);
    end if;
    delete from private.support_sessions where tg_id = p_tg_id;
    return jsonb_build_object('state', 'none');
  end if;
  if (select count(*) from private.support_tickets where tg_id = p_tg_id and created_at > now() - interval '1 hour') >= 3 then
    delete from private.support_sessions where tg_id = p_tg_id;
    return jsonb_build_object('state', 'limited');
  end if;
  insert into private.support_tickets(tg_id, lang) values (p_tg_id, case when p_lang = 'ru' then 'ru' else 'en' end) returning id into tid;
  if p_group is null then
    delete from private.support_sessions where tg_id = p_tg_id;
  else
    update private.support_sessions set ticket_id = tid, media_group = p_group, until = now() + interval '1 minute' where tg_id = p_tg_id;
  end if;
  return jsonb_build_object('state', 'new', 'id', tid);
end $$;

-- ---------- statistics: totals only, nothing that identifies a player ----------
create or replace function public.stats_summary() returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare tz text := 'Europe/Moscow'; d0 timestamptz; d7 timestamptz; d30 timestamptz; res jsonb; cfg jsonb;
begin
  d0 := date_trunc('day', now() at time zone tz) at time zone tz;
  d7 := d0 - interval '6 days';
  d30 := d0 - interval '29 days';
  select value into cfg from public.app_config where key = 'wallet';
  with
  rr as (select r.id, r.pot, coalesce(r.fee, 0) fee, r.settled_at from public.rounds r where r.room = 'real' and r.status = 'settled'),
  rb as (select b.user_id, b.amount, b.created_at from public.bets b join public.rounds r on r.id = b.round_id where b.room = 'real' and r.status = 'settled'),
  dep as (select user_id, credited, tx_time from private.deposits where status in ('credited', 'assigned')),
  wdp as (select amount, fee, coalesce(payout, amount) payout, decided_at at_ from private.withdrawals where kind = 'player' and status = 'paid'),
  rew as (select amount, created_at from private.quest_claims),
  pl as (select p.id, p.created_at from public.profiles p join public.wallets w on w.user_id = p.id where not p.is_bot)
  select jsonb_build_object(
    'generated_at', now(), 'tz', tz, 'paused', coalesce((cfg->>'auto_payout')::boolean, true) is not true,
    'players', jsonb_build_object(
      'total', (select count(*) from pl), 'today', (select count(*) from pl where created_at >= d0), 'week', (select count(*) from pl where created_at >= d7),
      'paying', (select count(distinct user_id) from dep),
      'active_today', (select count(distinct user_id) from rb where created_at >= d0), 'active_week', (select count(distinct user_id) from rb where created_at >= d7)),
    'rounds', jsonb_build_object(
      'total', (select count(*) from rr), 'today', (select count(*) from rr where settled_at >= d0), 'week', (select count(*) from rr where settled_at >= d7),
      'bets', (select count(*) from rb), 'avg_pot', (select coalesce(round(avg(pot), 2), 0) from rr), 'max_pot', (select coalesce(max(pot), 0) from rr)),
    'wagered', jsonb_build_object('total', (select coalesce(sum(amount), 0) from rb), 'today', (select coalesce(sum(amount), 0) from rb where created_at >= d0),
      'week', (select coalesce(sum(amount), 0) from rb where created_at >= d7)),
    'income', jsonb_build_object(
      'round_fees', jsonb_build_object('total', (select coalesce(sum(fee), 0) from rr), 'today', (select coalesce(sum(fee), 0) from rr where settled_at >= d0),
                                       'week', (select coalesce(sum(fee), 0) from rr where settled_at >= d7)),
      'withdraw_fees', jsonb_build_object('total', (select coalesce(sum(fee), 0) from wdp), 'today', (select coalesce(sum(fee), 0) from wdp where at_ >= d0),
                                       'week', (select coalesce(sum(fee), 0) from wdp where at_ >= d7)),
      'rewards', jsonb_build_object('total', (select coalesce(sum(amount), 0) from rew), 'today', (select coalesce(sum(amount), 0) from rew where created_at >= d0),
                                       'week', (select coalesce(sum(amount), 0) from rew where created_at >= d7))),
    'deposits', jsonb_build_object('total', (select coalesce(sum(credited), 0) from dep), 'count', (select count(*) from dep),
      'today', (select coalesce(sum(credited), 0) from dep where tx_time >= d0), 'week', (select coalesce(sum(credited), 0) from dep where tx_time >= d7),
      'unmatched', (select count(*) from private.deposits where status = 'unmatched')),
    'withdrawals', jsonb_build_object('paid_total', (select coalesce(sum(payout), 0) from wdp), 'paid_count', (select count(*) from wdp),
      'today', (select coalesce(sum(payout), 0) from wdp where at_ >= d0), 'week', (select coalesce(sum(payout), 0) from wdp where at_ >= d7),
      'pending_count', (select count(*) from private.withdrawals where kind = 'player' and status = 'pending'),
      'pending_sum', (select coalesce(sum(coalesce(payout, amount)), 0) from private.withdrawals where kind = 'player' and status = 'pending'),
      'waiting_owner', (select count(*) from private.withdrawals w where w.status in ('pending', 'flagged') and private.wd_reason(w) is not null),
      'owner_paid', (select coalesce(sum(amount), 0) from private.withdrawals where kind = 'owner' and status = 'paid')),
    'obligations', private.obligations(),
    'daily', (select coalesce(jsonb_agg(jsonb_build_object(
        'day', to_char(d, 'YYYY-MM-DD'),
        'rounds', (select count(*) from rr where settled_at >= d and settled_at < d + interval '1 day'),
        'wagered', (select coalesce(sum(amount), 0) from rb where created_at >= d and created_at < d + interval '1 day'),
        'fees', (select coalesce(sum(fee), 0) from rr where settled_at >= d and settled_at < d + interval '1 day')
              + (select coalesce(sum(fee), 0) from wdp where at_ >= d and at_ < d + interval '1 day'),
        'rewards', (select coalesce(sum(amount), 0) from rew where created_at >= d and created_at < d + interval '1 day'),
        'deposits', (select coalesce(sum(credited), 0) from dep where tx_time >= d and tx_time < d + interval '1 day'),
        'withdrawals', (select coalesce(sum(payout), 0) from wdp where at_ >= d and at_ < d + interval '1 day'),
        'players_new', (select count(*) from pl where created_at >= d and created_at < d + interval '1 day'),
        'players_active', (select count(distinct user_id) from rb where created_at >= d and created_at < d + interval '1 day')) order by d), '[]')
      from generate_series(d30, d0, interval '1 day') as g(d))
  ) into res;
  return res || jsonb_build_object('profit', jsonb_build_object(
    'total', (res#>>'{income,round_fees,total}')::numeric + (res#>>'{income,withdraw_fees,total}')::numeric - (res#>>'{income,rewards,total}')::numeric,
    'today', (res#>>'{income,round_fees,today}')::numeric + (res#>>'{income,withdraw_fees,today}')::numeric - (res#>>'{income,rewards,today}')::numeric,
    'week', (res#>>'{income,round_fees,week}')::numeric + (res#>>'{income,withdraw_fees,week}')::numeric - (res#>>'{income,rewards,week}')::numeric));
end $$;

do $$
declare f text;
begin
  foreach f in array array['admin_wd_todo()', 'admin_wd_mark(bigint, text)', 'admin_wd_approve(bigint)', 'admin_wd_reject(bigint)',
    'admin_set_paused(boolean)', 'owner_payout_create(numeric, numeric)', 'admin_wd_get(bigint)', 'bot_seen(bigint)',
    'support_take(bigint, text, text)', 'stats_summary()', 'payout_next()', 'payout_has_work()'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;

-- ---------- the owner's local statistics page: only the key's SHA-256 is stored, the key itself is only on the owner's PC ----------
insert into private.admin_config(key, value) values ('stats_key_sha256', '47aa91a39c1faeb0a67e5e41bb62747e337eb0bed9c642263eb7c54b134be2cf')
on conflict (key) do update set value = excluded.value;
create or replace function public.stats_key_ok(p_hash text) returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select value from private.admin_config where key = 'stats_key_sha256') = lower(p_hash), false)
$$;
revoke execute on function public.stats_key_ok(text) from public, anon, authenticated;
grant execute on function public.stats_key_ok(text) to service_role;
