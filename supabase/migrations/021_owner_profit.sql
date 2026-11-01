-- CUTLINE: what the owner may take out, counted two independent ways; the smaller one wins.
--  1. Free money in the wallet: on-chain balance − everything owed to players (balances, including money won from
--     task rewards; withdrawals not yet paid; bets in rounds not yet settled; transfers without a code) − the reserve.
--  2. Profit not yet taken: round commissions + withdrawal commissions − task rewards − owner payouts so far
--     (+ the owner's own top-ups sent with the comment HOUSE).
-- So the owner never takes players' money (1), and never more than the game has actually earned (2): rewards are paid
-- out of the commission, a transfer that arrived but is not counted yet is not "profit", and a top-up the owner made to
-- cover players stays in the wallet.
-- Task rewards are paid only while the profit (2) covers them, so rewards can never eat into players' money either;
-- HOUSE top-ups count towards it, so the owner can fund rewards by topping the wallet up.

-- the owner can top the wallet up without that money looking like a player's: a transfer with the comment HOUSE
-- is the owner's own capital (not owed to anyone), and the owner may take it back later.
alter table private.deposits drop constraint if exists deposits_status_check;
alter table private.deposits add constraint deposits_status_check
  check (status = any (array['credited', 'unmatched', 'ignored', 'assigned', 'house']));

create or replace function private.house_earned() returns numeric
language sql stable security definer set search_path = '' as $$
  select (select coalesce(sum(fee), 0) from public.rounds where room = 'real' and status = 'settled')
       + (select coalesce(sum(fee), 0) from private.withdrawals where kind = 'player' and status = 'paid')
       + (select coalesce(sum(amount_nano), 0) / 1000000000 from private.deposits where status = 'house')
       - (select coalesce(sum(amount), 0) from private.quest_claims)
       - (select coalesce(sum(amount), 0) from private.withdrawals where kind = 'owner' and status in ('pending', 'paid'))
$$;
revoke execute on function private.house_earned() from public, anon, authenticated;

create or replace function private.owner_available(p_chain_nano numeric) returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare cfg jsonb; reserve numeric; obl numeric; chain numeric; free numeric; earned numeric;
begin
  select value into cfg from public.app_config where key = 'wallet';
  reserve := coalesce((cfg->>'owner_reserve')::numeric, 1);
  obl := private.obligations();
  earned := private.house_earned();
  chain := case when p_chain_nano is null then null else p_chain_nano / 1000000000 end;
  free := case when chain is null then null else chain - obl - reserve end;
  return jsonb_build_object(
    'chain', chain, 'obligations', obl, 'reserve', reserve, 'free', free, 'earned', earned,
    'owner_paid', (select coalesce(sum(amount), 0) from private.withdrawals where kind = 'owner' and status = 'paid'),
    'topups', (select coalesce(sum(amount_nano), 0) / 1000000000 from private.deposits where status = 'house'),
    'available', case when free is null then null else greatest(0, floor(least(free, earned) * 100) / 100) end);
end $$;
revoke execute on function private.owner_available(numeric) from public, anon, authenticated;

-- for the bot and the owner's stats page (service role only)
create or replace function public.owner_available(p_chain_nano numeric) returns jsonb
language sql stable security definer set search_path = '' as $$ select private.owner_available(p_chain_nano) $$;
revoke execute on function public.owner_available(numeric) from public, anon, authenticated;
grant execute on function public.owner_available(numeric) to service_role;

create or replace function public.owner_payout_create(p_amount numeric, p_chain_nano numeric) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare cfg jsonb; addr text; av jsonb; avail numeric; amt numeric; wid bigint;
begin
  select value into cfg from public.app_config where key = 'wallet';
  addr := btrim(coalesce(cfg->>'owner_address', ''));
  if not (addr ~ '^[A-Za-z0-9_-]{48}$' or addr ~ '^(0|-1):[0-9a-fA-F]{64}$') then raise exception 'no_owner_address'; end if;
  if lower(addr) = lower(cfg->>'address') then raise exception 'no_owner_address'; end if;
  if p_chain_nano is null or p_chain_nano < 0 then raise exception 'not_available'; end if;
  perform pg_advisory_xact_lock(hashtext('cutline.house_money'));
  if exists (select 1 from private.withdrawals where kind = 'owner' and status = 'pending') then raise exception 'owner_pending'; end if;
  av := private.owner_available(p_chain_nano);
  avail := (av->>'available')::numeric;
  amt := round(coalesce(p_amount, avail), 2);
  if amt is null or amt < 0.1 or amt > avail then raise exception 'not_available'; end if;
  insert into private.withdrawals(user_id, kind, amount, fee, payout, address, status, audit, manual_ok, admin_note)
  values (null, 'owner', amt, 0, amt, addr, 'pending', av, true, 'owner profit') returning id into wid;
  return jsonb_build_object('id', wid, 'amount', amt, 'address', addr, 'available', avail);
end $$;
revoke execute on function public.owner_payout_create(numeric, numeric) from public, anon, authenticated;
grant execute on function public.owner_payout_create(numeric, numeric) to service_role;

-- task rewards: only out of profit that is still there
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
  perform 1 from public.wallets where user_id = p_user for update;
  if not found then raise exception 'tg_required'; end if;
  if exists (select 1 from private.quest_claims where user_id = p_user and quest_id = p_id) then raise exception 'quest_claimed'; end if;
  if q->>'kind' = 'channel' then
    if p_channel_ok is not true then raise exception 'quest_channel'; end if;
  else
    have := coalesce((private.quest_progress(p_user)->>(case q->>'kind' when 'rounds' then 'rounds' when 'wins' then 'wins'
                                                                     when 'friends' then 'friends' end))::numeric, 0);
    if have < coalesce((q->>'goal')::numeric, 1e9) then raise exception 'quest_not_done'; end if;
  end if;
  perform pg_advisory_xact_lock(hashtext('cutline.house_money'));
  select coalesce(sum(amount), 0) into day_sum from private.quest_claims where created_at > now() - interval '24 hours';
  if day_sum + amt > coalesce((cfg->>'daily_cap')::numeric, 50) then raise exception 'quests_busy'; end if;
  -- the reward comes out of the commission the game has earned and the owner has not taken
  if private.house_earned() - amt < -coalesce((cfg->>'reward_float')::numeric, 0.5) then raise exception 'quests_busy'; end if;
  insert into private.quest_claims(user_id, quest_id, amount) values (p_user, p_id, amt);
  bal := private.real_change(p_user, amt, 'reward', 'quest:' || p_id);
  return jsonb_build_object('ok', true, 'id', p_id, 'reward', amt, 'balance', bal);
end $$;
revoke execute on function private.quest_claim(uuid, text, boolean) from public, anon, authenticated;

-- a transfer with the comment HOUSE is the owner's top-up
create or replace function public.credit_deposit(p_hash text, p_lt bigint, p_sender text, p_nano numeric, p_comment text, p_time timestamptz)
returns text language plpgsql security definer set search_path = '' as $$
declare uid uuid; cr numeric; v_code text; n int; inv_id bigint;
begin
  if p_hash is null or p_nano is null or p_nano <= 0 then return 'skip'; end if;
  if exists (select 1 from private.deposits where tx_hash = p_hash) then return 'dup'; end if;
  v_code := upper(btrim(coalesce(p_comment, '')));
  if v_code = 'HOUSE' then
    insert into private.deposits(tx_hash, lt, user_id, sender, amount_nano, credited, comment, status, tx_time)
    values (p_hash, p_lt, null, p_sender, p_nano, 0, left(p_comment, 200), 'house', p_time) on conflict do nothing;
    return 'house';
  end if;
  select dc.user_id into uid from private.deposit_codes dc where dc.code = v_code;
  if uid is null then
    select i.id, i.user_id into inv_id, uid from private.deposit_invoices i
     where i.amount_nano = p_nano and i.status = 'open'
       and p_time >= i.created_at - interval '2 minutes' and p_time <= i.expires_at
     order by i.id desc limit 1 for update;
  else
    select i.id into inv_id from private.deposit_invoices i
     where i.user_id = uid and i.amount_nano = p_nano and i.status = 'open' order by i.id desc limit 1 for update;
  end if;
  cr := floor(p_nano / 10000000) / 100;
  if uid is null then
    if p_nano < 10000000 then return 'spam'; end if;
    insert into private.deposits(tx_hash, lt, user_id, sender, amount_nano, credited, comment, status, tx_time)
    values (p_hash, p_lt, null, p_sender, p_nano, 0, left(p_comment, 200), 'unmatched', p_time) on conflict do nothing;
    return 'unmatched';
  end if;
  insert into private.deposits(tx_hash, lt, user_id, sender, amount_nano, credited, comment, status, tx_time)
  values (p_hash, p_lt, uid, p_sender, p_nano, case when cr > 0 then cr else 0 end, left(p_comment, 200),
          case when cr > 0 then 'credited' else 'ignored' end, p_time)
  on conflict do nothing;
  get diagnostics n = row_count;
  if n = 0 then return 'dup'; end if;
  if inv_id is not null then update private.deposit_invoices set status = 'paid', paid_tx = p_hash where id = inv_id; end if;
  if cr > 0 then perform private.real_change(uid, cr, 'deposit', 'tx:' || p_hash); end if;
  return case when cr > 0 then 'credited' else 'ignored' end;
end $$;
