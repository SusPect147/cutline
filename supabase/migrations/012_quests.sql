-- CUTLINE: tasks ("quests") and referrals.
-- * Every player has an invite code; the link is app_config.quests.ref_link with {code} replaced by "r_<code>".
--   A new player who opens the game through such a link (Telegram start_param, signed by Telegram) is bound to the
--   inviter once, on their very first sign-in (edge function -> bind_referral).
-- * A friend counts once they have at least one deposit of friend_min_deposit Gram and friend_min_rounds settled
--   PvP rounds. Referral tasks pay at 5 / 10 / 25 / 50 / 100 counted friends.
-- * Other tasks: subscribe to the channel (checked by the bot with getChatMember), play N PvP rounds, win a round.
-- * Rewards go to the Gram balance through the ledger (kind 'reward'), each task at most once per player, and all
--   rewards together are capped per 24 hours (daily_cap). The owner can change amounts, goals or switch tasks off
--   in app_config.quests.

alter table private.ledger drop constraint ledger_kind_check;
alter table private.ledger add constraint ledger_kind_check
  check (kind in ('deposit', 'bet', 'win', 'withdraw', 'refund', 'adjust', 'reward'));

create table if not exists private.ref_codes (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  code    text not null unique
);
create table if not exists private.referrals (
  user_id     uuid primary key references public.profiles(id) on delete cascade,
  referrer_id uuid not null references public.profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  check (user_id <> referrer_id)
);
create index if not exists referrals_referrer on private.referrals(referrer_id);
create table if not exists private.quest_claims (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  quest_id   text not null,
  amount     numeric not null check (amount > 0),
  created_at timestamptz not null default now(),
  primary key (user_id, quest_id)
);
alter table private.ref_codes enable row level security;
alter table private.referrals enable row level security;
alter table private.quest_claims enable row level security;

insert into public.app_config(key, value) values ('quests', '{
  "enabled": true,
  "channel": "cutline",
  "ref_link": "https://t.me/cutline_game?startapp={code}",
  "friend_min_deposit": 0.1,
  "friend_min_rounds": 1,
  "daily_cap": 50,
  "list": [
    {"id": "channel", "kind": "channel", "goal": 1,   "reward": 0.02},
    {"id": "play10",  "kind": "rounds",  "goal": 10,  "reward": 0.02},
    {"id": "play50",  "kind": "rounds",  "goal": 50,  "reward": 0.1},
    {"id": "win1",    "kind": "wins",    "goal": 1,   "reward": 0.01},
    {"id": "ref5",    "kind": "friends", "goal": 5,   "reward": 0.7},
    {"id": "ref10",   "kind": "friends", "goal": 10,  "reward": 1.4},
    {"id": "ref25",   "kind": "friends", "goal": 25,  "reward": 3.5},
    {"id": "ref50",   "kind": "friends", "goal": 50,  "reward": 7},
    {"id": "ref100",  "kind": "friends", "goal": 100, "reward": 14}
  ]}'::jsonb)
on conflict (key) do nothing;

-- the player's invite code (made on first use)
create or replace function private.ref_code(p_user uuid) returns text
language plpgsql security definer set search_path = '' as $$
declare c text;
begin
  select code into c from private.ref_codes where user_id = p_user;
  if found then return c; end if;
  loop
    c := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));
    begin
      insert into private.ref_codes(user_id, code) values (p_user, c);
      return c;
    exception when unique_violation then
      select code into c from private.ref_codes where user_id = p_user;   -- created meanwhile by a parallel call
      if found then return c; end if;
    end;
  end loop;
end $$;

-- invited friends: all of them, those who deposited, and those who count (deposited and played)
create or replace function private.ref_stats(p_user uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  with cfg as (
    select coalesce((value->>'friend_min_deposit')::numeric, 0.1) as md, coalesce((value->>'friend_min_rounds')::int, 1) as mr
      from public.app_config where key = 'quests'),
  fr as (
    select r.user_id,
           exists (select 1 from private.deposits d where d.user_id = r.user_id and d.status in ('credited', 'assigned')
                    and d.credited >= (select md from cfg)) as dep_ok,
           (select count(distinct b.round_id) from public.bets b join public.rounds ro on ro.id = b.round_id
             where b.user_id = r.user_id and b.room = 'real' and ro.status = 'settled') as played
      from private.referrals r where r.referrer_id = p_user)
  select jsonb_build_object('total', count(*), 'deposited', count(*) filter (where dep_ok),
                            'ok', count(*) filter (where dep_ok and played >= (select mr from cfg)))
    from fr
$$;

create or replace function private.quest_progress(p_user uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'rounds', (select count(distinct b.round_id) from public.bets b join public.rounds r on r.id = b.round_id
                where b.user_id = p_user and b.room = 'real' and r.status = 'settled'),
    'wins', (select count(*) from public.rounds where winner_id = p_user and room = 'real' and status = 'settled'),
    'friends', (private.ref_stats(p_user)->>'ok')::int)
$$;

-- pays one task; p_channel_ok is true only when the edge function has just checked the subscription with Telegram
create or replace function private.quest_claim(p_user uuid, p_id text, p_channel_ok boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare cfg jsonb; q jsonb; have numeric; amt numeric; bal numeric; day_sum numeric;
begin
  select value into cfg from public.app_config where key = 'quests';
  if cfg is null or coalesce((cfg->>'enabled')::boolean, false) is not true then raise exception 'quests_off'; end if;
  select x into q from jsonb_array_elements(cfg->'list') x where x->>'id' = p_id;
  if q is null then raise exception 'no_quest'; end if;
  amt := (q->>'reward')::numeric;
  if not (amt > 0) then raise exception 'no_quest'; end if;
  perform 1 from public.wallets where user_id = p_user for update;          -- one claim at a time per player
  if not found then raise exception 'tg_required'; end if;
  if exists (select 1 from private.quest_claims where user_id = p_user and quest_id = p_id) then raise exception 'quest_claimed'; end if;
  if q->>'kind' = 'channel' then
    if p_channel_ok is not true then raise exception 'quest_channel'; end if;
  else
    have := coalesce((private.quest_progress(p_user)->>(case q->>'kind' when 'rounds' then 'rounds' when 'wins' then 'wins'
                                                                     when 'friends' then 'friends' end))::numeric, 0);
    if have < coalesce((q->>'goal')::numeric, 1e9) then raise exception 'quest_not_done'; end if;
  end if;
  perform pg_advisory_xact_lock(hashtext('cutline.quests.cap'));           -- the daily cap is shared by everyone
  select coalesce(sum(amount), 0) into day_sum from private.quest_claims where created_at > now() - interval '24 hours';
  if day_sum + amt > coalesce((cfg->>'daily_cap')::numeric, 50) then raise exception 'quests_busy'; end if;
  insert into private.quest_claims(user_id, quest_id, amount) values (p_user, p_id, amt);
  bal := private.real_change(p_user, amt, 'reward', 'quest:' || p_id);
  return jsonb_build_object('ok', true, 'id', p_id, 'reward', amt, 'balance', bal);
end $$;

-- ---------- for players ----------
create or replace function public.my_quests() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); cfg jsonb; code text;
begin
  if uid is null then raise exception 'auth_required'; end if;
  if not exists (select 1 from public.wallets where user_id = uid) then raise exception 'tg_required'; end if;
  select value into cfg from public.app_config where key = 'quests';
  if cfg is null then return jsonb_build_object('enabled', false, 'list', '[]'::jsonb); end if;
  code := private.ref_code(uid);
  return jsonb_build_object(
    'enabled', coalesce((cfg->>'enabled')::boolean, false), 'channel', cfg->>'channel', 'code', code,
    'link', replace(coalesce(cfg->>'ref_link', ''), '{code}', 'r_' || code),
    'friend_min_deposit', cfg->'friend_min_deposit', 'friend_min_rounds', cfg->'friend_min_rounds',
    'friends', private.ref_stats(uid), 'progress', private.quest_progress(uid),
    'list', (select coalesce(jsonb_agg(jsonb_build_object('id', q->>'id', 'kind', q->>'kind', 'goal', q->'goal', 'reward', q->'reward',
                       'claimed', exists (select 1 from private.quest_claims c where c.user_id = uid and c.quest_id = q->>'id')) order by ord), '[]')
               from jsonb_array_elements(cfg->'list') with ordinality as t(q, ord)));
end $$;

create or replace function public.claim_quest(p_id text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid();
begin
  if uid is null then raise exception 'auth_required'; end if;
  return private.quest_claim(uid, left(coalesce(p_id, ''), 32), false);
end $$;

-- ---------- for the edge function only ----------
-- binds a brand-new player to the inviter from the signed start_param ("r_<code>")
create or replace function public.bind_referral(p_user uuid, p_param text) returns boolean
language plpgsql security definer set search_path = '' as $$
declare c text; ref uuid;
begin
  c := upper(substring(coalesce(p_param, '') from '^r_([A-Za-z0-9]{6,16})$'));
  if c is null then return false; end if;
  select user_id into ref from private.ref_codes where code = c;
  if ref is null or ref = p_user then return false; end if;
  if not exists (select 1 from public.profiles where id = p_user and created_at > now() - interval '15 minutes') then return false; end if;
  if exists (select 1 from public.bets where user_id = p_user) or exists (select 1 from private.deposits where user_id = p_user) then return false; end if;
  insert into private.referrals(user_id, referrer_id) values (p_user, ref) on conflict (user_id) do nothing;
  return found;
end $$;

create or replace function public.quest_channel_info(p_user uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'tg_id', (select tg_id from private.tg_accounts where user_id = p_user limit 1),
    'channel', (select value->>'channel' from public.app_config where key = 'quests'),
    'claimed', exists (select 1 from private.quest_claims where user_id = p_user and quest_id = 'channel'))
$$;

create or replace function public.quest_channel_claim(p_user uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  return private.quest_claim(p_user, 'channel', true);
end $$;

-- ---------- rewards in the money checks ----------
create or replace function private.audit_user(p_user uuid) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare a jsonb; bal numeric; l_sum numeric; l_dep numeric; l_bet numeric; l_win numeric; l_wd numeric; l_ref numeric; l_adj numeric; l_rew numeric;
  dep numeric; bets numeric; wins numeric; wd_open numeric; refunded numeric; rew numeric; chain_ok boolean;
begin
  select balance into bal from public.wallets where user_id = p_user;
  select coalesce(sum(amount), 0),
         coalesce(sum(amount) filter (where kind = 'deposit'), 0), coalesce(sum(amount) filter (where kind = 'bet'), 0),
         coalesce(sum(amount) filter (where kind = 'win'), 0),     coalesce(sum(amount) filter (where kind = 'withdraw'), 0),
         coalesce(sum(amount) filter (where kind = 'refund'), 0),  coalesce(sum(amount) filter (where kind = 'adjust'), 0),
         coalesce(sum(amount) filter (where kind = 'reward'), 0)
    into l_sum, l_dep, l_bet, l_win, l_wd, l_ref, l_adj, l_rew
    from private.ledger where user_id = p_user;
  select coalesce(sum(credited), 0) into dep from private.deposits where user_id = p_user and status in ('credited', 'assigned');
  select coalesce(sum(amount), 0) into bets from public.bets where user_id = p_user and room = 'real';
  select coalesce(sum(r.pot - coalesce(r.fee, 0)), 0) into wins from public.rounds r
   where r.winner_id = p_user and r.room = 'real' and r.status = 'settled';
  select coalesce(sum(amount), 0) into wd_open from private.withdrawals where user_id = p_user and status in ('pending', 'paid', 'rejected');
  select coalesce(sum(amount), 0) into refunded from private.withdrawals where user_id = p_user and status = 'rejected';
  select coalesce(sum(amount), 0) into rew from private.quest_claims where user_id = p_user;
  select coalesce(bool_and(ok), true) into chain_ok from (
    select balance_after = coalesce(lag(balance_after) over (order by id), 0) + amount as ok
      from private.ledger where user_id = p_user) c;
  a := jsonb_build_object(
    'balance', bal, 'ledger_sum', l_sum, 'chain_ok', chain_ok,
    'deposits', dep, 'ledger_deposits', l_dep,
    'bets', bets, 'ledger_bets', -l_bet,
    'wins', wins, 'ledger_wins', l_win,
    'withdrawn', wd_open, 'ledger_withdrawn', -l_wd,
    'refunded', refunded, 'ledger_refunds', l_ref, 'adjustments', l_adj,
    'rewards', rew, 'ledger_rewards', l_rew);
  return a || jsonb_build_object('ok',
        bal = l_sum and chain_ok and dep = l_dep and bets = -l_bet and wins = l_win
    and wd_open = -l_wd and refunded = l_ref and l_adj = 0 and rew = l_rew);
end $$;

-- rewards in the player's own operations list
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
        from (select * from private.withdrawals where user_id = uid order by id desc limit 10) x), '[]'),
    'rewards', coalesce((select jsonb_agg(jsonb_build_object('id', quest_id, 'amount', amount, 'at', created_at) order by created_at desc)
        from (select * from private.quest_claims where user_id = uid order by created_at desc limit 10) q), '[]'));
end $$;

-- the owner's money overview also shows the task rewards paid
create or replace function private.money() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'withdrawals', coalesce((select jsonb_agg(x order by x.id) from (
        select w.id, w.amount, w.fee, coalesce(w.payout, w.amount) as send, w.address, w.status, w.created_at, w.send_at, w.auto_hold, w.admin_note, p.name, a.username,
               private.audit_user(w.user_id) as audit_now,
               (select jsonb_agg(jsonb_build_object('hash', d.tx_hash, 'amount', d.credited, 'from', d.sender, 'at', d.tx_time))
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
        'to_send', (select coalesce(sum(coalesce(payout, amount)), 0) from private.withdrawals where status = 'pending'),
        'game_fees', (select coalesce(sum(hl.fee), 0) from private.house_ledger hl join public.rounds r on r.id = hl.round_id where r.room = 'real'),
        'withdraw_fees', (select coalesce(sum(fee), 0) from private.withdrawals where status = 'paid'),
        'rewards', (select coalesce(sum(amount), 0) from private.quest_claims)))
$$;

revoke execute on function private.ref_code(uuid), private.ref_stats(uuid), private.quest_progress(uuid),
  private.quest_claim(uuid, text, boolean) from public, anon, authenticated;
revoke execute on function public.my_quests(), public.claim_quest(text), public.bind_referral(uuid, text),
  public.quest_channel_info(uuid), public.quest_channel_claim(uuid) from public, anon, authenticated;
grant execute on function public.my_quests(), public.claim_quest(text) to authenticated;
grant execute on function public.bind_referral(uuid, text), public.quest_channel_info(uuid), public.quest_channel_claim(uuid) to service_role;
