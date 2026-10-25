-- CUTLINE: the winner always ends in profit.
-- Commission (rule 2):
--   1. 2% of the pot, at least 0.1;
--   2. if that would leave the winner with less than their own stake + 0.1,
--      it is 2% of what they won from the others (pot − own stake), at least 0.1;
--   3. never more than (pot − own stake − 0.1): the winner is always at least 0.1 up.
-- Each round records the rule it was settled with (null = rule 1, the plain 2% / 0.1), so old rounds still verify.

alter table public.rounds add column if not exists fee_rule smallint;

update public.app_config set value = value || '{"guard": 0.1}'::jsonb where key = 'fee';

create or replace function public.round_fee_v2(p_pot numeric, p_stake numeric) returns numeric
language plpgsql stable set search_path = '' as $$
declare v jsonb; pct numeric; mn numeric; guard numeric; gain numeric; f numeric;
begin
  select value into v from public.app_config where key = 'fee';
  if v is null then return 0; end if;
  pct := coalesce((v->>'pct')::numeric, 0);
  mn := coalesce((v->>'min')::numeric, 0);
  guard := coalesce((v->>'guard')::numeric, 0.1);
  gain := p_pot - p_stake;
  if pct <= 0 or gain <= 0 then return 0; end if;
  f := greatest(round(p_pot * pct / 100, 2), mn);
  if p_pot - f < p_stake + guard then
    f := greatest(round(gain * pct / 100, 2), mn);
  end if;
  return greatest(least(f, gain - guard), 0);
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
  select coalesce(sum(amount), 0) into v_pot from public.bets where round_id = p_round;
  select coalesce(sum(amount), 0) into v_stake from public.bets where round_id = p_round and user_id = p_winner;
  v_fee := public.round_fee_v2(v_pot, v_stake);
  select seed into s from private.round_secrets where round_id = p_round;
  update public.rounds set
     status = 'settled', seed = s, entropy = p_entropy, mod = p_mod, mod_forced = p_mod_forced,
     winner_id = p_winner, pot = v_pot, fee = v_fee, fee_rule = 2, cuts = p_cuts, result = p_result, settled_at = now(),
     prep_until = now() + make_interval(secs => prep_ms / 1000.0),
     anim_end   = now() + make_interval(secs => (prep_ms + p_anim_ms) / 1000.0),
     ends_at    = now() + make_interval(secs => (prep_ms + p_anim_ms + result_ms) / 1000.0)
   where id = p_round;
  update public.wallets set balance = balance + (v_pot - v_fee) where user_id = p_winner;
  insert into private.house_ledger(round_id, fee) values (p_round, v_fee) on conflict (round_id) do nothing;
  if p_mod_forced then delete from private.admin_config where key = 'next_mod'; end if;
  nid := private.new_round(now() + make_interval(secs => (prep_ms + p_anim_ms + result_ms) / 1000.0));
  return jsonb_build_object('ok', true, 'next', nid);
end $$;

revoke execute on function public.round_fee_v2(numeric, numeric) from public, anon, authenticated;
revoke execute on function public.settle_round(bigint, text, text, boolean, uuid, int, jsonb, int) from public, anon, authenticated;
grant execute on function public.settle_round(bigint, text, text, boolean, uuid, int, jsonb, int) to service_role;
