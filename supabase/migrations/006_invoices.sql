-- CUTLINE: deposits without a comment.
-- The player picks an amount and gets an invoice: that amount plus a unique tail of a few thousandths
-- (e.g. 10.004371 Gram). A transfer of exactly that many nanograms to the house wallet while the invoice is open
-- is credited to its owner. The tail is below 0.01, so the player is credited exactly the amount they chose.
-- Rules that keep this safe:
--   * an exact amount is never handed out twice within 48 hours, so a late payment can't land on someone else;
--   * a transfer only matches an invoice that was open at the moment of the transfer (chain time);
--   * a transfer with the player's code as the comment still works as before (TON Connect sends it automatically).

create table if not exists private.deposit_invoices (
  id           bigint generated always as identity primary key,
  user_id      uuid not null references public.profiles(id) on delete cascade,
  amount_nano  numeric(30,0) not null check (amount_nano > 0),
  status       text not null default 'open' check (status in ('open', 'paid', 'expired')),
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null,
  paid_tx      text
);
create index if not exists deposit_invoices_nano_idx on private.deposit_invoices(amount_nano, created_at desc);
create index if not exists deposit_invoices_user_idx on private.deposit_invoices(user_id, created_at desc);
alter table private.deposit_invoices enable row level security;

create or replace function public.create_invoice(p_amount numeric) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare uid uuid := auth.uid(); cfg jsonb; base numeric; nano numeric; inv private.deposit_invoices; tries int := 0; recent int;
begin
  if uid is null then raise exception 'auth_required'; end if;
  if not exists (select 1 from public.wallets where user_id = uid) then raise exception 'tg_required'; end if;
  select value into cfg from public.app_config where key = 'wallet';
  base := round(p_amount, 2);
  if base is null or base < coalesce((cfg->>'min_deposit')::numeric, 0.1) or base > 100000 then raise exception 'bad_amount'; end if;
  -- the same open invoice is reused while it has at least 10 minutes left
  select * into inv from private.deposit_invoices
   where user_id = uid and status = 'open' and expires_at > now() + interval '10 minutes'
     and floor(amount_nano / 10000000) = base * 100
   order by id desc limit 1;
  if found then
    return jsonb_build_object('id', inv.id, 'nano', inv.amount_nano::text, 'expires_at', inv.expires_at, 'address', cfg->>'address');
  end if;
  select count(*) into recent from private.deposit_invoices where user_id = uid and created_at > now() - interval '1 hour';
  if recent >= 20 then raise exception 'too_many_invoices'; end if;
  perform pg_advisory_xact_lock(hashtext('cutline.deposit_invoices'));
  loop
    tries := tries + 1;
    nano := base * 1000000000 + (1 + floor(random() * 9998))::numeric * 1000;   -- tail 0.000001 … 0.009999 Gram
    exit when not exists (select 1 from private.deposit_invoices where amount_nano = nano and created_at > now() - interval '48 hours');
    if tries > 50 then raise exception 'busy'; end if;
  end loop;
  insert into private.deposit_invoices(user_id, amount_nano, expires_at)
  values (uid, nano, now() + interval '30 minutes') returning * into inv;
  return jsonb_build_object('id', inv.id, 'nano', inv.amount_nano::text, 'expires_at', inv.expires_at, 'address', cfg->>'address');
end $$;

-- same as before, plus: a transfer without a valid code is matched to an open invoice by its exact amount
create or replace function public.credit_deposit(p_hash text, p_lt bigint, p_sender text, p_nano numeric, p_comment text, p_time timestamptz)
returns text
language plpgsql security definer set search_path = '' as $$
declare uid uuid; cr numeric; v_code text; n int; inv_id bigint;
begin
  if p_hash is null or p_nano is null or p_nano <= 0 then return 'skip'; end if;
  if exists (select 1 from private.deposits where tx_hash = p_hash) then return 'dup'; end if;
  v_code := upper(btrim(coalesce(p_comment, '')));
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
  cr := floor(p_nano / 10000000) / 100;               -- credited in 0.01 steps; the exact amount is kept in amount_nano
  if uid is null then
    if p_nano < 10000000 then return 'spam'; end if;   -- dust and on-chain spam are not even stored
    insert into private.deposits(tx_hash, lt, user_id, sender, amount_nano, credited, comment, status, tx_time)
    values (p_hash, p_lt, null, p_sender, p_nano, 0, left(p_comment, 200), 'unmatched', p_time) on conflict do nothing;
    return 'unmatched';
  end if;
  insert into private.deposits(tx_hash, lt, user_id, sender, amount_nano, credited, comment, status, tx_time)
  values (p_hash, p_lt, uid, p_sender, p_nano, case when cr > 0 then cr else 0 end, left(p_comment, 200),
          case when cr > 0 then 'credited' else 'ignored' end, p_time)
  on conflict do nothing;
  get diagnostics n = row_count;
  if n = 0 then return 'dup'; end if;                  -- a parallel scan got here first
  if inv_id is not null then update private.deposit_invoices set status = 'paid', paid_tx = p_hash where id = inv_id; end if;
  if cr > 0 then perform private.real_change(uid, cr, 'deposit', 'tx:' || p_hash); end if;
  return case when cr > 0 then 'credited' else 'ignored' end;
end $$;

-- a transfer of an invoice amount that came in after the invoice expired lands in "unmatched";
-- support can still give it to the invoice owner with admin_assign_deposit (the admin list shows the match)
create or replace function public.admin_money(p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not public.admin_check(coalesce(p_code, '')) then raise exception 'bad_code'; end if;
  return jsonb_build_object(
    'withdrawals', coalesce((select jsonb_agg(x order by x.id) from (
        select w.id, w.amount, w.address, w.status, w.created_at, w.audit, p.name, a.username,
               private.audit_user(w.user_id) as audit_now,
               (select jsonb_agg(jsonb_build_object('hash', d.tx_hash, 'amount', d.credited, 'nano', d.amount_nano, 'from', d.sender, 'at', d.tx_time))
                  from private.deposits d where d.user_id = w.user_id and d.status in ('credited', 'assigned')) as deposits
          from private.withdrawals w join public.profiles p on p.id = w.user_id
          left join private.tg_accounts a on a.user_id = w.user_id
         where w.status in ('pending', 'flagged') limit 100) x), '[]'),
    'unmatched', coalesce((select jsonb_agg(jsonb_build_object('hash', d.tx_hash, 'nano', d.amount_nano, 'from', d.sender, 'comment', d.comment, 'at', d.tx_time,
        'invoice_user', (select i.user_id from private.deposit_invoices i where i.amount_nano = d.amount_nano
                          and i.created_at > d.tx_time - interval '48 hours' and i.created_at <= d.tx_time order by i.id desc limit 1)) order by d.tx_time desc)
        from private.deposits d where d.status = 'unmatched'), '[]'),
    'totals', jsonb_build_object(
        'balances', (select coalesce(sum(balance), 0) from public.wallets),
        'deposited', (select coalesce(sum(credited), 0) from private.deposits where status in ('credited', 'assigned')),
        'paid_out', (select coalesce(sum(amount), 0) from private.withdrawals where status = 'paid'),
        'pending', (select coalesce(sum(amount), 0) from private.withdrawals where status = 'pending'),
        'fees', (select coalesce(sum(fee), 0) from private.house_ledger hl join public.rounds r on r.id = hl.round_id where r.room = 'real')));
end $$;

revoke execute on function public.create_invoice(numeric) from public, anon;
grant execute on function public.create_invoice(numeric) to authenticated;
revoke execute on function public.credit_deposit(text, bigint, text, numeric, text, timestamptz) from public, anon, authenticated;
grant execute on function public.credit_deposit(text, bigint, text, numeric, text, timestamptz) to service_role;
revoke execute on function public.admin_money(text) from public;
grant execute on function public.admin_money(text) to anon, authenticated;
