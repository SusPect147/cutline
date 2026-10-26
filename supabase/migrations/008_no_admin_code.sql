-- CUTLINE: no admin code and no admin panel in the game any more.
-- Money is handled by the owner from the Supabase SQL editor with these functions (private schema:
-- not reachable through the public API, only by the database owner):
--   select private.money();                              -- open withdrawals (with the reconciliation), unmatched deposits, totals
--   select private.wd_paid(12, '<payout tx hash>');      -- withdrawal #12 was sent
--   select private.wd_reject(12, 'reason');              -- pending: refund the whole amount; flagged: just close it
--   select private.wd_approve(12);                       -- a flagged request checked by hand: debit it, it becomes pending
--   select private.give_deposit('<tx hash>', '<player id>');  -- credit an unmatched deposit to its owner

alter table private.withdrawals add column if not exists send_at timestamptz;
alter table private.withdrawals add column if not exists send_seqno bigint;
alter table private.withdrawals add column if not exists send_wallet text;
alter table private.withdrawals add column if not exists auto_hold boolean not null default false;

create or replace function private.money() returns jsonb
language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'withdrawals', coalesce((select jsonb_agg(x order by x.id) from (
        select w.id, w.amount, w.fee, coalesce(w.payout, w.amount) as send, w.address, w.status, w.created_at, w.send_at, w.auto_hold, w.admin_note, p.name, a.username,
               private.audit_user(w.user_id) as audit_now,
               (select jsonb_agg(jsonb_build_object('hash', d.tx_hash, 'amount', d.credited, 'from', d.sender, 'at', d.tx_time))
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
        'paid_out', (select coalesce(sum(coalesce(payout, amount)), 0) from private.withdrawals where status = 'paid'),
        'to_send', (select coalesce(sum(coalesce(payout, amount)), 0) from private.withdrawals where status = 'pending'),
        'game_fees', (select coalesce(sum(hl.fee), 0) from private.house_ledger hl join public.rounds r on r.id = hl.round_id where r.room = 'real'),
        'withdraw_fees', (select coalesce(sum(fee), 0) from private.withdrawals where status = 'paid')))
$$;

create or replace function private.wd_paid(p_id bigint, p_tx text) returns text
language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(btrim(p_tx), '') = '' then raise exception 'tx_required'; end if;
  update private.withdrawals set status = 'paid', payout_tx = btrim(p_tx), decided_at = now() where id = p_id and status = 'pending';
  if not found then raise exception 'not_pending'; end if;
  return 'paid';
end $$;

create or replace function private.wd_reject(p_id bigint, p_note text default null) returns text
language plpgsql security definer set search_path = '' as $$
declare w private.withdrawals;
begin
  select * into w from private.withdrawals where id = p_id for update;
  if not found then raise exception 'not_found'; end if;
  if w.status = 'pending' and w.send_at is not null then raise exception 'payout_in_flight'; end if;
  if w.status = 'pending' then
    perform private.real_change(w.user_id, w.amount, 'refund', 'wd:' || p_id);
    update private.withdrawals set status = 'rejected', admin_note = p_note, decided_at = now() where id = p_id;
    return 'rejected, refunded';
  elsif w.status = 'flagged' then
    update private.withdrawals set status = 'cancelled', admin_note = p_note, decided_at = now() where id = p_id;
    return 'cancelled';
  end if;
  raise exception 'not_open';
end $$;

create or replace function private.wd_approve(p_id bigint) returns text
language plpgsql security definer set search_path = '' as $$
declare w private.withdrawals;
begin
  select * into w from private.withdrawals where id = p_id for update;
  if not found or w.status <> 'flagged' then raise exception 'not_flagged'; end if;
  perform private.real_change(w.user_id, -w.amount, 'withdraw', 'wd:' || p_id);
  update private.withdrawals set status = 'pending' where id = p_id;
  return 'pending';
end $$;

create or replace function private.give_deposit(p_hash text, p_user uuid) returns numeric
language plpgsql security definer set search_path = '' as $$
declare d private.deposits; cr numeric;
begin
  select * into d from private.deposits where tx_hash = p_hash for update;
  if not found or d.status <> 'unmatched' then raise exception 'not_unmatched'; end if;
  if not exists (select 1 from public.wallets where user_id = p_user) then raise exception 'no_player'; end if;
  cr := floor(d.amount_nano / 10000000) / 100;
  update private.deposits set user_id = p_user, credited = cr, status = 'assigned' where tx_hash = p_hash;
  perform private.real_change(p_user, cr, 'deposit', 'tx:' || p_hash);
  return cr;
end $$;

revoke execute on function private.money(), private.wd_paid(bigint, text), private.wd_reject(bigint, text),
  private.wd_approve(bigint), private.give_deposit(text, uuid) from public, anon, authenticated;

-- the old code-protected functions can no longer be called from outside
revoke execute on function public.admin_money(text), public.admin_withdrawal(text, bigint, text, text, text),
  public.admin_assign_deposit(text, text, uuid), public.house_stats(text) from public, anon, authenticated;
