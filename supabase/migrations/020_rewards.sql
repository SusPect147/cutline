-- CUTLINE: bigger rewards, paid for out of the commission, and conditions that make farming them with extra accounts a loss.
-- * "Play N rounds" and "Win" count only PvP rounds where the game took a commission.
-- * A friend counts after depositing at least friend_min_deposit in total, playing friend_min_rounds such rounds,
--   and their bets having brought the game friend_min_fee of commission (their share of each round's commission, by stake).
--   The rewards per friend stay at or below that commission, so inviting your own extra accounts never pays.

create or replace function private.quest_progress(p_user uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'rounds', (select count(distinct b.round_id) from public.bets b join public.rounds r on r.id = b.round_id
                where b.user_id = p_user and b.room = 'real' and r.status = 'settled' and coalesce(r.fee, 0) > 0),
    'wins', (select count(*) from public.rounds where winner_id = p_user and room = 'real' and status = 'settled' and coalesce(fee, 0) > 0),
    'friends', (private.ref_stats(p_user)->>'ok')::int)
$$;

create or replace function private.ref_stats(p_user uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
  with cfg as (
    select coalesce((value->>'friend_min_deposit')::numeric, 0.5) as md, coalesce((value->>'friend_min_rounds')::int, 3) as mr,
           coalesce((value->>'friend_min_fee')::numeric, 0.3) as mf
      from public.app_config where key = 'quests'),
  fr as (
    select r.user_id,
           (select coalesce(sum(d.credited), 0) from private.deposits d
             where d.user_id = r.user_id and d.status in ('credited', 'assigned')) as deposited,
           x.played, x.fee_paid
      from private.referrals r
      cross join lateral (
        select count(*) as played, coalesce(sum(s.fee * s.stake / nullif(s.pot, 0)), 0) as fee_paid
          from (select ro.fee, ro.pot, sum(b.amount) as stake
                  from public.bets b join public.rounds ro on ro.id = b.round_id
                 where b.user_id = r.user_id and b.room = 'real' and ro.status = 'settled' and coalesce(ro.fee, 0) > 0
                 group by ro.id, ro.fee, ro.pot) s) x
     where r.referrer_id = p_user)
  select jsonb_build_object('total', count(*),
                            'deposited', count(*) filter (where deposited >= (select md from cfg)),
                            'ok', count(*) filter (where deposited >= (select md from cfg) and played >= (select mr from cfg)
                                                     and fee_paid >= (select mf from cfg)))
    from fr
$$;
revoke execute on function private.quest_progress(uuid) from public, anon, authenticated;
revoke execute on function private.ref_stats(uuid) from public, anon, authenticated;

-- the new rewards and friend conditions
update public.app_config set value = (value - 'friend_min_wager')
  || jsonb_build_object('friend_min_deposit', 0.5, 'friend_min_rounds', 3, 'friend_min_fee', 0.3, 'friend_rounds_hint', 10)
  || jsonb_build_object('list', (select jsonb_agg(case q->>'id'
        when 'play10' then q || '{"reward": 0.1}'  when 'play50' then q || '{"reward": 0.35}'
        when 'ref5'   then q || '{"reward": 1}'    when 'ref10'  then q || '{"reward": 2}'
        when 'ref25'  then q || '{"reward": 4}'    when 'ref50'  then q || '{"reward": 8}'
        when 'ref100' then q || '{"reward": 16}'   else q end order by ord)
      from jsonb_array_elements(value->'list') with ordinality as t(q, ord)))
 where key = 'quests';

-- the Tasks page and the bot show the new conditions
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
    'friend_min_fee', cfg->'friend_min_fee', 'friend_rounds_hint', cfg->'friend_rounds_hint',
    'friends', private.ref_stats(uid), 'progress', private.quest_progress(uid),
    'list', (select coalesce(jsonb_agg(jsonb_build_object('id', q->>'id', 'kind', q->>'kind', 'goal', q->'goal', 'reward', q->'reward',
                       'claimed', exists (select 1 from private.quest_claims c where c.user_id = uid and c.quest_id = q->>'id')) order by ord), '[]')
               from jsonb_array_elements(cfg->'list') with ordinality as t(q, ord)));
end $$;

create or replace function public.bot_ref_info(p_tg_id bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid; cfg jsonb; code text;
begin
  select user_id into uid from private.tg_accounts where tg_id = p_tg_id;
  select value into cfg from public.app_config where key = 'quests';
  if cfg is null then return jsonb_build_object('enabled', false); end if;
  if uid is null then
    return jsonb_build_object('enabled', coalesce((cfg->>'enabled')::boolean, false), 'account', false);
  end if;
  code := private.ref_code(uid);
  return jsonb_build_object(
    'enabled', coalesce((cfg->>'enabled')::boolean, false), 'account', true,
    'link', replace(coalesce(cfg->>'ref_link', ''), '{code}', 'r_' || code),
    'min_deposit', coalesce(cfg->'friend_min_deposit', '0.5'::jsonb), 'min_fee', coalesce(cfg->'friend_min_fee', '0.3'::jsonb),
    'rounds_hint', coalesce(cfg->'friend_rounds_hint', '10'::jsonb),
    'friends', private.ref_stats(uid),
    'ladder', (select coalesce(jsonb_agg(jsonb_build_object('goal', q->'goal', 'reward', q->'reward',
                 'claimed', exists (select 1 from private.quest_claims c where c.user_id = uid and c.quest_id = q->>'id')) order by ord), '[]')
               from jsonb_array_elements(cfg->'list') with ordinality as t(q, ord) where q->>'kind' = 'friends'));
end $$;
revoke execute on function public.bot_ref_info(bigint) from public, anon, authenticated;
grant execute on function public.bot_ref_info(bigint) to service_role;
