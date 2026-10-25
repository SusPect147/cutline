-- CUTLINE: house commission and no upper bet limit.
-- The winner gets the pot minus the commission: 2% of the pot, at least 0.1, never more than the pot.
-- Rounds settled before this migration keep fee = null (no commission).

alter table public.rounds add column if not exists fee numeric(14,2);

-- public, so every player (and the round verifier) can see the rule
insert into public.app_config(key, value) values ('fee', '{"pct": 2, "min": 0.1}')
on conflict (key) do update set value = excluded.value;

-- what the house has earned, round by round
create table if not exists private.house_ledger (
  round_id    bigint primary key references public.rounds(id) on delete cascade,
  fee         numeric(14,2) not null,
  created_at  timestamptz not null default now()
);
alter table private.house_ledger enable row level security;

create or replace function public.round_fee(p_pot numeric) returns numeric
language sql stable set search_path = '' as $$
  select coalesce(least(p_pot, greatest(round(p_pot * (v->>'pct')::numeric / 100, 2), (v->>'min')::numeric)), 0)
    from (select (select value from public.app_config where key = 'fee') as v) c
$$;

create or replace function public.settle_round(p_round bigint, p_entropy text, p_mod text, p_mod_forced boolean,
  p_winner uuid, p_cuts int, p_result jsonb, p_anim_ms int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r public.rounds; v_pot numeric; v_fee numeric; t jsonb; prep_ms int; result_ms int; s text; nid bigint;
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
  v_fee := public.round_fee(v_pot);
  select seed into s from private.round_secrets where round_id = p_round;
  update public.rounds set
     status = 'settled', seed = s, entropy = p_entropy, mod = p_mod, mod_forced = p_mod_forced,
     winner_id = p_winner, pot = v_pot, fee = v_fee, cuts = p_cuts, result = p_result, settled_at = now(),
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

-- any amount the player has (min 0.1); the ceiling only protects the numeric column
create or replace function public.place_bet(p_amount numeric) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); r public.rounds; n int; already boolean; bal numeric; t jsonb;
begin
  if uid is null then raise exception 'auth_required'; end if;
  p_amount := round(p_amount, 2);
  if p_amount is null or p_amount < 0.1 or p_amount > 100000000000 then raise exception 'bad_amount'; end if;
  select * into r from public.rounds where status = 'betting' order by id desc limit 1 for update;
  if not found or now() < r.opens_at then raise exception 'not_open'; end if;
  if r.bets_close_at is not null and now() >= r.bets_close_at then raise exception 'closed'; end if;
  select exists(select 1 from public.bets where round_id = r.id and user_id = uid) into already;
  select count(distinct user_id) into n from public.bets where round_id = r.id;
  if not already and n >= 24 then raise exception 'round_full'; end if;
  update public.wallets set balance = balance - p_amount
   where user_id = uid and balance >= p_amount returning balance into bal;
  if not found then raise exception 'no_funds'; end if;
  insert into public.bets(round_id, user_id, amount) values (r.id, uid, p_amount);
  if r.bets_close_at is null and not already and n + 1 >= 2 then
    select value into t from public.app_config where key = 'timing';
    update public.rounds set bets_close_at = now() + make_interval(secs => coalesce((t->>'bet_ms')::int, 15000) / 1000.0)
     where id = r.id;
  end if;
  return jsonb_build_object('balance', bal, 'round', r.id);
end $$;

-- the owner's view of the earnings, behind the same admin code as the test menu
create or replace function public.house_stats(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not public.admin_check(coalesce(p_code, '')) then raise exception 'bad_code'; end if;
  return (select jsonb_build_object(
    'total', coalesce(sum(fee), 0),
    'today', coalesce(sum(fee) filter (where created_at >= date_trunc('day', now())), 0),
    'rounds', count(*)) from private.house_ledger);
end $$;

revoke execute on function public.round_fee(numeric) from public, anon, authenticated;
revoke execute on function public.settle_round(bigint, text, text, boolean, uuid, int, jsonb, int) from public, anon, authenticated;
grant execute on function public.settle_round(bigint, text, text, boolean, uuid, int, jsonb, int) to service_role;
grant execute on function public.place_bet(numeric) to authenticated;
revoke execute on function public.house_stats(text) from public;
grant execute on function public.house_stats(text) to anon, authenticated;
