-- CUTLINE: automatic payouts.
-- The edge function (action "payouts", run by the game every minute and right after a request) pays pending
-- withdrawals from the payout wallet whose recovery phrase is the PAYOUT_MNEMONIC secret. Nothing is sent
-- without that secret. Safety rules:
--   * one payout at a time; the wallet's seqno is stored BEFORE sending, so a transfer can never go out twice;
--   * the player's balance is reconciled again and all their deposits are re-checked on chain right before paying;
--   * a payout is marked paid only when its transaction (comment "CUTLINE payout #id") is seen on chain;
--   * limits: auto_max per withdrawal and daily_cap per 24 hours (app_config.wallet); anything above waits for
--     the owner (private.wd_paid / private.wd_reject in the SQL editor);
--   * if something looks wrong the request is put on hold (auto_hold) with a note, for the owner to decide.

create table if not exists private.payout_state (
  id        int primary key default 1 check (id = 1),
  last_run  timestamptz not null default 'epoch'
);
insert into private.payout_state(id) values (1) on conflict do nothing;
alter table private.payout_state enable row level security;

create or replace function public.payout_slot(p_gap_ms int) returns boolean
language sql security definer set search_path = '' as $$
  update private.payout_state set last_run = now()
   where id = 1 and last_run < now() - make_interval(secs => p_gap_ms / 1000.0)
  returning true
$$;

create or replace function public.payout_inflight() returns jsonb
language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'address', address, 'nano', (coalesce(payout, amount) * 1000000000)::bigint::text,
    'seqno', send_seqno, 'wallet', send_wallet, 'sent_at', send_at) order by id), '[]')
  from private.withdrawals where status = 'pending' and send_at is not null
$$;

-- the next request that may be paid automatically, or null
create or replace function public.payout_next() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare cfg jsonb; w private.withdrawals; a jsonb; mx numeric; cap numeric; day_sum numeric;
begin
  select value into cfg from public.app_config where key = 'wallet';
  if coalesce((cfg->>'auto_payout')::boolean, true) is not true then return null; end if;
  mx := coalesce((cfg->>'auto_max')::numeric, 50);
  cap := coalesce((cfg->>'daily_cap')::numeric, 300);
  select coalesce(sum(coalesce(payout, amount)), 0) into day_sum from private.withdrawals
   where send_at > now() - interval '24 hours';
  for w in select * from private.withdrawals
            where status = 'pending' and send_at is null and not auto_hold
            order by id loop
    if coalesce(w.payout, w.amount) > mx then continue; end if;
    if day_sum + coalesce(w.payout, w.amount) > cap then return null; end if;
    a := private.audit_user(w.user_id);
    -- the request was already debited, so the balance check is "ledger and sources agree"
    if not (a->>'ok')::boolean then
      update private.withdrawals set auto_hold = true, admin_note = 'auto: balance does not reconcile' where id = w.id;
      continue;
    end if;
    return jsonb_build_object('id', w.id, 'address', w.address, 'nano', (coalesce(w.payout, w.amount) * 1000000000)::bigint::text,
      'deposits', coalesce((select jsonb_agg(d.tx_hash) from private.deposits d where d.user_id = w.user_id and d.status = 'credited'), '[]'));
  end loop;
  return null;
end $$;

create or replace function public.payout_claim(p_id bigint, p_seqno bigint, p_wallet text) returns boolean
language sql security definer set search_path = '' as $$
  update private.withdrawals set send_at = now(), send_seqno = p_seqno, send_wallet = p_wallet
   where id = p_id and status = 'pending' and send_at is null and not auto_hold
  returning true
$$;

create or replace function public.payout_done(p_id bigint, p_tx text) returns boolean
language sql security definer set search_path = '' as $$
  update private.withdrawals set status = 'paid', payout_tx = p_tx, decided_at = now(), admin_note = 'auto'
   where id = p_id and status = 'pending' and send_at is not null
  returning true
$$;

-- the transfer provably never executed (its validity window passed and the seqno did not move): try again later
create or replace function public.payout_reset(p_id bigint) returns boolean
language sql security definer set search_path = '' as $$
  update private.withdrawals set send_at = null, send_seqno = null, send_wallet = null
   where id = p_id and status = 'pending' and send_at is not null
  returning true
$$;

create or replace function public.payout_hold(p_id bigint, p_note text) returns boolean
language sql security definer set search_path = '' as $$
  update private.withdrawals set auto_hold = true, admin_note = left(p_note, 300)
   where id = p_id and status = 'pending'
  returning true
$$;

revoke execute on function public.payout_slot(int), public.payout_inflight(), public.payout_next(),
  public.payout_claim(bigint, bigint, text), public.payout_done(bigint, text), public.payout_reset(bigint),
  public.payout_hold(bigint, text) from public, anon, authenticated;
grant execute on function public.payout_slot(int), public.payout_inflight(), public.payout_next(),
  public.payout_claim(bigint, bigint, text), public.payout_done(bigint, text), public.payout_reset(bigint),
  public.payout_hold(bigint, text) to service_role;
