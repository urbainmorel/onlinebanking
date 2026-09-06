-- Add fee calculation modes (fixed vs percentage) and rates to transfer_control_fees

alter table public.transfer_control_fees
  add column if not exists dual_review_fee_mode text not null default 'fixed' check (dual_review_fee_mode in ('fixed', 'percentage')),
  add column if not exists dual_review_fee_rate numeric(5,2) not null default 1.00 check (dual_review_fee_rate >= 0),
  add column if not exists escalation_fee_mode text not null default 'fixed' check (escalation_fee_mode in ('fixed', 'percentage')),
  add column if not exists escalation_fee_rate numeric(5,2) not null default 1.50 check (escalation_fee_rate >= 0),
  add column if not exists compliance_fee_mode text not null default 'fixed' check (compliance_fee_mode in ('fixed', 'percentage')),
  add column if not exists compliance_fee_rate numeric(5,2) not null default 2.00 check (compliance_fee_rate >= 0),
  add column if not exists final_authorization_fee_mode text not null default 'fixed' check (final_authorization_fee_mode in ('fixed', 'percentage')),
  add column if not exists final_authorization_fee_rate numeric(5,2) not null default 2.50 check (final_authorization_fee_rate >= 0);

comment on column public.transfer_control_fees.dual_review_fee_mode is 'Calculation mode for step 1 fee: fixed (amount) or percentage (% of transfer amount).';
comment on column public.transfer_control_fees.dual_review_fee_rate is 'Percentage rate for step 1 fee when dual_review_fee_mode = percentage.';

create or replace function public.update_transfer_control_fees(
  p_currency text,
  p_dual_review_fee_minor bigint,
  p_escalation_fee_minor bigint,
  p_compliance_fee_minor bigint,
  p_final_authorization_fee_minor bigint,
  p_dual_review_fee_mode text default 'fixed',
  p_dual_review_fee_rate numeric default 1.00,
  p_escalation_fee_mode text default 'fixed',
  p_escalation_fee_rate numeric default 1.50,
  p_compliance_fee_mode text default 'fixed',
  p_compliance_fee_rate numeric default 2.00,
  p_final_authorization_fee_mode text default 'fixed',
  p_final_authorization_fee_rate numeric default 2.50
) returns public.transfer_control_fees
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_id uuid := private.ensure_branch_manager();
  normalized_currency text := upper(trim(coalesce(p_currency, '')));
  v_dual_mode text := lower(trim(coalesce(p_dual_review_fee_mode, 'fixed')));
  v_escalation_mode text := lower(trim(coalesce(p_escalation_fee_mode, 'fixed')));
  v_compliance_mode text := lower(trim(coalesce(p_compliance_fee_mode, 'fixed')));
  v_final_mode text := lower(trim(coalesce(p_final_authorization_fee_mode, 'fixed')));
  updated_row public.transfer_control_fees;
begin
  if normalized_currency not in ('EUR', 'USD', 'CAD', 'CHF', 'GBP') then
    raise exception 'INVALID_CURRENCY' using errcode = '22023';
  end if;

  if p_dual_review_fee_minor < 0 or p_escalation_fee_minor < 0 or p_compliance_fee_minor < 0 or p_final_authorization_fee_minor < 0 then
    raise exception 'INVALID_FEE_AMOUNT' using errcode = '22023';
  end if;

  if v_dual_mode not in ('fixed', 'percentage') or
     v_escalation_mode not in ('fixed', 'percentage') or
     v_compliance_mode not in ('fixed', 'percentage') or
     v_final_mode not in ('fixed', 'percentage') then
    raise exception 'INVALID_FEE_MODE' using errcode = '22023';
  end if;

  if p_dual_review_fee_rate < 0 or p_escalation_fee_rate < 0 or p_compliance_fee_rate < 0 or p_final_authorization_fee_rate < 0 then
    raise exception 'INVALID_FEE_RATE' using errcode = '22023';
  end if;

  insert into public.transfer_control_fees (
    currency,
    dual_review_fee_minor,
    escalation_fee_minor,
    compliance_fee_minor,
    final_authorization_fee_minor,
    dual_review_fee_mode,
    dual_review_fee_rate,
    escalation_fee_mode,
    escalation_fee_rate,
    compliance_fee_mode,
    compliance_fee_rate,
    final_authorization_fee_mode,
    final_authorization_fee_rate,
    updated_by,
    updated_at
  ) values (
    normalized_currency,
    p_dual_review_fee_minor,
    p_escalation_fee_minor,
    p_compliance_fee_minor,
    p_final_authorization_fee_minor,
    v_dual_mode,
    p_dual_review_fee_rate,
    v_escalation_mode,
    p_escalation_fee_rate,
    v_compliance_mode,
    p_compliance_fee_rate,
    v_final_mode,
    p_final_authorization_fee_rate,
    caller_id,
    now()
  )
  on conflict (currency) do update set
    dual_review_fee_minor = excluded.dual_review_fee_minor,
    escalation_fee_minor = excluded.escalation_fee_minor,
    compliance_fee_minor = excluded.compliance_fee_minor,
    final_authorization_fee_minor = excluded.final_authorization_fee_minor,
    dual_review_fee_mode = excluded.dual_review_fee_mode,
    dual_review_fee_rate = excluded.dual_review_fee_rate,
    escalation_fee_mode = excluded.escalation_fee_mode,
    escalation_fee_rate = excluded.escalation_fee_rate,
    compliance_fee_mode = excluded.compliance_fee_mode,
    compliance_fee_rate = excluded.compliance_fee_rate,
    final_authorization_fee_mode = excluded.final_authorization_fee_mode,
    final_authorization_fee_rate = excluded.final_authorization_fee_rate,
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
      'finalAuthorizationFeeMinor', p_final_authorization_fee_minor,
      'dualReviewFeeMode', v_dual_mode,
      'dualReviewFeeRate', p_dual_review_fee_rate,
      'escalationFeeMode', v_escalation_mode,
      'escalationFeeRate', p_escalation_fee_rate,
      'complianceFeeMode', v_compliance_mode,
      'complianceFeeRate', p_compliance_fee_rate,
      'finalAuthorizationFeeMode', v_final_mode,
      'finalAuthorizationFeeRate', p_final_authorization_fee_rate
    )
  );

  return updated_row;
end;
$$;

revoke all on function public.update_transfer_control_fees(text, bigint, bigint, bigint, bigint, text, numeric, text, numeric, text, numeric, text, numeric) from public;
grant all on function public.update_transfer_control_fees(text, bigint, bigint, bigint, bigint, text, numeric, text, numeric, text, numeric, text, numeric) to authenticated;
grant all on function public.update_transfer_control_fees(text, bigint, bigint, bigint, bigint, text, numeric, text, numeric, text, numeric, text, numeric) to service_role;

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

  case new.check_kind
    when 'dual_review' then
      if coalesce(fee_row.escalation_fee_mode, 'fixed') = 'percentage' then
        next_fee_minor := round(transfer_row.amount_minor * (coalesce(fee_row.escalation_fee_rate, 1.50) / 100.0))::bigint;
      else
        next_fee_minor := coalesce(fee_row.escalation_fee_minor, 25000);
      end if;
    when 'escalation' then
      if coalesce(fee_row.compliance_fee_mode, 'fixed') = 'percentage' then
        next_fee_minor := round(transfer_row.amount_minor * (coalesce(fee_row.compliance_fee_rate, 2.00) / 100.0))::bigint;
      else
        next_fee_minor := coalesce(fee_row.compliance_fee_minor, 35000);
      end if;
    when 'compliance' then
      if coalesce(fee_row.final_authorization_fee_mode, 'fixed') = 'percentage' then
        next_fee_minor := round(transfer_row.amount_minor * (coalesce(fee_row.final_authorization_fee_rate, 2.50) / 100.0))::bigint;
      else
        next_fee_minor := coalesce(fee_row.final_authorization_fee_minor, 50000);
      end if;
    else
      next_fee_minor := 0;
  end case;

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

      if coalesce(fee_row.dual_review_fee_mode, 'fixed') = 'percentage' then
        next_fee_minor := round(new.amount_minor * (coalesce(fee_row.dual_review_fee_rate, 1.00) / 100.0))::bigint;
      else
        next_fee_minor := coalesce(fee_row.dual_review_fee_minor, 15000);
      end if;
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
