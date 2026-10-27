-- CUTLINE: hardening.
-- * Request limits for the game server (edge function): a simple counter per key and time window.
-- * Payouts: the server checks the database first and only talks to the blockchain when there is work to do.
-- * Sign-in: the last sign-in time is known, so the avatar is refreshed at most every 10 minutes.
-- * Invites: a friend counts after betting at least friend_min_wager Gram in PvP; rewards 0.6 / 1.2 / 3 / 6 / 12.
-- (Guest accounts are switched off and sign-in e-mails moved to a domain that can never exist: see the end.)

create table if not exists private.rate_hits (
  key       text primary key,
  win_start timestamptz not null default now(),
  n         int not null default 0
);
alter table private.rate_hits enable row level security;

-- true while the key is within p_max requests per p_secs seconds
create or replace function public.rate_hit(p_key text, p_max int, p_secs int) returns boolean
language sql security definer set search_path = '' as $$
  insert into private.rate_hits as r(key, win_start, n) values (left(p_key, 120), now(), 1)
  on conflict (key) do update set
    win_start = case when r.win_start < now() - make_interval(secs => p_secs) then now() else r.win_start end,
    n         = case when r.win_start < now() - make_interval(secs => p_secs) then 1 else r.n + 1 end
  returning n <= p_max
$$;
revoke execute on function public.rate_hit(text, int, int) from public, anon, authenticated;
grant execute on function public.rate_hit(text, int, int) to service_role;

-- is there anything for the payout run to do? (same rule as the 15 s job)
create or replace function public.payout_has_work() returns boolean
language plpgsql stable security definer set search_path = '' as $$
declare cfg jsonb; mx numeric; cap numeric; day_sum numeric;
begin
  select value into cfg from public.app_config where key = 'wallet';
  if coalesce((cfg->>'auto_payout')::boolean, true) is not true then return false; end if;
  mx := coalesce((cfg->>'auto_max')::numeric, 50);
  cap := coalesce((cfg->>'daily_cap')::numeric, 300);
  select coalesce(sum(coalesce(payout, amount)), 0) into day_sum from private.withdrawals where send_at > now() - interval '24 hours';
  return exists (select 1 from private.withdrawals where status = 'pending' and not auto_hold
                  and (send_at is not null or (coalesce(payout, amount) <= mx and day_sum + coalesce(payout, amount) <= cap)));
end $$;
revoke execute on function public.payout_has_work() from public, anon, authenticated;
grant execute on function public.payout_has_work() to service_role;

create or replace function public.tg_lookup(p_tg_id bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('user_id', a.user_id, 'photo_uid', a.photo_uid, 'avatar_url', p.avatar_url, 'updated_at', a.updated_at)
    from private.tg_accounts a join public.profiles p on p.id = a.user_id
   where a.tg_id = p_tg_id
$$;

-- invites: the friend has to bet, not just deposit
update public.app_config set value = value
  || jsonb_build_object('friend_min_wager', 0.2)
  || jsonb_build_object('list', (select jsonb_agg(case q->>'id'
        when 'ref5' then q || '{"reward": 0.6}' when 'ref10' then q || '{"reward": 1.2}'
        when 'ref25' then q || '{"reward": 3}' when 'ref50' then q || '{"reward": 6}'
        when 'ref100' then q || '{"reward": 12}' else q end order by ord)
      from jsonb_array_elements(value->'list') with ordinality as t(q, ord)))
 where key = 'quests';

create or replace function private.ref_stats(p_user uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  with cfg as (
    select coalesce((value->>'friend_min_deposit')::numeric, 0.1) as md, coalesce((value->>'friend_min_rounds')::int, 1) as mr,
           coalesce((value->>'friend_min_wager')::numeric, 0.2) as mw
      from public.app_config where key = 'quests'),
  fr as (
    select r.user_id,
           exists (select 1 from private.deposits d where d.user_id = r.user_id and d.status in ('credited', 'assigned')
                    and d.credited >= (select md from cfg)) as dep_ok,
           (select count(distinct b.round_id) from public.bets b join public.rounds ro on ro.id = b.round_id
             where b.user_id = r.user_id and b.room = 'real' and ro.status = 'settled') as played,
           (select coalesce(sum(b.amount), 0) from public.bets b join public.rounds ro on ro.id = b.round_id
             where b.user_id = r.user_id and b.room = 'real' and ro.status = 'settled') as wagered
      from private.referrals r where r.referrer_id = p_user)
  select jsonb_build_object('total', count(*), 'deposited', count(*) filter (where dep_ok),
                            'ok', count(*) filter (where dep_ok and played >= (select mr from cfg) and wagered >= (select mw from cfg)))
    from fr
$$;

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
    'friend_min_wager', coalesce(cfg->'friend_min_wager', '0.2'::jsonb),
    'friends', private.ref_stats(uid), 'progress', private.quest_progress(uid),
    'list', (select coalesce(jsonb_agg(jsonb_build_object('id', q->>'id', 'kind', q->>'kind', 'goal', q->'goal', 'reward', q->'reward',
                       'claimed', exists (select 1 from private.quest_claims c where c.user_id = uid and c.quest_id = q->>'id')) order by ord), '[]')
               from jsonb_array_elements(cfg->'list') with ordinality as t(q, ord)));
end $$;

-- old request counters are not needed after an hour
select cron.schedule('cutline-rate-cleanup', '23 * * * *', $$delete from private.rate_hits where win_start < now() - interval '1 hour'$$);

-- Sign-in accounts (run once by hand in the SQL editor, 2026-10-27; kept here for the record):
--   * every Telegram account got the address tg<telegram id>@cutline.invalid (".invalid" can never be registered,
--     so no one can receive mail for it) and no password; new accounts get a hashed address the server derives itself;
--   * the old guest accounts (@guest.cutline.app) were banned and their sessions removed;
--   * new sign-ups through the public API are switched off (Authentication -> Sign In / Providers).
--
-- update auth.users u set email = 'tg' || a.tg_id || '@cutline.invalid', encrypted_password = ''
--   from private.tg_accounts a where a.user_id = u.id;
-- update auth.identities i set identity_data = i.identity_data || jsonb_build_object('email', u.email)
--   from auth.users u where u.id = i.user_id and i.provider = 'email';
-- update auth.users set banned_until = '2999-01-01' where email like '%@guest.cutline.app';
-- delete from auth.sessions s using auth.users u where u.id = s.user_id and u.email like '%@guest.cutline.app';
