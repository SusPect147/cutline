-- CUTLINE: Telegram-only accounts.
-- A player account exists only after the `game` edge function has checked Telegram's signature
-- on the Mini App launch data. Name and avatar are written by the server, never by the client.

-- players can no longer create their own profile / wallet (the old function stays, but nobody but the owner may call it)
revoke execute on function public.ensure_profile(text, text) from public, anon, authenticated;

create table private.tg_accounts (
  tg_id       bigint primary key,
  user_id     uuid not null unique references public.profiles(id) on delete cascade,
  photo_uid   text,                          -- Telegram file_unique_id of the cached avatar
  updated_at  timestamptz not null default now()
);
alter table private.tg_accounts enable row level security;

-- service role only: what we already know about this Telegram user
create or replace function public.tg_lookup(p_tg_id bigint) returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object('user_id', a.user_id, 'photo_uid', a.photo_uid, 'avatar_url', p.avatar_url)
    from private.tg_accounts a join public.profiles p on p.id = a.user_id
   where a.tg_id = p_tg_id
$$;

-- service role only: create or refresh the profile; the starting wallet (10) is created once
create or replace function public.tg_upsert_profile(p_user uuid, p_tg_id bigint, p_name text, p_avatar text, p_photo_uid text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare nm text; av text; w public.wallets;
begin
  nm := left(btrim(regexp_replace(coalesce(p_name, ''), '[\r\n\t<>]', '', 'g')), 24);
  if char_length(nm) = 0 then nm := 'Player'; end if;
  av := case when p_avatar ~ '^https://(lyuvjhzbcpeazzsvyida\.supabase\.co/storage/v1/object/public/avatars/|api\.dicebear\.com/|t\.me/)'
              and char_length(p_avatar) < 400 then p_avatar else null end;
  insert into public.profiles(id, name, avatar_url) values (p_user, nm, av)
  on conflict (id) do update set name = excluded.name, avatar_url = coalesce(excluded.avatar_url, public.profiles.avatar_url);
  insert into private.tg_accounts(tg_id, user_id, photo_uid) values (p_tg_id, p_user, p_photo_uid)
  on conflict (tg_id) do update set photo_uid = coalesce(excluded.photo_uid, private.tg_accounts.photo_uid), updated_at = now();
  insert into public.wallets(user_id, balance) values (p_user, 10) on conflict (user_id) do nothing;
  select * into w from public.wallets where user_id = p_user;
  return jsonb_build_object('balance', w.balance, 'last_faucet_round', w.last_faucet_round, 'name', nm,
    'avatar_url', (select avatar_url from public.profiles where id = p_user));
end $$;

revoke execute on function public.tg_lookup(bigint), public.tg_upsert_profile(uuid, bigint, text, text, text) from public, anon, authenticated;
grant execute on function public.tg_lookup(bigint), public.tg_upsert_profile(uuid, bigint, text, text, text) to service_role;

-- public bucket for avatars copied from Telegram (only the server uploads)
insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 1048576, array['image/jpeg', 'image/png'])
on conflict (id) do nothing;
