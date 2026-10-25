-- CUTLINE: server-authoritative game state.
-- Clients can only READ public tables. Every change of money or round state goes through
-- SECURITY DEFINER functions with their own checks, or through the `game` edge function (service role).

create extension if not exists pgcrypto with schema extensions;

create schema if not exists private;          -- never exposed through the API
revoke all on schema private from anon, authenticated;

-- ---------- tables ----------
create table public.profiles (
  id          uuid primary key,
  name        text not null check (char_length(name) between 1 and 24),
  avatar_url  text,
  is_bot      boolean not null default false,
  created_at  timestamptz not null default now()
);

create table public.wallets (
  user_id            uuid primary key references public.profiles(id) on delete cascade,
  balance            numeric(14,2) not null default 10 check (balance >= 0),
  last_faucet_round  bigint
);

create table public.rounds (
  id             bigint generated always as identity primary key,
  status         text not null default 'betting' check (status in ('betting','settled')),
  seed_hash      text not null,               -- sha256(seed), public from the start
  seed           text,                        -- revealed when the round is settled
  entropy        text,                        -- created only after bets are closed
  mod            text,
  mod_forced     boolean not null default false,
  opens_at       timestamptz not null default now(),
  bets_close_at  timestamptz,                 -- set when the 2nd player joins
  settled_at     timestamptz,
  prep_until     timestamptz,
  anim_end       timestamptz,
  ends_at        timestamptz,
  winner_id      uuid references public.profiles(id),
  pot            numeric(14,2),
  cuts           int,
  result         jsonb,                       -- field + every cut, for playback and verification
  created_at     timestamptz not null default now()
);
create index rounds_status_idx on public.rounds(status, id desc);

create table public.bets (
  id          bigint generated always as identity primary key,
  round_id    bigint not null references public.rounds(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  amount      numeric(14,2) not null check (amount > 0),
  created_at  timestamptz not null default now()
);
create index bets_round_idx on public.bets(round_id, id);
create index bets_user_idx on public.bets(user_id);

create table public.app_config (            -- public, non-secret settings
  key    text primary key,
  value  jsonb not null
);
insert into public.app_config(key, value) values
  ('timing', '{"bet_ms":15000,"prep_ms":5000,"result_ms":5400,"fast":false}');

create table private.round_secrets (
  round_id  bigint primary key references public.rounds(id) on delete cascade,
  seed      text not null
);
create table private.admin_config (
  key    text primary key,
  value  text
);

-- ---------- row level security ----------
alter table public.profiles   enable row level security;
alter table public.wallets    enable row level security;
alter table public.rounds     enable row level security;
alter table public.bets       enable row level security;
alter table public.app_config enable row level security;
alter table private.round_secrets enable row level security;
alter table private.admin_config  enable row level security;

create policy "profiles are public"  on public.profiles   for select using (true);
create policy "rounds are public"    on public.rounds     for select using (true);
create policy "bets are public"      on public.bets       for select using (true);
create policy "config is public"     on public.app_config for select using (true);
create policy "own wallet only"      on public.wallets    for select to authenticated using (user_id = (select auth.uid()));
-- no insert/update/delete policies at all: writes only through the functions below

-- ---------- helpers ----------
create or replace function public.server_now() returns timestamptz
language sql stable set search_path = '' as $$ select now() $$;

create or replace function private.new_round(p_opens_at timestamptz) returns bigint
language plpgsql security definer set search_path = '' as $$
declare s text := encode(extensions.gen_random_bytes(12), 'hex'); rid bigint;
begin
  insert into public.rounds(seed_hash, opens_at)
  values (encode(extensions.digest(s, 'sha256'), 'hex'), p_opens_at) returning id into rid;
  insert into private.round_secrets(round_id, seed) values (rid, s);
  return rid;
end $$;

-- ---------- player actions ----------
-- creates the profile and the starting wallet (10) on first visit; later calls only refresh name/avatar
create or replace function public.ensure_profile(p_name text, p_avatar text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); nm text; av text; w public.wallets;
begin
  if uid is null then raise exception 'auth_required'; end if;
  nm := left(regexp_replace(coalesce(p_name, ''), '[\r\n\t<>]', '', 'g'), 24);
  if char_length(btrim(nm)) = 0 then nm := 'Player'; end if;
  av := case when p_avatar ~ '^https://(api\.dicebear\.com|t\.me|cdn[0-9]*\.telegram-cdn\.org)/' and char_length(p_avatar) < 400
             then p_avatar else null end;
  insert into public.profiles(id, name, avatar_url) values (uid, nm, av)
  on conflict (id) do update set name = excluded.name, avatar_url = coalesce(excluded.avatar_url, public.profiles.avatar_url)
  where public.profiles.is_bot = false;
  insert into public.wallets(user_id, balance) values (uid, 10) on conflict (user_id) do nothing;
  select * into w from public.wallets where user_id = uid;
  return jsonb_build_object('balance', w.balance, 'last_faucet_round', w.last_faucet_round);
end $$;

create or replace function public.place_bet(p_amount numeric) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); r public.rounds; n int; already boolean; bal numeric; t jsonb;
begin
  if uid is null then raise exception 'auth_required'; end if;
  p_amount := round(p_amount, 2);
  if p_amount is null or p_amount < 0.1 or p_amount > 1000 then raise exception 'bad_amount'; end if;
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

-- free top-up: random 10.0 … 100.0, once per round
create or replace function public.claim_faucet() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); rid bigint; amt numeric; bal numeric;
begin
  if uid is null then raise exception 'auth_required'; end if;
  select id into rid from public.rounds order by id desc limit 1;
  amt := round((10 + random() * 90)::numeric, 1);
  update public.wallets set balance = balance + amt, last_faucet_round = rid
   where user_id = uid and last_faucet_round is distinct from rid returning balance into bal;
  if not found then raise exception 'faucet_used'; end if;
  return jsonb_build_object('amount', amt, 'balance', bal, 'round', rid);
end $$;

-- ---------- server-only (edge function with the service role) ----------
create or replace function public.get_round_secret(p_round bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s text; nm text;
begin
  select seed into s from private.round_secrets where round_id = p_round;
  select value into nm from private.admin_config where key = 'next_mod';
  return jsonb_build_object('seed', s, 'forced_mod', nm);
end $$;

create or replace function public.settle_round(p_round bigint, p_entropy text, p_mod text, p_mod_forced boolean,
  p_winner uuid, p_cuts int, p_result jsonb, p_anim_ms int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r public.rounds; v_pot numeric; t jsonb; prep_ms int; result_ms int; s text; nid bigint;
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
  select seed into s from private.round_secrets where round_id = p_round;
  update public.rounds set
     status = 'settled', seed = s, entropy = p_entropy, mod = p_mod, mod_forced = p_mod_forced,
     winner_id = p_winner, pot = v_pot, cuts = p_cuts, result = p_result, settled_at = now(),
     prep_until = now() + make_interval(secs => prep_ms / 1000.0),
     anim_end   = now() + make_interval(secs => (prep_ms + p_anim_ms) / 1000.0),
     ends_at    = now() + make_interval(secs => (prep_ms + p_anim_ms + result_ms) / 1000.0)
   where id = p_round;
  update public.wallets set balance = balance + v_pot where user_id = p_winner;
  if p_mod_forced then delete from private.admin_config where key = 'next_mod'; end if;
  nid := private.new_round(now() + make_interval(secs => (prep_ms + p_anim_ms + result_ms) / 1000.0));
  return jsonb_build_object('ok', true, 'next', nid);
end $$;

create or replace function public.admin_bot_bet(p_bot uuid, p_amount numeric) returns void
language plpgsql security definer set search_path = '' as $$
declare r public.rounds; n int; already boolean; t jsonb;
begin
  if not exists (select 1 from public.profiles where id = p_bot and is_bot) then raise exception 'not_bot'; end if;
  select * into r from public.rounds where status = 'betting' order by id desc limit 1 for update;
  if not found or now() < r.opens_at or (r.bets_close_at is not null and now() >= r.bets_close_at) then raise exception 'not_open'; end if;
  select exists(select 1 from public.bets where round_id = r.id and user_id = p_bot) into already;
  select count(distinct user_id) into n from public.bets where round_id = r.id;
  if not already and n >= 24 then raise exception 'round_full'; end if;
  update public.wallets set balance = balance - p_amount where user_id = p_bot and balance >= p_amount;
  if not found then raise exception 'no_funds'; end if;
  insert into public.bets(round_id, user_id, amount) values (r.id, p_bot, round(p_amount, 2));
  if r.bets_close_at is null and not already and n + 1 >= 2 then
    select value into t from public.app_config where key = 'timing';
    update public.rounds set bets_close_at = now() + make_interval(secs => coalesce((t->>'bet_ms')::int, 15000) / 1000.0) where id = r.id;
  end if;
end $$;

create or replace function public.admin_check(p_code text) returns boolean
language sql security definer set search_path = '' as $$
  select exists(select 1 from private.admin_config
                where key = 'code_hash' and value = encode(extensions.digest(p_code, 'sha256'), 'hex'))
$$;

create or replace function public.admin_set(p_key text, p_value text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if p_key not in ('next_mod') then raise exception 'bad_key'; end if;
  if p_value is null then delete from private.admin_config where key = p_key;
  else insert into private.admin_config(key, value) values (p_key, p_value)
       on conflict (key) do update set value = excluded.value; end if;
end $$;

create or replace function public.admin_timing(p_fast boolean) returns void
language sql security definer set search_path = '' as $$
  update public.app_config set value = case when p_fast
    then '{"bet_ms":6000,"prep_ms":4000,"result_ms":3000,"fast":true}'::jsonb
    else '{"bet_ms":15000,"prep_ms":5000,"result_ms":5400,"fast":false}'::jsonb end
  where key = 'timing'
$$;

create or replace function public.admin_skip() returns void
language plpgsql security definer set search_path = '' as $$
declare s public.rounds; o public.rounds;
begin
  select * into o from public.rounds where status = 'betting' order by id desc limit 1 for update;
  -- open betting round: close it now (needs two players)
  if found and now() >= o.opens_at then
    if (select count(distinct user_id) from public.bets where round_id = o.id) >= 2 then
      update public.rounds set bets_close_at = now() where id = o.id;
    end if;
    return;
  end if;
  -- otherwise: finish the round on screen and open the next one now
  select * into s from public.rounds where status = 'settled' order by id desc limit 1;
  if found and s.ends_at > now() then
    update public.rounds set ends_at = now(), anim_end = least(anim_end, now()), prep_until = least(prep_until, now()) where id = s.id;
    update public.rounds set opens_at = now() where id = o.id;
  end if;
end $$;

-- ---------- permissions ----------
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.server_now()                 to anon, authenticated;
grant execute on function public.ensure_profile(text, text)   to authenticated;
grant execute on function public.place_bet(numeric)           to authenticated;
grant execute on function public.claim_faucet()               to authenticated;
grant execute on function public.get_round_secret(bigint), public.settle_round(bigint, text, text, boolean, uuid, int, jsonb, int),
                         public.admin_bot_bet(uuid, numeric), public.admin_check(text), public.admin_set(text, text),
                         public.admin_timing(boolean), public.admin_skip() to service_role;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
revoke execute on function private.new_round(timestamptz) from public, anon, authenticated;

-- ---------- realtime ----------
alter publication supabase_realtime add table public.rounds, public.bets, public.wallets, public.app_config;

-- ---------- seed data ----------
-- house bots, only used by the admin test menu (they bet house money)
insert into public.profiles(id, name, avatar_url, is_bot)
select gen_random_uuid(), n, 'https://api.dicebear.com/9.x/thumbs/svg?seed=bot-' || replace(n, ' ', '-'), true
from unnest(array['Night Owl','Silver Fox','Lucky Duck','Mint Panda','Paper Crane','Cold Brew','Blue Whale','Iron Monk','Quiet Storm','Odd Lemon','Velvet Moth','Green Comet']) as n;
insert into public.wallets(user_id, balance) select id, 1000000000 from public.profiles where is_bot;

select private.new_round(now());
