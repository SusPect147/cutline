-- CUTLINE: only money that went through the game can be withdrawn.
-- wallets.wager_left = how much the player still has to bet in PvP before the rest of the balance can be withdrawn.
--   deposit / task reward  -> wager_left grows by the amount
--   PvP bet                -> wager_left shrinks by the bet (not below 0)
--   always                 -> wager_left never exceeds the balance (money lost in a round is no longer owed)
-- Withdrawable = balance - wager_left. Winnings from a round are withdrawable at once, as soon as the deposits
-- behind them have been bet.

alter table public.wallets add column if not exists wager_left numeric not null default 0 check (wager_left >= 0);

create or replace function private.real_change(p_user uuid, p_delta numeric, p_kind text, p_ref text) returns numeric
language plpgsql security definer set search_path = '' as $$
declare bal numeric;
begin
  update public.wallets set
     balance = balance + p_delta,
     wager_left = least(balance + p_delta, case
       when p_kind in ('deposit', 'reward') then wager_left + p_delta
       when p_kind = 'bet' then greatest(0, wager_left + p_delta)
       else wager_left end)
   where user_id = p_user and balance + p_delta >= 0
   returning balance into bal;
  if not found then raise exception 'no_funds'; end if;
  insert into private.ledger(user_id, kind, amount, ref, balance_after) values (p_user, p_kind, p_delta, p_ref, bal);
  return bal;
end $$;

-- existing players: replay their ledger with the same rule
do $$
declare r record; w numeric := 0; cur uuid := null;
begin
  for r in select user_id, kind, amount, balance_after from private.ledger order by user_id, id loop
    if cur is distinct from r.user_id then
      if cur is not null then update public.wallets set wager_left = least(w, balance) where user_id = cur; end if;
      cur := r.user_id; w := 0;
    end if;
    if r.kind in ('deposit', 'reward') then w := w + r.amount;
    elsif r.kind = 'bet' then w := greatest(0, w + r.amount);
    end if;
    w := least(w, r.balance_after);
  end loop;
  if cur is not null then update public.wallets set wager_left = least(w, balance) where user_id = cur; end if;
end $$;

create or replace function public.request_withdrawal(p_amount numeric, p_address text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); cfg jsonb; a jsonb; wid bigint; addr text; open_n int; v_fee numeric; w public.wallets;
begin
  if uid is null then raise exception 'auth_required'; end if;
  select value into cfg from public.app_config where key = 'wallet';
  addr := btrim(coalesce(p_address, ''));
  if not (addr ~ '^[A-Za-z0-9_-]{48}$' or addr ~ '^(0|-1):[0-9a-fA-F]{64}$') then raise exception 'bad_address'; end if;
  if lower(addr) = lower(cfg->>'address') then raise exception 'bad_address'; end if;
  p_amount := round(p_amount, 2);
  if p_amount is null or p_amount < coalesce((cfg->>'min_withdraw')::numeric, 1) then raise exception 'min_withdraw'; end if;
  v_fee := private.wd_fee(p_amount);
  if p_amount - v_fee <= 0 then raise exception 'min_withdraw'; end if;
  select * into w from public.wallets where user_id = uid for update;
  if not found then raise exception 'tg_required'; end if;
  if w.balance < p_amount then raise exception 'no_funds'; end if;
  if w.balance - w.wager_left < p_amount then raise exception 'not_wagered'; end if;   -- not yet played through
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

-- the player's wallet: also what can be withdrawn, and a longer operations history (the list scrolls)
create or replace function public.my_wallet() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); w public.wallets; cfg jsonb;
begin
  if uid is null then raise exception 'auth_required'; end if;
  select * into w from public.wallets where user_id = uid;
  if not found then raise exception 'tg_required'; end if;
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
        'fun_games', (select count(distinct round_id) from public.bets where user_id = uid and room = 'fun'))),
    'deposits', coalesce((select jsonb_agg(jsonb_build_object('amount', credited, 'at', tx_time, 'status', status) order by tx_time desc)
        from (select * from private.deposits where user_id = uid order by tx_time desc limit 50) d), '[]'),
    'withdrawals', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'amount', amount, 'fee', fee, 'payout', coalesce(payout, amount),
        'address', address, 'status', status, 'at', created_at, 'tx', payout_tx) order by id desc)
        from (select * from private.withdrawals where user_id = uid order by id desc limit 50) x), '[]'),
    'rewards', coalesce((select jsonb_agg(jsonb_build_object('id', quest_id, 'amount', amount, 'at', created_at) order by created_at desc)
        from (select * from private.quest_claims where user_id = uid order by created_at desc limit 50) q), '[]'));
end $$;
