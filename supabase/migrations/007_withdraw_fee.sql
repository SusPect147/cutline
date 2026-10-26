-- CUTLINE: 1% withdrawal fee.
-- The player asks for X: X leaves the balance (the ledger is unchanged), the fee is 1% of X (at least 0.01),
-- and X − fee is what the owner sends. Fee and payout are fixed in the request when it is made.
-- A rejected request refunds the whole X. The rate can be changed with app_config.wallet.wd_fee_pct.

alter table private.withdrawals add column if not exists fee numeric(14,2) not null default 0;
alter table private.withdrawals add column if not exists payout numeric(14,2);

create or replace function private.wd_fee(p_amount numeric) returns numeric
language sql stable security definer set search_path = '' as $$
  select greatest(round(p_amount * coalesce((select (value->>'wd_fee_pct')::numeric from public.app_config where key = 'wallet'), 1) / 100, 2), 0.01)
$$;

create or replace function public.request_withdrawal(p_amount numeric, p_address text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); cfg jsonb; a jsonb; wid bigint; addr text; open_n int; v_fee numeric;
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
  perform 1 from public.wallets where user_id = uid for update;
  select count(*) into open_n from private.withdrawals where user_id = uid and status in ('pending', 'flagged');
  if open_n >= coalesce((cfg->>'max_pending')::int, 3) then raise exception 'too_many_pending'; end if;
  a := private.audit_user(uid);
  if (a->>'balance')::numeric < p_amount then raise exception 'no_funds'; end if;
  if not (a->>'ok')::boolean then
    insert into private.withdrawals(user_id, amount, fee, payout, address, status, audit)
    values (uid, p_amount, v_fee, p_amount - v_fee, addr, 'flagged', a) returning id into wid;
    return jsonb_build_object('id', wid, 'status', 'flagged', 'fee', v_fee, 'payout', p_amount - v_fee);
  end if;
  insert into private.withdrawals(user_id, amount, fee, payout, address, status, audit)
  values (uid, p_amount, v_fee, p_amount - v_fee, addr, 'pending', a) returning id into wid;
  perform private.real_change(uid, -p_amount, 'withdraw', 'wd:' || wid);
  return jsonb_build_object('id', wid, 'status', 'pending', 'fee', v_fee, 'payout', p_amount - v_fee,
    'balance', (select balance from public.wallets where user_id = uid));
end $$;

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
        from (select * from private.deposits where user_id = uid order by tx_time desc limit 10) d), '[]'),
    'withdrawals', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'amount', amount, 'fee', fee, 'payout', coalesce(payout, amount),
        'address', address, 'status', status, 'at', created_at, 'tx', payout_tx) order by id desc)
        from (select * from private.withdrawals where user_id = uid order by id desc limit 10) x), '[]'));
end $$;

create or replace function public.admin_money(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not public.admin_check(coalesce(p_code, '')) then raise exception 'bad_code'; end if;
  return jsonb_build_object(
    'withdrawals', coalesce((select jsonb_agg(x order by x.id) from (
        select w.id, w.amount, w.fee, coalesce(w.payout, w.amount) as payout, w.address, w.status, w.created_at, w.audit, p.name, a.username,
               private.audit_user(w.user_id) as audit_now,
               (select jsonb_agg(jsonb_build_object('hash', d.tx_hash, 'amount', d.credited, 'nano', d.amount_nano, 'from', d.sender, 'at', d.tx_time))
                  from private.deposits d where d.user_id = w.user_id and d.status in ('credited', 'assigned')) as deposits
          from private.withdrawals w join public.profiles p on p.id = w.user_id
          left join private.tg_accounts a on a.user_id = w.user_id
         where w.status in ('pending', 'flagged') limit 100) x), '[]'),
    'unmatched', coalesce((select jsonb_agg(jsonb_build_object('hash', d.tx_hash, 'nano', d.amount_nano, 'from', d.sender, 'comment', d.comment, 'at', d.tx_time,
        'invoice_user', (select i.user_id from private.deposit_invoices i where i.amount_nano = d.amount_nano
                          and i.created_at > d.tx_time - interval '48 hours' and i.created_at <= d.tx_time order by i.id desc limit 1)) order by d.tx_time desc)
        from private.deposits d where d.status = 'unmatched'), '[]'),
    'totals', jsonb_build_object(
        'balances', (select coalesce(sum(balance), 0) from public.wallets),
        'deposited', (select coalesce(sum(credited), 0) from private.deposits where status in ('credited', 'assigned')),
        'paid_out', (select coalesce(sum(coalesce(payout, amount)), 0) from private.withdrawals where status = 'paid'),
        'pending', (select coalesce(sum(coalesce(payout, amount)), 0) from private.withdrawals where status = 'pending'),
        'fees', (select coalesce(sum(fee), 0) from private.house_ledger hl join public.rounds r on r.id = hl.round_id where r.room = 'real'),
        'wd_fees', (select coalesce(sum(fee), 0) from private.withdrawals where status = 'paid')));
end $$;

revoke execute on function private.wd_fee(numeric) from public, anon, authenticated;
revoke execute on function public.request_withdrawal(numeric, text), public.my_wallet() from public, anon;
grant execute on function public.request_withdrawal(numeric, text), public.my_wallet() to authenticated;
revoke execute on function public.admin_money(text) from public;
grant execute on function public.admin_money(text) to anon, authenticated;
