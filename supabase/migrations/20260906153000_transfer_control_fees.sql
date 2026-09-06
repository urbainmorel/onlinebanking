create table if not exists public.transfer_control_fees (
  currency text primary key check (currency in ('EUR', 'USD', 'CAD', 'CHF', 'GBP')),
  dual_review_fee_minor bigint not null default 15000 check (dual_review_fee_minor >= 0),
  escalation_fee_minor bigint not null default 25000 check (escalation_fee_minor >= 0),
  compliance_fee_minor bigint not null default 35000 check (compliance_fee_minor >= 0),
  final_authorization_fee_minor bigint not null default 50000 check (final_authorization_fee_minor >= 0),
  updated_by uuid references public.staff_members(user_id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.transfer_control_fees is
  'Branch manager configurable fee tiers required for each wire transfer review stage.';

create trigger transfer_control_fees_set_updated_at
before update on public.transfer_control_fees
for each row execute function private.set_updated_at();

alter table public.transfer_control_fees enable row level security;

create policy transfer_control_fees_authenticated_select
on public.transfer_control_fees
for select
to authenticated
using (true);

revoke all on table public.transfer_control_fees
from public, anon, authenticated, service_role;
grant select on table public.transfer_control_fees to authenticated;
grant all on table public.transfer_control_fees to service_role;

insert into public.transfer_control_fees (
  currency,
  dual_review_fee_minor,
  escalation_fee_minor,
  compliance_fee_minor,
  final_authorization_fee_minor
)
values
  ('EUR', 15000, 25000, 35000, 50000),
  ('USD', 15000, 25000, 35000, 50000),
  ('CAD', 15000, 25000, 35000, 50000),
  ('CHF', 15000, 25000, 35000, 50000),
  ('GBP', 15000, 25000, 35000, 50000)
on conflict (currency) do nothing;

create or replace function public.update_transfer_control_fees(
  p_currency text,
  p_dual_review_fee_minor bigint,
  p_escalation_fee_minor bigint,
  p_compliance_fee_minor bigint,
  p_final_authorization_fee_minor bigint
) returns public.transfer_control_fees
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_id uuid := private.ensure_branch_manager();
  normalized_currency text := upper(trim(coalesce(p_currency, '')));
  updated_row public.transfer_control_fees;
begin
  if normalized_currency not in ('EUR', 'USD', 'CAD', 'CHF', 'GBP') then
    raise exception 'INVALID_CURRENCY' using errcode = '22023';
  end if;

  if p_dual_review_fee_minor < 0 or p_escalation_fee_minor < 0 or p_compliance_fee_minor < 0 or p_final_authorization_fee_minor < 0 then
    raise exception 'INVALID_FEE_AMOUNT' using errcode = '22023';
  end if;

  insert into public.transfer_control_fees (
    currency,
    dual_review_fee_minor,
    escalation_fee_minor,
    compliance_fee_minor,
    final_authorization_fee_minor,
    updated_by,
    updated_at
  ) values (
    normalized_currency,
    p_dual_review_fee_minor,
    p_escalation_fee_minor,
    p_compliance_fee_minor,
    p_final_authorization_fee_minor,
    caller_id,
    now()
  )
  on conflict (currency) do update set
    dual_review_fee_minor = excluded.dual_review_fee_minor,
    escalation_fee_minor = excluded.escalation_fee_minor,
    compliance_fee_minor = excluded.compliance_fee_minor,
    final_authorization_fee_minor = excluded.final_authorization_fee_minor,
    updated_by = caller_id,
    updated_at = now()
  returning * into updated_row;

  insert into public.audit_events (
    actor_id,
    action,
    entity_type,
    entity_id,
    payload
  ) values (
    caller_id,
    'branch_manager_update_transfer_control_fees',
    'transfer_control_fees',
    normalized_currency,
    jsonb_build_object(
      'currency', normalized_currency,
      'dualReviewFeeMinor', p_dual_review_fee_minor,
      'escalationFeeMinor', p_escalation_fee_minor,
      'complianceFeeMinor', p_compliance_fee_minor,
      'finalAuthorizationFeeMinor', p_final_authorization_fee_minor
    )
  );

  return updated_row;
end;
$$;

revoke all on function public.update_transfer_control_fees(text, bigint, bigint, bigint, bigint) from public;
grant all on function public.update_transfer_control_fees(text, bigint, bigint, bigint, bigint) to authenticated;
grant all on function public.update_transfer_control_fees(text, bigint, bigint, bigint, bigint) to service_role;

create or replace function private.enqueue_transfer_check_validation_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  transfer_row public.transfer_intents;
  fee_row public.transfer_control_fees;
  recipient_email text;
  next_fee_minor bigint := 0;
begin
  select transfer.*
  into transfer_row
  from public.transfer_intents as transfer
  where transfer.id = new.transfer_id;

  if not found then
    return new;
  end if;

  select profile.email
  into recipient_email
  from public.profiles as profile
  where profile.user_id = transfer_row.owner_id;

  if recipient_email is null then
    return new;
  end if;

  select fee.*
  into fee_row
  from public.transfer_control_fees as fee
  where fee.currency = transfer_row.currency;

  next_fee_minor := case new.check_kind
    when 'dual_review' then coalesce(fee_row.escalation_fee_minor, 25000)
    when 'escalation' then coalesce(fee_row.compliance_fee_minor, 35000)
    when 'compliance' then coalesce(fee_row.final_authorization_fee_minor, 50000)
    else 0
  end;

  insert into public.transactional_email_outbox (
    event_key,
    recipient_id,
    recipient_email,
    template_key,
    entity_type,
    entity_id,
    payload
  ) values (
    'transfer_review_checks:' || new.id::text || ':completed',
    transfer_row.owner_id,
    recipient_email,
    'transfer_check_validated',
    'transfer',
    transfer_row.id,
    jsonb_build_object(
      'checkKind', new.check_kind,
      'amountMinor', transfer_row.amount_minor,
      'currency', transfer_row.currency,
      'recipientName', transfer_row.recipient_name,
      'requiredFeeAmountMinor', next_fee_minor,
      'actionPath', '/myaccount'
    )
  )
  on conflict (event_key) do nothing;

  return new;
end;
$$;

create or replace function private.enqueue_financial_workflow_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  email_template text;
  entity_kind text;
  recipient uuid;
  email_address text;
  email_payload jsonb;
  fee_row public.transfer_control_fees;
  next_fee_minor bigint := 15000;
begin
  if tg_op = 'UPDATE' and new.status = old.status then
    return new;
  end if;

  if tg_table_name = 'transfer_intents' then
    entity_kind := 'transfer';
    recipient := new.owner_id;
    email_template := case new.status
      when 'submitted' then 'transfer_submitted'
      when 'approved_for_external_execution' then 'transfer_approved'
      when 'external_settlement_confirmed' then 'transfer_completed'
      when 'rejected' then 'transfer_rejected'
      when 'external_failed' then 'transfer_failed'
      else null
    end;

    if new.status = 'submitted' then
      select fee.*
      into fee_row
      from public.transfer_control_fees as fee
      where fee.currency = new.currency;

      next_fee_minor := coalesce(fee_row.dual_review_fee_minor, 15000);
    end if;

    email_payload := jsonb_build_object(
      'amountMinor', new.amount_minor,
      'currency', new.currency,
      'recipientName', new.recipient_name,
      'requiredFeeAmountMinor', next_fee_minor
    );
  elsif tg_table_name = 'loan_applications' then
    entity_kind := 'loan';
    recipient := new.owner_id;
    email_template := case new.status
      when 'submitted' then 'loan_submitted'
      when 'approved_for_external_funding' then 'loan_approved'
      when 'external_settlement_confirmed' then 'loan_disbursed'
      when 'rejected' then 'loan_rejected'
      when 'external_failed' then 'loan_failed'
      else null
    end;
    email_payload := jsonb_build_object(
      'amountMinor', new.requested_amount_minor,
      'currency', new.currency,
      'reference', new.reference
    );
  else
    return new;
  end if;

  if email_template is null then
    return new;
  end if;

  select email
  into email_address
  from public.profiles
  where user_id = recipient;

  if email_address is null then
    return new;
  end if;

  insert into public.transactional_email_outbox (
    event_key,
    recipient_id,
    recipient_email,
    template_key,
    entity_type,
    entity_id,
    payload
  )
  values (
    tg_table_name || ':' || new.id::text || ':' || new.status,
    recipient,
    email_address,
    email_template,
    entity_kind,
    new.id,
    email_payload
  )
  on conflict (event_key) do nothing;

  return new;
end;
$$;
