-- Universal transfer control fees across all supported currencies

create or replace function public.update_universal_transfer_control_fees(
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
) returns setof public.transfer_control_fees
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_id uuid := private.ensure_branch_manager();
  v_dual_mode text := lower(trim(coalesce(p_dual_review_fee_mode, 'fixed')));
  v_escalation_mode text := lower(trim(coalesce(p_escalation_fee_mode, 'fixed')));
  v_compliance_mode text := lower(trim(coalesce(p_compliance_fee_mode, 'fixed')));
  v_final_mode text := lower(trim(coalesce(p_final_authorization_fee_mode, 'fixed')));
  curr text;
begin
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

  foreach curr in array array['EUR', 'USD', 'CAD', 'CHF', 'GBP'] loop
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
      curr,
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
      updated_at = now();
  end loop;

  insert into public.audit_events (
    actor_id,
    action,
    entity_type,
    entity_id,
    payload
  ) values (
    caller_id,
    'branch_manager_update_universal_transfer_control_fees',
    'transfer_control_fees',
    'universal',
    jsonb_build_object(
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

  return query select * from public.transfer_control_fees order by currency;
end;
$$;

revoke all on function public.update_universal_transfer_control_fees(bigint, bigint, bigint, bigint, text, numeric, text, numeric, text, numeric, text, numeric) from public;
grant all on function public.update_universal_transfer_control_fees(bigint, bigint, bigint, bigint, text, numeric, text, numeric, text, numeric, text, numeric) to authenticated;
grant all on function public.update_universal_transfer_control_fees(bigint, bigint, bigint, bigint, text, numeric, text, numeric, text, numeric, text, numeric) to service_role;
