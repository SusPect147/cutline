-- CUTLINE: real Gram balances (deposits to the house wallet, manual withdrawals) and a separate ForFun room.
--
-- Money rules:
--   * The real balance (wallets.balance) changes ONLY through private.real_change(), which also writes a
--     row into private.ledger. So at any moment: wallets.balance == sum(ledger.amount) for that user.
--   * Deposits are credited only by the `game` edge function after it has checked the transaction on chain
--     (credit_deposit, service role only). A transaction hash can be credited once (primary key).
--   * A withdrawal is a request. Before it is accepted, the player's balance is reconciled against deposits,
--     bets, wins, withdrawals and refunds. Any mismatch -> the request is stored as 'flagged' with the full
--     snapshot, nothing is debited, and support looks into it. Payouts are made by hand by the owner.
--   * ForFun uses wallets.fun_balance (test money, free top-ups). The two never mix.

-- ---------- rooms ----------
alter table public.rounds add column if not exists room text not null default 'fun';
alter table public.bets   add column if not exists room text not null default 'fun';
do $$ begin
  alter table public.rounds add constraint rounds_room_chk check (room in ('real', 'fun'));
  alter table public.bets   add constraint bets_room_chk   check (room in ('real', 'fun'));
exception when duplicate_object then null; end $$;
create index if not exists rounds_room_idx on public.rounds(room, status, id desc);

-- ---------- balances: everything so far was test money ----------
alter table public.wallets add column if not exists fun_balance numeric(14,2) not null default 10;
do $$ begin
  alter table public.wallets add constraint wallets_fun_nonneg check (fun_balance >= 0);
exception when duplicate_object then null; end $$;
alter table public.wallets alter column balance set default 0;
update public.wallets w set
  fun_balance = case when p.is_bot then 1000000000 else 10 end,
  balance = 0
from public.profiles p where p.id = w.user_id;

alter table private.tg_accounts add column if not exists username text;

-- ---------- public settings ----------
insert into public.app_config(key, value) values ('wallet', jsonb_build_object(
  'address', 'UQBPHPJsnXJut6zzXtrVdUbUwga5F8_KfBn0fK8G4U7D_H_U',
  'min_deposit', 0.1, 'min_withdraw', 1, 'max_pending', 3,
  'support', 'https://t.me/hammer147'))
on conflict (key) do update set value = excluded.value;

-- ---------- money tables (private: only these functions touch them) ----------
create table if not exists private.ledger (
  id             bigint generated always as identity primary key,
  user_id        uuid not null references public.profiles(id) on delete cascade,
  kind           text not null check (kind in ('deposit', 'bet', 'win', 'withdraw', 'refund', 'adjust')),
  amount         numeric(14,2) not null,
  ref            text,
  balance_after  numeric(14,2) not null,
  created_at     timestamptz not null default now()
);
create index if not exists ledger_user_idx on private.ledger(user_id, id);

create table if not exists private.deposit_codes (
  user_id  uuid primary key references public.profiles(id) on delete cascade,
  code     text not null unique
);

create table if not exists private.deposits (
  tx_hash      text primary key,
  lt           bigint not null,
  user_id      uuid references public.profiles(id),
  sender       text not null,
  amount_nano  numeric(30,0) not null,
  credited     numeric(14,2) not null default 0,
  comment      text,
  status       text not null check (status in ('credited', 'unmatched', 'ignored', 'assigned')),
  tx_time      timestamptz not null,
  created_at   timestamptz not null default now()
);
create index if not exists deposits_user_idx on private.deposits(user_id, tx_time desc);

create table if not exists private.withdrawals (
  id          bigint generated always as identity primary key,
  user_id     uuid not null references public.profiles(id),
  amount      numeric(14,2) not null check (amount > 0),
  address     text not null,
  status      text not null check (status in ('pending', 'paid', 'rejected', 'flagged', 'cancelled')),
  audit       jsonb not null,
  admin_note  text,
  payout_tx   text,
  created_at  timestamptz not null default now(),
  decided_at  timestamptz
);
create index if not exists withdrawals_user_idx on private.withdrawals(user_id, id desc);
create index if not exists withdrawals_status_idx on private.withdrawals(status, id);

create table if not exists private.scan_state (
  id         int primary key default 1 check (id = 1),
  last_scan  timestamptz not null default 'epoch'
);
insert into private.scan_state(id) values (1) on conflict do nothing;

alter table private.ledger        enable row level security;
alter table private.deposit_codes enable row level security;
alter table private.deposits      enable row level security;
alter table private.withdrawals   enable row level security;
alter table private.scan_state    enable row level security;

-- ---------- the only way the real balance moves ----------
create or replace function private.real_change(p_user uuid, p_delta numeric, p_kind text, p_ref text) returns numeric
language plpgsql security definer set search_path = '' as $$
declare bal numeric;
begin
  update public.wallets set balance = balance + p_delta
   where user_id = p_user and balance + p_delta >= 0
   returning balance into bal;
  if not found then raise exception 'no_funds'; end if;
  insert into private.ledger(user_id, kind, amount, ref, balance_after) values (p_user, p_kind, p_delta, p_ref, bal);
  return bal;
end $$;

-- the full reconciliation of one player's real balance
create or replace function private.audit_user(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare a jsonb; bal numeric; l_sum numeric; l_dep numeric; l_bet numeric; l_win numeric; l_wd numeric; l_ref numeric; l_adj numeric;
  dep numeric; bets numeric; wins numeric; wd_open numeric; refunded numeric; chain_ok boolean;
begin
  select balance into bal from public.wallets where user_id = p_user;
  select coalesce(sum(amount), 0),
         coalesce(sum(amount) filter (where kind = 'deposit'), 0), coalesce(sum(amount) filter (where kind = 'bet'), 0),
         coalesce(sum(amount) filter (where kind = 'win'), 0),     coalesce(sum(amount) filter (where kind = 'withdraw'), 0),
         coalesce(sum(amount) filter (where kind = 'refund'), 0),  coalesce(sum(amount) filter (where kind = 'adjust'), 0)
    into l_sum, l_dep, l_bet, l_win, l_wd, l_ref, l_adj
    from private.ledger where user_id = p_user;
  select coalesce(sum(credited), 0) into dep from private.deposits where user_id = p_user and status in ('credited', 'assigned');
  select coalesce(sum(amount), 0) into bets from public.bets where user_id = p_user and room = 'real';
  select coalesce(sum(r.pot - coalesce(r.fee, 0)), 0) into wins from public.rounds r
   where r.winner_id = p_user and r.room = 'real' and r.status = 'settled';
  select coalesce(sum(amount), 0) into wd_open from private.withdrawals where user_id = p_user and status in ('pending', 'paid', 'rejected');
  select coalesce(sum(amount), 0) into refunded from private.withdrawals where user_id = p_user and status = 'rejected';
  -- every ledger row must continue the previous one
  select coalesce(bool_and(ok), true) into chain_ok from (
    select balance_after = coalesce(lag(balance_after) over (order by id), 0) + amount as ok
      from private.ledger where user_id = p_user) c;
  a := jsonb_build_object(
    'balance', bal, 'ledger_sum', l_sum, 'chain_ok', chain_ok,
    'deposits', dep, 'ledger_deposits', l_dep,
    'bets', bets, 'ledger_bets', -l_bet,
    'wins', wins, 'ledger_wins', l_win,
    'withdrawn', wd_open, 'ledger_withdrawn', -l_wd,
    'refunded', refunded, 'ledger_refunds', l_ref, 'adjustments', l_adj);
  return a || jsonb_build_object('ok',
        bal = l_sum and chain_ok and dep = l_dep and bets = -l_bet and wins = l_win
    and wd_open = -l_wd and refunded = l_ref and l_adj = 0);
end $$;

-- ---------- rounds per room ----------
create or replace function private.new_round(p_room text, p_opens_at timestamptz) returns bigint
language plpgsql security definer set search_path = '' as $$
declare s text := encode(extensions.gen_random_bytes(12), 'hex'); rid bigint;
begin
  insert into public.rounds(seed_hash, opens_at, room)
  values (encode(extensions.digest(s, 'sha256'), 'hex'), p_opens_at, p_room) returning id into rid;
  insert into private.round_secrets(round_id, seed) values (rid, s);
  return rid;
end $$;

create or replace function public.place_bet(p_amount numeric, p_room text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); r public.rounds; n int; already boolean; bal numeric; t jsonb;
begin
  if uid is null then raise exception 'auth_required'; end if;
  if p_room is null or p_room not in ('real', 'fun') then raise exception 'bad_room'; end if;
  p_amount := round(p_amount, 2);
  if p_amount is null or p_amount < 0.1 or p_amount > 100000000000 then raise exception 'bad_amount'; end if;
  select * into r from public.rounds where status = 'betting' and room = p_room order by id desc limit 1 for update;
  if not found or now() < r.opens_at then raise exception 'not_open'; end if;
  if r.bets_close_at is not null and now() >= r.bets_close_at then raise exception 'closed'; end if;
  select exists(select 1 from public.bets where round_id = r.id and user_id = uid) into already;
  select count(distinct user_id) into n from public.bets where round_id = r.id;
  if not already and n >= 24 then raise exception 'round_full'; end if;
  if p_room = 'real' then
    bal := private.real_change(uid, -p_amount, 'bet', 'round:' || r.id);
  else
    update public.wallets set fun_balance = fun_balance - p_amount
     where user_id = uid and fun_balance >= p_amount returning fun_balance into bal;
    if not found then raise exception 'no_funds'; end if;
  end if;
  insert into public.bets(round_id, user_id, amount, room) values (r.id, uid, p_amount, p_room);
  if r.bets_close_at is null and not already and n + 1 >= 2 then
    select value into t from public.app_config where key = 'timing';
    update public.rounds set bets_close_at = now() + make_interval(secs => coalesce((t->>'bet_ms')::int, 15000) / 1000.0)
     where id = r.id;
  end if;
  return jsonb_build_object('balance', bal, 'round', r.id, 'room', p_room);
end $$;

-- older clients only know one argument: they play with test money
create or replace function public.place_bet(p_amount numeric) returns jsonb
language sql security definer set search_path = '' as $$ select public.place_bet(p_amount, 'fun') $$;

create or replace function public.claim_faucet() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); rid bigint; amt numeric; bal numeric;
begin
  if uid is null then raise exception 'auth_required'; end if;
  select id into rid from public.rounds where room = 'fun' order by id desc limit 1;
  amt := round((10 + random() * 90)::numeric, 1);
  update public.wallets set fun_balance = fun_balance + amt, last_faucet_round = rid
   where user_id = uid and last_faucet_round is distinct from rid returning fun_balance into bal;
  if not found then raise exception 'faucet_used'; end if;
  return jsonb_build_object('amount', amt, 'balance', bal, 'round', rid);
end $$;

create or replace function public.settle_round(p_round bigint, p_entropy text, p_mod text, p_mod_forced boolean,
  p_winner uuid, p_cuts int, p_result jsonb, p_anim_ms int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r public.rounds; v_pot numeric; v_stake numeric; v_fee numeric; t jsonb; prep_ms int; result_ms int; s text; nid bigint;
begin
  select value into t from public.app_config where key = 'timing';
  prep_ms := coalesce((t->>'prep_ms')::int, 5000);
  result_ms := coalesce((t->>'result_ms')::int, 5400);
  select * into r from public.rounds where id = p_round for update;
  if not found or r.status <> 'betting' or r.bets_close_at is null or r.bets_close_at > now() then
    return jsonb_build_object('ok', false);
  end if;
  if not exists (select 1 from public.bets where round_id = p_round and user_id = p_winner) then
    raise exception 'bad_winner';
  end if;
  if p_anim_ms < 0 or p_anim_ms > 300000 then raise exception 'bad_anim'; end if;
  if r.room = 'real' and p_mod_forced then raise exception 'no_forced_mod_in_real'; end if;
  select coalesce(sum(amount), 0) into v_pot from public.bets where round_id = p_round;
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
    if p_mod_forced then delete from private.admin_config where key = 'next_mod'; end if;
  end if;
  nid := private.new_round(r.room, now() + make_interval(secs => (prep_ms + p_anim_ms + result_ms) / 1000.0));
  return jsonb_build_object('ok', true, 'next', nid);
end $$;

-- the admin's forced modifier applies to ForFun only; real rounds always get the random one
create or replace function public.get_round_secret(p_round bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s text; nm text; rm text;
begin
  select seed into s from private.round_secrets where round_id = p_round;
  select room into rm from public.rounds where id = p_round;
  select value into nm from private.admin_config where key = 'next_mod';
  return jsonb_build_object('seed', s, 'forced_mod', case when rm = 'real' then null else nm end);
end $$;

-- test tools touch ForFun only
create or replace function public.admin_bot_bet(p_bot uuid, p_amount numeric) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.rounds; n int; already boolean; t jsonb;
begin
  if not exists (select 1 from public.profiles where id = p_bot and is_bot) then raise exception 'not_bot'; end if;
  select * into r from public.rounds where status = 'betting' and room = 'fun' order by id desc limit 1 for update;
  if not found or now() < r.opens_at or (r.bets_close_at is not null and now() >= r.bets_close_at) then raise exception 'not_open'; end if;
  select exists(select 1 from public.bets where round_id = r.id and user_id = p_bot) into already;
  select count(distinct user_id) into n from public.bets where round_id = r.id;
  if not already and n >= 24 then raise exception 'round_full'; end if;
  update public.wallets set fun_balance = fun_balance - p_amount where user_id = p_bot and fun_balance >= p_amount;
  if not found then raise exception 'no_funds'; end if;
  insert into public.bets(round_id, user_id, amount, room) values (r.id, p_bot, round(p_amount, 2), 'fun');
  if r.bets_close_at is null and not already and n + 1 >= 2 then
    select value into t from public.app_config where key = 'timing';
    update public.rounds set bets_close_at = now() + make_interval(secs => coalesce((t->>'bet_ms')::int, 15000) / 1000.0) where id = r.id;
  end if;
end $$;

create or replace function public.admin_skip() returns void
language plpgsql security definer set search_path = '' as $$
declare s public.rounds; o public.rounds;
begin
  select * into o from public.rounds where status = 'betting' and room = 'fun' order by id desc limit 1 for update;
  if found and now() >= o.opens_at then
    if (select count(distinct user_id) from public.bets where round_id = o.id) >= 2 then
      update public.rounds set bets_close_at = now() where id = o.id;
    end if;
    return;
  end if;
  select * into s from public.rounds where status = 'settled' and room = 'fun' order by id desc limit 1;
  if found and s.ends_at > now() then
    update public.rounds set ends_at = now(), anim_end = least(anim_end, now()), prep_until = least(prep_until, now()) where id = s.id;
    update public.rounds set opens_at = now() where id = o.id;
  end if;
end $$;

-- ---------- sign-in: profile + both balances ----------
create or replace function public.tg_login_profile(p_user uuid, p_tg_id bigint, p_name text, p_avatar text, p_photo_uid text, p_username text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare nm text; av text; un text; w public.wallets;
begin
  nm := left(btrim(regexp_replace(coalesce(p_name, ''), '[\r\n\t<>\u200e\u200f\u202a-\u202e\u2066-\u2069]', '', 'g')), 24);
  if char_length(nm) = 0 then nm := 'Player'; end if;
  un := case when p_username ~ '^[A-Za-z0-9_]{3,32}$' then p_username end;
  av := case when p_avatar ~ '^https://(lyuvjhzbcpeazzsvyida\.supabase\.co/storage/v1/object/public/avatars/|api\.dicebear\.com/|t\.me/)'
              and char_length(p_avatar) < 400 then p_avatar else null end;
  insert into public.profiles(id, name, avatar_url) values (p_user, nm, av)
  on conflict (id) do update set name = excluded.name, avatar_url = coalesce(excluded.avatar_url, public.profiles.avatar_url);
  insert into private.tg_accounts(tg_id, user_id, photo_uid, username) values (p_tg_id, p_user, p_photo_uid, un)
  on conflict (tg_id) do update set photo_uid = coalesce(excluded.photo_uid, private.tg_accounts.photo_uid),
    username = excluded.username, updated_at = now();
  insert into public.wallets(user_id, balance, fun_balance) values (p_user, 0, 10) on conflict (user_id) do nothing;
  select * into w from public.wallets where user_id = p_user;
  return jsonb_build_object('balance', w.balance, 'fun_balance', w.fun_balance, 'last_faucet_round', w.last_faucet_round,
    'name', nm, 'username', un, 'avatar_url', (select avatar_url from public.profiles where id = p_user));
end $$;

-- the previous sign-in function (still used until the new edge function is live) must not hand out real money
create or replace function public.tg_upsert_profile(p_user uuid, p_tg_id bigint, p_name text, p_avatar text, p_photo_uid text)
returns jsonb
language sql security definer set search_path = '' as $$
  select public.tg_login_profile(p_user, p_tg_id, p_name, p_avatar, p_photo_uid, null)
$$;
revoke execute on function public.tg_upsert_profile(uuid, bigint, text, text, text) from public, anon, authenticated;
grant execute on function public.tg_upsert_profile(uuid, bigint, text, text, text) to service_role;

-- ---------- deposits ----------
create or replace function private.deposit_code(p_user uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare c text;
begin
  select code into c from private.deposit_codes where user_id = p_user;
  if c is null then
    loop
      c := 'CUT' || upper(encode(extensions.gen_random_bytes(4), 'hex'));
      begin
        insert into private.deposit_codes(user_id, code) values (p_user, c);
        exit;
      exception when unique_violation then
        select code into c from private.deposit_codes where user_id = p_user;
        if c is not null then exit; end if;
      end;
    end loop;
  end if;
  return c;
end $$;

-- service role only: called by the edge function for a transaction it has already checked on chain
create or replace function public.credit_deposit(p_hash text, p_lt bigint, p_sender text, p_nano numeric, p_comment text, p_time timestamptz)
returns text
language plpgsql security definer set search_path = '' as $$
declare uid uuid; cr numeric; v_code text; n int;
begin
  if p_hash is null or p_nano is null or p_nano <= 0 then return 'skip'; end if;
  if exists (select 1 from private.deposits where tx_hash = p_hash) then return 'dup'; end if;
  v_code := upper(btrim(coalesce(p_comment, '')));
  select dc.user_id into uid from private.deposit_codes dc where dc.code = v_code;
  cr := floor(p_nano / 10000000) / 100;               -- credited in 0.01 steps; the exact amount is kept in amount_nano
  if uid is null then
    if p_nano < 10000000 then return 'spam'; end if;   -- dust and on-chain spam are not even stored
    insert into private.deposits(tx_hash, lt, user_id, sender, amount_nano, credited, comment, status, tx_time)
    values (p_hash, p_lt, null, p_sender, p_nano, 0, left(p_comment, 200), 'unmatched', p_time) on conflict do nothing;
    return 'unmatched';
  end if;
  insert into private.deposits(tx_hash, lt, user_id, sender, amount_nano, credited, comment, status, tx_time)
  values (p_hash, p_lt, uid, p_sender, p_nano, case when cr > 0 then cr else 0 end, left(p_comment, 200),
          case when cr > 0 then 'credited' else 'ignored' end, p_time)
  on conflict do nothing;
  get diagnostics n = row_count;
  if n = 0 then return 'dup'; end if;                  -- a parallel scan got here first
  if cr > 0 then perform private.real_change(uid, cr, 'deposit', 'tx:' || p_hash); end if;
  return case when cr > 0 then 'credited' else 'ignored' end;
end $$;

-- service role only: at most one chain scan every few seconds
create or replace function public.scan_slot(p_gap_ms int) returns boolean
language sql security definer set search_path = '' as $$
  update private.scan_state set last_scan = now()
   where id = 1 and last_scan < now() - make_interval(secs => p_gap_ms / 1000.0)
  returning true
$$;

-- ---------- what the player sees about their money ----------
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
    'username', (select username from private.tg_accounts where user_id = uid limit 1),
    'stats', (select jsonb_build_object(
        'games', (select count(distinct round_id) from public.bets where user_id = uid and room = 'real'),
        'wins', (select count(*) from public.rounds where winner_id = uid and room = 'real' and status = 'settled'),
        'best', (select coalesce(max(pot - coalesce(fee, 0)), 0) from public.rounds where winner_id = uid and room = 'real' and status = 'settled'),
        'wagered', (select coalesce(sum(amount), 0) from public.bets where user_id = uid and room = 'real'),
        'fun_games', (select count(distinct round_id) from public.bets where user_id = uid and room = 'fun'))),
    'deposits', coalesce((select jsonb_agg(jsonb_build_object('amount', credited, 'at', tx_time, 'status', status) order by tx_time desc)
        from (select * from private.deposits where user_id = uid order by tx_time desc limit 10) d), '[]'),
    'withdrawals', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'amount', amount, 'address', address, 'status', status, 'at', created_at, 'tx', payout_tx) order by id desc)
        from (select * from private.withdrawals where user_id = uid order by id desc limit 10) x), '[]'));
end $$;

-- ---------- withdrawals ----------
create or replace function public.request_withdrawal(p_amount numeric, p_address text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); cfg jsonb; a jsonb; wid bigint; addr text; open_n int;
begin
  if uid is null then raise exception 'auth_required'; end if;
  select value into cfg from public.app_config where key = 'wallet';
  addr := btrim(coalesce(p_address, ''));
  if not (addr ~ '^[A-Za-z0-9_-]{48}$' or addr ~ '^(0|-1):[0-9a-fA-F]{64}$') then raise exception 'bad_address'; end if;
  if lower(addr) = lower(cfg->>'address') then raise exception 'bad_address'; end if;
  p_amount := round(p_amount, 2);
  if p_amount is null or p_amount < coalesce((cfg->>'min_withdraw')::numeric, 1) then raise exception 'min_withdraw'; end if;
  perform 1 from public.wallets where user_id = uid for update;               -- no bets or wins in between
  select count(*) into open_n from private.withdrawals where user_id = uid and status in ('pending', 'flagged');
  if open_n >= coalesce((cfg->>'max_pending')::int, 3) then raise exception 'too_many_pending'; end if;
  a := private.audit_user(uid);
  if (a->>'balance')::numeric < p_amount then raise exception 'no_funds'; end if;
  if not (a->>'ok')::boolean then
    insert into private.withdrawals(user_id, amount, address, status, audit) values (uid, p_amount, addr, 'flagged', a) returning id into wid;
    return jsonb_build_object('id', wid, 'status', 'flagged');
  end if;
  insert into private.withdrawals(user_id, amount, address, status, audit) values (uid, p_amount, addr, 'pending', a) returning id into wid;
  perform private.real_change(uid, -p_amount, 'withdraw', 'wd:' || wid);
  return jsonb_build_object('id', wid, 'status', 'pending', 'balance', (select balance from public.wallets where user_id = uid));
end $$;

-- ---------- owner tools (same admin code as the test menu) ----------
create or replace function public.admin_money(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not public.admin_check(coalesce(p_code, '')) then raise exception 'bad_code'; end if;
  return jsonb_build_object(
    'withdrawals', coalesce((select jsonb_agg(x order by x.id) from (
        select w.id, w.amount, w.address, w.status, w.created_at, w.audit, p.name, a.username,
               private.audit_user(w.user_id) as audit_now,
               (select jsonb_agg(jsonb_build_object('hash', d.tx_hash, 'amount', d.credited, 'nano', d.amount_nano, 'from', d.sender, 'at', d.tx_time))
                  from private.deposits d where d.user_id = w.user_id and d.status in ('credited', 'assigned')) as deposits
          from private.withdrawals w join public.profiles p on p.id = w.user_id
          left join private.tg_accounts a on a.user_id = w.user_id
         where w.status in ('pending', 'flagged') limit 100) x), '[]'),
    'unmatched', coalesce((select jsonb_agg(jsonb_build_object('hash', tx_hash, 'nano', amount_nano, 'from', sender, 'comment', comment, 'at', tx_time) order by tx_time desc)
        from private.deposits where status = 'unmatched'), '[]'),
    'totals', jsonb_build_object(
        'balances', (select coalesce(sum(balance), 0) from public.wallets),
        'deposited', (select coalesce(sum(credited), 0) from private.deposits where status in ('credited', 'assigned')),
        'paid_out', (select coalesce(sum(amount), 0) from private.withdrawals where status = 'paid'),
        'pending', (select coalesce(sum(amount), 0) from private.withdrawals where status = 'pending'),
        'fees', (select coalesce(sum(fee), 0) from private.house_ledger hl join public.rounds r on r.id = hl.round_id where r.room = 'real')));
end $$;

create or replace function public.admin_withdrawal(p_code text, p_id bigint, p_action text, p_tx text, p_note text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare w private.withdrawals;
begin
  if not public.admin_check(coalesce(p_code, '')) then raise exception 'bad_code'; end if;
  select * into w from private.withdrawals where id = p_id for update;
  if not found then raise exception 'not_found'; end if;
  if p_action = 'paid' and w.status = 'pending' then
    if coalesce(btrim(p_tx), '') = '' then raise exception 'tx_required'; end if;
    update private.withdrawals set status = 'paid', payout_tx = btrim(p_tx), admin_note = p_note, decided_at = now() where id = p_id;
  elsif p_action = 'reject' and w.status = 'pending' then
    perform private.real_change(w.user_id, w.amount, 'refund', 'wd:' || p_id);
    update private.withdrawals set status = 'rejected', admin_note = p_note, decided_at = now() where id = p_id;
  elsif p_action = 'reject' and w.status = 'flagged' then
    -- nothing was ever debited for a flagged request: just close it
    update private.withdrawals set status = 'cancelled', admin_note = p_note, decided_at = now() where id = p_id;
  elsif p_action = 'approve' and w.status = 'flagged' then
    perform private.real_change(w.user_id, -w.amount, 'withdraw', 'wd:' || p_id);
    update private.withdrawals set status = 'pending', admin_note = p_note where id = p_id;
  else
    raise exception 'bad_action';
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- a deposit that came without the right comment can be given to its owner after support checked it
create or replace function public.admin_assign_deposit(p_code text, p_hash text, p_user uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare d private.deposits; cr numeric;
begin
  if not public.admin_check(coalesce(p_code, '')) then raise exception 'bad_code'; end if;
  select * into d from private.deposits where tx_hash = p_hash for update;
  if not found or d.status <> 'unmatched' then raise exception 'not_unmatched'; end if;
  cr := floor(d.amount_nano / 10000000) / 100;
  update private.deposits set user_id = p_user, credited = cr, status = 'assigned' where tx_hash = p_hash;
  perform private.real_change(p_user, cr, 'deposit', 'tx:' || p_hash);
  return jsonb_build_object('ok', true, 'credited', cr);
end $$;

-- the house earnings counter: real-money rounds only (earlier test-money commissions do not count)
create or replace function public.house_stats(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not public.admin_check(coalesce(p_code, '')) then raise exception 'bad_code'; end if;
  return (select jsonb_build_object(
    'total', coalesce(sum(h.fee), 0),
    'today', coalesce(sum(h.fee) filter (where h.created_at >= date_trunc('day', now())), 0),
    'rounds', count(*)) from private.house_ledger h join public.rounds r on r.id = h.round_id where r.room = 'real');
end $$;

-- ---------- permissions ----------
revoke execute on all functions in schema private from public, anon, authenticated;
revoke execute on function public.place_bet(numeric, text), public.place_bet(numeric), public.claim_faucet(),
  public.my_wallet(), public.request_withdrawal(numeric, text) from public, anon;
grant execute on function public.place_bet(numeric, text), public.place_bet(numeric), public.claim_faucet(),
  public.my_wallet(), public.request_withdrawal(numeric, text) to authenticated;
revoke execute on function public.credit_deposit(text, bigint, text, numeric, text, timestamptz), public.scan_slot(int),
  public.tg_login_profile(uuid, bigint, text, text, text, text), public.settle_round(bigint, text, text, boolean, uuid, int, jsonb, int),
  public.get_round_secret(bigint), public.admin_bot_bet(uuid, numeric), public.admin_skip()
  from public, anon, authenticated;
grant execute on function public.credit_deposit(text, bigint, text, numeric, text, timestamptz), public.scan_slot(int),
  public.tg_login_profile(uuid, bigint, text, text, text, text), public.settle_round(bigint, text, text, boolean, uuid, int, jsonb, int),
  public.get_round_secret(bigint), public.admin_bot_bet(uuid, numeric), public.admin_skip() to service_role;
revoke execute on function public.admin_money(text), public.admin_withdrawal(text, bigint, text, text, text),
  public.admin_assign_deposit(text, text, uuid) from public;
grant execute on function public.admin_money(text), public.admin_withdrawal(text, bigint, text, text, text),
  public.admin_assign_deposit(text, text, uuid) to anon, authenticated;

-- the edge function asks this before the (slower) second-indexer confirmation
create or replace function public.deposit_known(p_hash text) returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from private.deposits where tx_hash = p_hash)
$$;
revoke execute on function public.deposit_known(text) from public, anon, authenticated;
grant execute on function public.deposit_known(text) to service_role;

-- deposits count only from the moment they were switched on (earlier transfers to the wallet are the owner's own)
update public.app_config set value = value || jsonb_build_object('since', floor(extract(epoch from now()))::bigint) where key = 'wallet';

-- defence in depth: besides RLS (no write policies), client roles get no write privileges at all
revoke insert, update, delete, truncate on public.wallets, public.bets, public.rounds, public.profiles, public.app_config from anon, authenticated;
