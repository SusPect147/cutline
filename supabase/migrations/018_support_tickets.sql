-- CUTLINE: support tickets. A player sends one message (text, or a screenshot with a caption); it arrives in the
-- support chat as one card with the player's details and two buttons: "Reply" and "Problem solved".
create table if not exists private.support_tickets (
  id          bigserial primary key,
  tg_id       bigint not null,
  lang        text not null default 'ru',
  status      text not null default 'open' check (status in ('open', 'solved')),
  admin_msg   bigint,                       -- the card's message id in the support chat (a reply to it answers the ticket)
  created_at  timestamptz not null default now(),
  answered_at timestamptz,
  solved_at   timestamptz
);
create index if not exists support_tickets_admin_msg on private.support_tickets(admin_msg);
alter table private.support_tickets enable row level security;

alter table private.support_sessions add column if not exists ticket_id bigint;
alter table private.support_sessions add column if not exists media_group text;

-- the support account pressed "Reply": its next message goes to this ticket
create table if not exists private.support_reply (
  admin_id  bigint primary key,
  ticket_id bigint not null,
  until     timestamptz not null
);
alter table private.support_reply enable row level security;


-- "Support" pressed: the next message becomes a ticket (for 30 minutes)
create or replace function public.support_open(p_tg_id bigint) returns void
language sql security definer set search_path = '' as $$
  insert into private.support_sessions(tg_id, until) values (p_tg_id, now() + interval '30 minutes')
  on conflict (tg_id) do update set until = excluded.until, ticket_id = null, media_group = null, last_head = null, last_ack = null;
$$;

create or replace function public.support_close(p_tg_id bigint) returns void
language sql security definer set search_path = '' as $$
  delete from private.support_sessions where tg_id = p_tg_id;
$$;

-- a message from the player arrived. Returns {state}: 'none' (not in support), 'new' (a new ticket was opened: id),
-- 'album' (another picture of the same album as the ticket: id, admin_msg)
create or replace function public.support_take(p_tg_id bigint, p_group text, p_lang text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s private.support_sessions; tid bigint; am bigint;
begin
  select * into s from private.support_sessions where tg_id = p_tg_id for update;
  if not found or s.until < now() then
    delete from private.support_sessions where tg_id = p_tg_id;
    return jsonb_build_object('state', 'none');
  end if;
  if s.ticket_id is not null then
    if p_group is not null and p_group = s.media_group then
      select admin_msg into am from private.support_tickets where id = s.ticket_id;
      return jsonb_build_object('state', 'album', 'id', s.ticket_id, 'admin_msg', am);
    end if;
    delete from private.support_sessions where tg_id = p_tg_id;
    return jsonb_build_object('state', 'none');
  end if;
  insert into private.support_tickets(tg_id, lang) values (p_tg_id, case when p_lang = 'ru' then 'ru' else 'en' end) returning id into tid;
  if p_group is null then
    delete from private.support_sessions where tg_id = p_tg_id;          -- one message, one ticket
  else
    update private.support_sessions set ticket_id = tid, media_group = p_group, until = now() + interval '1 minute' where tg_id = p_tg_id;
  end if;
  return jsonb_build_object('state', 'new', 'id', tid);
end $$;

create or replace function public.support_set_card(p_ticket bigint, p_admin_msg bigint) returns void
language sql security definer set search_path = '' as $$
  update private.support_tickets set admin_msg = p_admin_msg where id = p_ticket;
$$;

create or replace function public.support_ticket(p_ticket bigint, p_admin_msg bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('id', id, 'tg_id', tg_id, 'lang', lang, 'status', status, 'admin_msg', admin_msg)
    from private.support_tickets
   where (p_ticket is not null and id = p_ticket) or (p_ticket is null and admin_msg = p_admin_msg)
   limit 1
$$;

-- "Reply" pressed (p_ticket) / the support account's next message (p_ticket null: take and clear)
create or replace function public.support_reply_set(p_admin bigint, p_ticket bigint) returns void
language sql security definer set search_path = '' as $$
  insert into private.support_reply(admin_id, ticket_id, until) values (p_admin, p_ticket, now() + interval '30 minutes')
  on conflict (admin_id) do update set ticket_id = excluded.ticket_id, until = excluded.until;
$$;
create or replace function public.support_reply_take(p_admin bigint) returns bigint
language sql security definer set search_path = '' as $$
  delete from private.support_reply where admin_id = p_admin and until > now() returning ticket_id;
$$;
create or replace function public.support_reply_cancel(p_admin bigint) returns void
language sql security definer set search_path = '' as $$
  delete from private.support_reply where admin_id = p_admin;
$$;

create or replace function public.support_answered(p_ticket bigint) returns void
language sql security definer set search_path = '' as $$
  update private.support_tickets set answered_at = now() where id = p_ticket;
$$;

-- "Problem solved": returns the ticket, and whether it was still open
create or replace function public.support_solve(p_ticket bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t private.support_tickets; was text;
begin
  select * into t from private.support_tickets where id = p_ticket for update;
  if not found then return null; end if;
  was := t.status;
  update private.support_tickets set status = 'solved', solved_at = coalesce(solved_at, now()) where id = p_ticket;
  return jsonb_build_object('id', t.id, 'tg_id', t.tg_id, 'lang', t.lang, 'admin_msg', t.admin_msg, 'was_open', was = 'open');
end $$;

do $$
declare f text;
begin
  foreach f in array array['support_open(bigint)', 'support_close(bigint)', 'support_take(bigint, text, text)',
    'support_set_card(bigint, bigint)', 'support_ticket(bigint, bigint)', 'support_reply_set(bigint, bigint)',
    'support_reply_take(bigint)', 'support_reply_cancel(bigint)', 'support_answered(bigint)', 'support_solve(bigint)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
