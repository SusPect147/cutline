-- CUTLINE: the bot's chat (/start menu). The "bot" edge function asks for a player's invite link and progress
-- by Telegram id. Only the server (service role) can call it.
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
    'min_deposit', coalesce(cfg->'friend_min_deposit', '0.1'::jsonb), 'min_wager', coalesce(cfg->'friend_min_wager', '0.2'::jsonb),
    'friends', private.ref_stats(uid),
    'ladder', (select coalesce(jsonb_agg(jsonb_build_object('goal', q->'goal', 'reward', q->'reward',
                 'claimed', exists (select 1 from private.quest_claims c where c.user_id = uid and c.quest_id = q->>'id')) order by ord), '[]')
               from jsonb_array_elements(cfg->'list') with ordinality as t(q, ord) where q->>'kind' = 'friends'));
end $$;
revoke execute on function public.bot_ref_info(bigint) from public, anon, authenticated;
grant execute on function public.bot_ref_info(bigint) to service_role;
