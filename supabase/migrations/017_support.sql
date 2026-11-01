-- CUTLINE: support chat in the bot. After "Support" is pressed, the player's messages (text, screenshots, files)
-- are passed on to the support account for 30 minutes (the window renews with every message; /start leaves it).
create table if not exists private.support_sessions (
  tg_id     bigint primary key,
  until     timestamptz not null,
  last_head timestamptz,          -- when the player's details were last sent to support (sent at most once a minute)
  last_ack  timestamptz           -- when the player was last told "sent" (at most every 20 s, so albums do not spam)
);
alter table private.support_sessions enable row level security;

-- p_mode: 'open' (Support pressed), 'msg' (a message arrived), 'close' (/start)
-- returns {active, head, ack}: is the window open, should the details header be sent, should the player be told "sent"
create or replace function public.support_touch(p_tg_id bigint, p_mode text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s private.support_sessions; head boolean := false; ack boolean := false;
begin
  if p_mode = 'close' then
    delete from private.support_sessions where tg_id = p_tg_id;
    return jsonb_build_object('active', false);
  end if;
  if p_mode = 'open' then
    insert into private.support_sessions(tg_id, until) values (p_tg_id, now() + interval '30 minutes')
    on conflict (tg_id) do update set until = excluded.until;
    return jsonb_build_object('active', true);
  end if;
  select * into s from private.support_sessions where tg_id = p_tg_id for update;
  if not found or s.until < now() then return jsonb_build_object('active', false); end if;
  head := s.last_head is null or s.last_head < now() - interval '1 minute';
  ack := s.last_ack is null or s.last_ack < now() - interval '20 seconds';
  update private.support_sessions set until = now() + interval '30 minutes',
         last_head = case when head then now() else last_head end,
         last_ack  = case when ack then now() else last_ack end
   where tg_id = p_tg_id;
  return jsonb_build_object('active', true, 'head', head, 'ack', ack);
end $$;
revoke execute on function public.support_touch(bigint, text) from public, anon, authenticated;
grant execute on function public.support_touch(bigint, text) to service_role;

-- closed windows are not needed for long
select cron.schedule('cutline-support-cleanup', '41 4 * * *', $$delete from private.support_sessions where until < now() - interval '1 day'$$);
