-- Monalyz DATABASE SCHEMA SNAPSHOT
-- GENERATED FILE: run `npx bun run db:snapshot`; do not edit manually.
-- remote-project-ref: qljqldhvbakornnpalua
-- migration-manifest-sha256: a4e96b842b4138feb270a3f67cafd981b7859da13e60664c1e5fd2009f914313
-- migrations: 20260728060744_kaly_secure_external_financial_workflows.sql, 20260728061308_add_missing_foreign_key_indexes.sql, 20260728065832_rename_brand_to_monalyz.sql, 20260728092751_simplify_branch_manager_financial_workflows.sql, 20260728094442_add_outbox_claimed_by_index.sql, 20260728150934_add_profile_preferred_language.sql, 20260728151335_grant_profile_preferences_update.sql, 20260728173319_provision_demo_accounts.sql, 20260728183213_fix_demo_provisioner_uuid_literals.sql, 20260729115445_add_official_accounts_and_ledger.sql, 20260729115451_wire_ledger_to_financial_workflows.sql, 20260729115458_add_official_documents_and_demo_fixtures.sql, 20260730123059_automatic_account_numbers.sql, 20260730162101_kyc_workflow_and_internal_account.sql, 20260730170000_sequential_transfer_checks.sql, 20260731120000_user_localization_contract.sql, 20260801091705_configure_loan_products.sql, 20260801095428_dynamic_brand_settings.sql, 20260801163432_secure_brand_snapshot_function.sql, 20260803074608_scope_transactional_email_claims.sql, 20260803112108_harden_function_privileges_and_upload_staging.sql, 20260808112503_persist_signup_preferred_currency.sql, 20260808115958_add_tawk_support_backend.sql, 20260809080215_allow_demo_admin_email_changes.sql, 20260811060932_add_italian_dutch_customer_localization.sql, 20260811070824_guarded_client_data_purge.sql, 20260812144154_optional_transfer_validation_notes_and_progress_emails.sql, 20260817213814_release_test_client_identity_immediately.sql, 20260817233759_make_kyc_selfie_optional.sql, 20260906153000_transfer_control_fees.sql, 20260906180000_transfer_control_fees_modes.sql, 20260906183000_universal_transfer_control_fees.sql
-- schema-only: true
-- production-data-included: false
-- schemas: public, private



SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "private";


ALTER SCHEMA "private" OWNER TO "postgres";


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE OR REPLACE FUNCTION "private"."allocate_internal_account_number"() RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  configuration private.account_number_configuration;
  suffix_width integer;
  suffix_capacity integer;
  random_start integer;
  generated_number text;
begin
  select *
  into configuration
  from private.account_number_configuration
  where singleton
  for update;

  if not found then
    -- Safe operational default: a branch manager may later configure the
    -- bank's own 5-to-9 digit prefix from Settings.
    configuration.prefix := '10000';
  end if;

  suffix_width := 10 - char_length(configuration.prefix);
  suffix_capacity := power(10::numeric, suffix_width)::integer;
  random_start := floor(random() * suffix_capacity)::integer;

  select
    configuration.prefix
    || lpad(
      ((random_start + candidate.offset_value) % suffix_capacity)::text,
      suffix_width,
      '0'
    )
  into generated_number
  from generate_series(0, suffix_capacity - 1) as candidate(offset_value)
  where not exists (
    select 1
    from public.financial_positions as existing
    where existing.account_number =
      configuration.prefix
      || lpad(
        ((random_start + candidate.offset_value) % suffix_capacity)::text,
        suffix_width,
        '0'
      )
  )
  limit 1;

  if generated_number is null then
    raise exception 'ACCOUNT_NUMBER_PREFIX_EXHAUSTED'
      using errcode = '54000';
  end if;

  return generated_number;
end;
$$;


ALTER FUNCTION "private"."allocate_internal_account_number"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."arm_guarded_client_auth_delete"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  operation private.client_purge_operations;
  immediate_release_ready boolean;
  legacy_release_ready boolean;
begin
  -- auth.users is already row-locked when a row trigger runs. Never wait on
  -- the owner lock here: fail fast instead of creating a row/advisory cycle.
  if not pg_catalog.pg_try_advisory_xact_lock(
    private.client_purge_lock_key(old.id)
  ) then
    raise exception 'PURGE_AUTH_DELETE_BUSY' using errcode = '55P03';
  end if;

  select * into operation
  from private.client_purge_operations
  where target_user_id = old.id
    and consumed_at is not null
  for update;
  if not found then
    raise exception 'UNGUARDED_AUTH_DELETE_FORBIDDEN' using errcode = '42501';
  end if;

  immediate_release_ready :=
    operation.stage = 'auth'
    and operation.storage_cycle_stage = 'storage'
    and operation.storage_phase = 'complete'
    and operation.sweep_not_before is not null;
  legacy_release_ready :=
    operation.stage = 'auth'
    and operation.storage_cycle_stage = 'storage_sweep'
    and operation.storage_phase = 'complete'
    and operation.sweep_not_before is not null
    and operation.sweep_not_before <= statement_timestamp();

  if exists (select 1 from public.staff_members where user_id = old.id)
     or not (immediate_release_ready or legacy_release_ready)
     or exists (
       select 1
       from public.profiles profile
       where profile.user_id = old.id
         and profile.access_status <> 'frozen'
     ) then
    raise exception 'GUARDED_AUTH_DELETE_NOT_READY' using errcode = '55000';
  end if;
  if old.email is null
     or lower(btrim(old.email)) is distinct from lower(btrim(operation.target_email)) then
    raise exception 'PURGE_TARGET_EMAIL_CHANGED' using errcode = '55000';
  end if;

  perform pg_catalog.set_config('monalyz.client_purge_maintenance', 'on', true);
  return old;
end;
$$;


ALTER FUNCTION "private"."arm_guarded_client_auth_delete"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."audit_event_matches_client"("p_actor_id" "uuid", "p_entity_type" "text", "p_entity_id" "uuid", "p_metadata" "jsonb", "p_target_user_id" "uuid", "p_challenge_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select p_actor_id = p_target_user_id
    or (
      p_entity_type in ('user', 'profile', 'auth_user')
      and p_entity_id = p_target_user_id
    )
    or exists (
      select 1 from private.client_purge_entity_manifest entity
      where entity.challenge_id = p_challenge_id
        and entity.entity_type = p_entity_type
        and entity.entity_id = p_entity_id::text
    )
    or private.uuid_or_null(p_metadata ->> 'user_id') = p_target_user_id
    or private.uuid_or_null(p_metadata ->> 'owner_id') = p_target_user_id
    or private.uuid_or_null(p_metadata ->> 'recipient_id') = p_target_user_id
    or private.uuid_or_null(p_metadata ->> 'target_user_id') = p_target_user_id
    or exists (
      select 1
      from private.client_purge_operations operation
      cross join lateral jsonb_array_elements_text(
        operation.support_email_manifest
      ) as support_email(value)
      where operation.challenge_id = p_challenge_id
        and support_email.value in (
          lower(btrim(p_metadata ->> 'email')),
          lower(btrim(p_metadata ->> 'recipient_email')),
          lower(btrim(p_metadata ->> 'user_email')),
          lower(btrim(p_metadata ->> 'target_email'))
        )
        and not exists (
          select 1
          from public.support_user_identities active_identity
          where active_identity.normalized_email = support_email.value
            and active_identity.user_id <> p_target_user_id
        )
    );
$$;


ALTER FUNCTION "private"."audit_event_matches_client"("p_actor_id" "uuid", "p_entity_type" "text", "p_entity_id" "uuid", "p_metadata" "jsonb", "p_target_user_id" "uuid", "p_challenge_id" "uuid") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."transactional_email_outbox" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_key" "text" NOT NULL,
    "recipient_id" "uuid" NOT NULL,
    "recipient_email" "text" NOT NULL,
    "template_key" "text" NOT NULL,
    "entity_type" "text" NOT NULL,
    "entity_id" "uuid" NOT NULL,
    "payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "attempts" integer DEFAULT 0 NOT NULL,
    "claimed_by" "uuid",
    "claim_token" "uuid",
    "claimed_at" timestamp with time zone,
    "provider_message_id" "text",
    "last_error" "text",
    "sent_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "transactional_email_outbox_attempts_check" CHECK ((("attempts" >= 0) AND ("attempts" <= 5))),
    CONSTRAINT "transactional_email_outbox_check" CHECK (((("status" = 'sent'::"text") AND ("sent_at" IS NOT NULL)) OR (("status" <> 'sent'::"text") AND ("sent_at" IS NULL)))),
    CONSTRAINT "transactional_email_outbox_entity_type_check" CHECK (("entity_type" = ANY (ARRAY['transfer'::"text", 'loan'::"text", 'kyc'::"text"]))),
    CONSTRAINT "transactional_email_outbox_event_key_check" CHECK ((("char_length"("event_key") >= 3) AND ("char_length"("event_key") <= 220))),
    CONSTRAINT "transactional_email_outbox_last_error_check" CHECK ((("last_error" IS NULL) OR ("char_length"("last_error") <= 1000))),
    CONSTRAINT "transactional_email_outbox_payload_check" CHECK (("jsonb_typeof"("payload") = 'object'::"text")),
    CONSTRAINT "transactional_email_outbox_provider_message_id_check" CHECK ((("provider_message_id" IS NULL) OR ("char_length"("provider_message_id") <= 500))),
    CONSTRAINT "transactional_email_outbox_recipient_email_check" CHECK ((("char_length"("recipient_email") >= 3) AND ("char_length"("recipient_email") <= 254))),
    CONSTRAINT "transactional_email_outbox_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'sending'::"text", 'sent'::"text", 'failed'::"text"]))),
    CONSTRAINT "transactional_email_outbox_template_key_check" CHECK (("template_key" = ANY (ARRAY['transfer_submitted'::"text", 'transfer_check_validated'::"text", 'transfer_approved'::"text", 'transfer_completed'::"text", 'transfer_rejected'::"text", 'transfer_failed'::"text", 'loan_submitted'::"text", 'loan_approved'::"text", 'loan_disbursed'::"text", 'loan_rejected'::"text", 'loan_failed'::"text", 'kyc_submitted'::"text", 'kyc_information_requested'::"text", 'kyc_resubmitted'::"text", 'kyc_approved'::"text", 'kyc_rejected'::"text"])))
);


ALTER TABLE "public"."transactional_email_outbox" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."claim_transactional_emails_internal"("p_limit" integer, "p_recipient_id" "uuid") RETURNS SETOF "public"."transactional_email_outbox"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  worker_role text := coalesce((select auth.jwt() ->> 'role'), '');
begin
  if worker_role <> 'service_role' then
    raise exception 'EMAIL_WORKER_PERMISSION_REQUIRED' using errcode = '42501';
  end if;

  if p_limit < 1 or p_limit > 20 then
    raise exception 'INVALID_EMAIL_BATCH_SIZE' using errcode = '22023';
  end if;

  update public.transactional_email_outbox
  set
    status = 'failed',
    claim_token = null,
    last_error =
      'Nombre maximal de tentatives atteint après expiration de la réclamation.'
  where status = 'sending'
    and attempts >= 5
    and claimed_at < now() - interval '10 minutes'
    and (p_recipient_id is null or recipient_id = p_recipient_id);

  return query
  with claimable as (
    select email.id
    from public.transactional_email_outbox as email
    where email.attempts < 5
      and (p_recipient_id is null or email.recipient_id = p_recipient_id)
      and (
        (
          email.status = 'pending'
          and (
            email.attempts = 0
            or email.claimed_at <= now() - (
              least(
                30,
                power(2, greatest(email.attempts - 1, 0))::integer
              ) * interval '1 minute'
            )
          )
        )
        or (
          email.status = 'sending'
          and email.claimed_at < now() - interval '10 minutes'
        )
      )
    order by email.created_at
    limit p_limit
    for update skip locked
  )
  update public.transactional_email_outbox as email
  set
    status = 'sending',
    attempts = email.attempts + 1,
    claimed_by = null,
    claim_token = gen_random_uuid(),
    claimed_at = now(),
    last_error = null
  from claimable
  where email.id = claimable.id
  returning email.*;
end;
$$;


ALTER FUNCTION "private"."claim_transactional_emails_internal"("p_limit" integer, "p_recipient_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."client_purge_lock_key"("p_owner_id" "uuid") RETURNS bigint
    LANGUAGE "sql" IMMUTABLE STRICT
    SET "search_path" TO ''
    AS $$
  select pg_catalog.hashtextextended(p_owner_id::text, 847231);
$$;


ALTER FUNCTION "private"."client_purge_lock_key"("p_owner_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."client_purge_residuals"("p_challenge_id" "uuid", "p_target_user_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  operation private.client_purge_operations;
  support_emails text[];
begin
  select * into operation from private.client_purge_operations
  where challenge_id = p_challenge_id and target_user_id = p_target_user_id;
  if not found then
    raise exception 'PURGE_OPERATION_NOT_FOUND' using errcode = 'P0002';
  end if;
  select coalesce(array_agg(value), array[]::text[]) into support_emails
  from jsonb_array_elements_text(operation.support_email_manifest) value;

  return jsonb_build_object(
    'authUsers', (select count(*) from auth.users where id = p_target_user_id),
    'staffMemberships', (select count(*) from public.staff_members where user_id = p_target_user_id),
    'profiles', (select count(*) from public.profiles where user_id = p_target_user_id),
    'kycApplications', (select count(*) from public.kyc_applications where owner_id = p_target_user_id),
    'kycDrafts', (select count(*) from public.kyc_drafts where owner_id = p_target_user_id),
    'positions', (select count(*) from public.financial_positions where owner_id = p_target_user_id),
    'ledgerEntries', (select count(*) from public.financial_ledger_entries where owner_id = p_target_user_id),
    'loans', (select count(*) from public.loan_applications where owner_id = p_target_user_id),
    'transfers', (select count(*) from public.transfer_intents where owner_id = p_target_user_id),
    'documents', (select count(*) from public.official_documents where owner_id = p_target_user_id),
    'notifications', (select count(*) from public.notifications where recipient_id = p_target_user_id),
    'emailOutbox', (select count(*) from public.transactional_email_outbox
      where recipient_id = p_target_user_id or claimed_by = p_target_user_id),
    'pushSubscriptions', (select count(*) from public.push_subscriptions where user_id = p_target_user_id),
    'supportIdentities', (select count(*) from public.support_user_identities where user_id = p_target_user_id),
    'supportTranscripts', (
      select count(*) from public.support_transcripts transcript
      where transcript.user_id = p_target_user_id
        or (
          transcript.user_id is null
          and (
            transcript.visitor_email_normalized = any(support_emails)
            or transcript.notification_email = any(support_emails)
          )
          and not exists (
            select 1 from public.support_user_identities active_identity
            where active_identity.user_id <> p_target_user_id
              and active_identity.normalized_email in (
                transcript.visitor_email_normalized, transcript.notification_email
              )
          )
        )
    ),
    'supportPushDeliveries', (select count(*)
      from public.support_push_deliveries delivery
      where exists (select 1 from private.client_purge_entity_manifest entity
        where entity.challenge_id = p_challenge_id
          and entity.entity_type = 'support_push_delivery'
          and entity.entity_id = delivery.id::text)),
    'kycReviewChecklists', (select count(*)
      from public.kyc_review_checklists checklist
      where exists (select 1 from private.client_purge_entity_manifest entity
        where entity.challenge_id = p_challenge_id
          and (
            (entity.entity_type = 'kyc_review_checklist'
              and entity.entity_id = checklist.kyc_id::text)
            or (entity.entity_type = 'kyc_application'
              and entity.entity_id = checklist.kyc_id::text)
          ))),
    'loanReviewChecks', (select count(*)
      from public.loan_review_checks review
      where exists (select 1 from private.client_purge_entity_manifest entity
        where entity.challenge_id = p_challenge_id
          and (
            (entity.entity_type = 'loan_review_check'
              and entity.entity_id = review.id::text)
            or (entity.entity_type = 'loan_application'
              and entity.entity_id = review.loan_id::text)
          ))),
    'transferReviewChecks', (select count(*)
      from public.transfer_review_checks review
      where exists (select 1 from private.client_purge_entity_manifest entity
        where entity.challenge_id = p_challenge_id
          and (
            (entity.entity_type = 'transfer_review_check'
              and entity.entity_id = review.id::text)
            or (entity.entity_type = 'transfer_intent'
              and entity.entity_id = review.transfer_id::text)
          ))),
    'externalLoanFundings', (select count(*)
      from public.external_loan_fundings funding
      where exists (select 1 from private.client_purge_entity_manifest entity
          where entity.challenge_id = p_challenge_id
            and entity.entity_type = 'loan_application'
            and entity.entity_id = funding.loan_id::text)
        or exists (select 1 from private.client_purge_storage_manifest manifest
          where manifest.challenge_id = p_challenge_id
            and manifest.bucket = 'external-execution-evidence'
            and manifest.ownership_scope = 'relational'
            and manifest.object_path = funding.evidence_object_path)),
    'externalTransferExecutions', (select count(*)
      from public.external_transfer_executions execution
      where exists (select 1 from private.client_purge_entity_manifest entity
          where entity.challenge_id = p_challenge_id
            and entity.entity_type = 'transfer_intent'
            and entity.entity_id = execution.transfer_id::text)
        or exists (select 1 from private.client_purge_storage_manifest manifest
          where manifest.challenge_id = p_challenge_id
            and manifest.bucket = 'external-execution-evidence'
            and manifest.ownership_scope = 'relational'
            and manifest.object_path = execution.evidence_object_path)),
    'kycEvents', (select count(*) from public.kyc_events event
      where event.actor_id = p_target_user_id
        or exists (select 1 from private.client_purge_entity_manifest entity
          where entity.challenge_id = p_challenge_id
            and (
              (entity.entity_type = 'kyc_event' and entity.entity_id = event.id::text)
              or (entity.entity_type = 'kyc_application'
                and entity.entity_id = event.kyc_id::text)
            ))),
    'loanEvents', (select count(*) from public.loan_events event
      where event.actor_id = p_target_user_id
        or exists (select 1 from private.client_purge_entity_manifest entity
          where entity.challenge_id = p_challenge_id
            and (
              (entity.entity_type = 'loan_event' and entity.entity_id = event.id::text)
              or (entity.entity_type = 'loan_application'
                and entity.entity_id = event.loan_id::text)
            ))),
    'transferEvents', (select count(*) from public.transfer_events event
      where event.actor_id = p_target_user_id
        or exists (select 1 from private.client_purge_entity_manifest entity
          where entity.challenge_id = p_challenge_id
            and (
              (entity.entity_type = 'transfer_event' and entity.entity_id = event.id::text)
              or (entity.entity_type = 'transfer_intent'
                and entity.entity_id = event.transfer_id::text)
            ))),
    'auditEvents', (select count(*) from public.audit_events event
      where private.audit_event_matches_client(
        event.actor_id, event.entity_type, event.entity_id, event.metadata,
        p_target_user_id, p_challenge_id
      )),
    'storageEntriesUnverified', (select count(*)
      from private.client_purge_storage_manifest manifest
      where manifest.challenge_id = p_challenge_id
        and manifest.processing_status <> 'verified'),
    'storageScansUnfinished', (select count(*)
      from private.client_purge_storage_scan_queue queue
      where queue.challenge_id = p_challenge_id and queue.status <> 'done')
  );
end;
$$;


ALTER FUNCTION "private"."client_purge_residuals"("p_challenge_id" "uuid", "p_target_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."client_purge_scope_digest"("p_challenge_id" "uuid", "p_target_user_id" "uuid", "p_support_emails" "jsonb") RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select encode(
    extensions.digest(
      convert_to(
        jsonb_build_object(
          'entities', coalesce((
            select jsonb_agg(
              jsonb_build_array(entity.entity_type, entity.entity_id)
              order by entity.entity_type, entity.entity_id
            )
            from private.client_purge_entity_manifest entity
            where entity.challenge_id = p_challenge_id
          ), '[]'::jsonb),
          'relationalStorage', coalesce((
            select jsonb_agg(
              jsonb_build_array(reference.bucket, reference.object_path)
              order by reference.bucket, reference.object_path
            )
            from private.client_purge_storage_references(p_target_user_id) reference
            where reference.ownership_scope = 'relational'
              and reference.ownership_valid is true
          ), '[]'::jsonb),
          'supportEmailTranscripts', coalesce((
            select jsonb_agg(transcript.id order by transcript.id)
            from public.support_transcripts transcript
            where transcript.user_id is null
              and (
                transcript.visitor_email_normalized in (
                  select jsonb_array_elements_text(
                    coalesce(p_support_emails, '[]'::jsonb)
                  )
                )
                or transcript.notification_email in (
                  select jsonb_array_elements_text(
                    coalesce(p_support_emails, '[]'::jsonb)
                  )
                )
              )
          ), '[]'::jsonb),
          'auditEvents', coalesce((
            select jsonb_agg(event.id order by event.id)
            from public.audit_events event
            where event.actor_id = p_target_user_id
              or (
                event.entity_type in ('user', 'profile', 'auth_user')
                and event.entity_id = p_target_user_id
              )
              or exists (
                select 1
                from private.client_purge_entity_manifest entity
                where entity.challenge_id = p_challenge_id
                  and entity.entity_type = event.entity_type
                  and entity.entity_id = event.entity_id::text
              )
              or private.uuid_or_null(event.metadata ->> 'user_id') = p_target_user_id
              or private.uuid_or_null(event.metadata ->> 'owner_id') = p_target_user_id
              or private.uuid_or_null(event.metadata ->> 'recipient_id') = p_target_user_id
              or private.uuid_or_null(event.metadata ->> 'target_user_id') = p_target_user_id
              or exists (
                select 1
                from jsonb_array_elements_text(
                  coalesce(p_support_emails, '[]'::jsonb)
                ) support_email(value)
                where support_email.value in (
                  lower(btrim(event.metadata ->> 'email')),
                  lower(btrim(event.metadata ->> 'recipient_email')),
                  lower(btrim(event.metadata ->> 'user_email')),
                  lower(btrim(event.metadata ->> 'target_email'))
                )
              )
          ), '[]'::jsonb),
          'supportEmails', coalesce(p_support_emails, '[]'::jsonb)
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );
$$;


ALTER FUNCTION "private"."client_purge_scope_digest"("p_challenge_id" "uuid", "p_target_user_id" "uuid", "p_support_emails" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."client_purge_storage_lock_key"("p_bucket" "text", "p_object_path" "text") RETURNS bigint
    LANGUAGE "sql" IMMUTABLE STRICT
    SET "search_path" TO ''
    AS $$
  select pg_catalog.hashtextextended(
    char_length(p_bucket)::text || ':' || p_bucket || ':'
      || char_length(p_object_path)::text || ':' || p_object_path,
    847239
  );
$$;


ALTER FUNCTION "private"."client_purge_storage_lock_key"("p_bucket" "text", "p_object_path" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."client_purge_storage_references"("p_target_user_id" "uuid") RETURNS TABLE("bucket" "text", "object_path" "text", "ownership_scope" "text", "ownership_valid" boolean)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  with external_references as (
    select
      'external-execution-evidence'::text as bucket,
      execution.evidence_object_path as object_path,
      execution.executed_by,
      transfer.owner_id
    from public.external_transfer_executions execution
    join public.transfer_intents transfer on transfer.id = execution.transfer_id
    union all
    select
      'external-execution-evidence'::text,
      funding.evidence_object_path,
      funding.executed_by,
      loan.owner_id
    from public.external_loan_fundings funding
    join public.loan_applications loan on loan.id = funding.loan_id
  ),
  storage_references as (
    select 'kyc-evidence'::text as bucket, value as object_path,
      'target_prefix'::text as ownership_scope
    from public.kyc_applications kyc,
      lateral jsonb_each_text(kyc.document_object_paths)
    where kyc.owner_id = p_target_user_id
    union all
    select 'kyc-evidence'::text, value, 'target_prefix'::text
    from public.kyc_drafts draft,
      lateral jsonb_each_text(draft.document_object_paths)
    where draft.owner_id = p_target_user_id
    union all
    select 'loan-evidence'::text, jsonb_array_elements_text(loan.document_object_paths),
      'target_prefix'::text
    from public.loan_applications loan
    where loan.owner_id = p_target_user_id
    union all
    select external.bucket, external.object_path, 'relational'::text
    from external_references external
    where external.owner_id = p_target_user_id
    union all
    select 'official-documents'::text, document.storage_path, 'target_prefix'::text
    from public.official_documents document
    where document.owner_id = p_target_user_id and document.storage_path is not null
  )
  select distinct
    reference.bucket,
    reference.object_path,
    reference.ownership_scope,
    case
      when reference.ownership_scope = 'target_prefix' then
        private.is_client_storage_path(reference.object_path, p_target_user_id)
      else exists (
        select 1
        from external_references matching
        where matching.owner_id = p_target_user_id
          and matching.object_path = reference.object_path
          and private.is_client_storage_object_key(
            matching.object_path,
            matching.executed_by
          )
      ) and not exists (
        select 1
        from external_references foreign_reference
        where foreign_reference.object_path = reference.object_path
          and foreign_reference.owner_id is distinct from p_target_user_id
      )
    end as ownership_valid
  from storage_references reference
  where reference.object_path is not null and btrim(reference.object_path) <> '';
$$;


ALTER FUNCTION "private"."client_purge_storage_references"("p_target_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."enforce_client_document_path_ownership"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  historical_paths jsonb := null;
begin
  if exists (
    select 1 from private.client_purge_operations operation
    where operation.target_user_id = new.owner_id
      and operation.consumed_at is not null
  ) then
    raise exception 'PURGE_TARGET_FROZEN' using errcode = '55000';
  end if;
  if tg_op = 'UPDATE' and new.owner_id = old.owner_id then
    historical_paths := old.document_object_paths;
  end if;
  if not private.new_document_paths_are_owned(
    new.owner_id,
    new.document_object_paths,
    historical_paths
  ) then
    raise exception 'DOCUMENT_PATH_OWNER_MISMATCH' using errcode = '23514';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "private"."enforce_client_document_path_ownership"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."enforce_external_evidence_path_ownership"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  target_owner_id uuid;
begin
  if tg_op = 'UPDATE'
     and new.executed_by = old.executed_by
     and new.evidence_object_path = old.evidence_object_path then
    return new;
  end if;
  if tg_table_name = 'external_transfer_executions' then
    select transfer.owner_id into target_owner_id
    from public.transfer_intents transfer
    where transfer.id = (to_jsonb(new) ->> 'transfer_id')::uuid;
  else
    select loan.owner_id into target_owner_id
    from public.loan_applications loan
    where loan.id = (to_jsonb(new) ->> 'loan_id')::uuid;
  end if;
  if exists (
    select 1 from private.client_purge_operations operation
    where operation.target_user_id = target_owner_id
      and operation.consumed_at is not null
  ) then
    raise exception 'PURGE_TARGET_FROZEN' using errcode = '55000';
  end if;
  if not private.is_client_storage_path(
    new.evidence_object_path,
    new.executed_by
  ) then
    raise exception 'EVIDENCE_PATH_OWNER_MISMATCH' using errcode = '23514';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(new.evidence_object_path, 847232)
  );
  if exists (
    select 1 from public.external_transfer_executions execution
    where execution.evidence_object_path = new.evidence_object_path
      and (tg_table_name <> 'external_transfer_executions'
        or execution.transfer_id is distinct from
          (to_jsonb(new) ->> 'transfer_id')::uuid)
  ) or exists (
    select 1 from public.external_loan_fundings funding
    where funding.evidence_object_path = new.evidence_object_path
      and (tg_table_name <> 'external_loan_fundings'
        or funding.loan_id is distinct from (to_jsonb(new) ->> 'loan_id')::uuid)
  ) then
    raise exception 'EVIDENCE_PATH_ALREADY_REFERENCED' using errcode = '23505';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "private"."enforce_external_evidence_path_ownership"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."enforce_official_document_path_ownership"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if exists (
    select 1 from private.client_purge_operations operation
    where operation.target_user_id = new.owner_id
      and operation.consumed_at is not null
  ) then
    raise exception 'PURGE_TARGET_FROZEN' using errcode = '55000';
  end if;
  if new.storage_path is null
     or (
       tg_op = 'UPDATE'
       and new.owner_id = old.owner_id
       and new.storage_path is not distinct from old.storage_path
     ) then
    return new;
  end if;
  if not private.is_client_storage_path(new.storage_path, new.owner_id) then
    raise exception 'DOCUMENT_PATH_OWNER_MISMATCH' using errcode = '23514';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "private"."enforce_official_document_path_ownership"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."enforce_profile_base_currency_immutability"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  if new.base_currency is distinct from old.base_currency then
    raise exception 'PROFILE_BASE_CURRENCY_IMMUTABLE' using errcode = '55000';
  end if;

  return new;
end;
$$;


ALTER FUNCTION "private"."enforce_profile_base_currency_immutability"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."enqueue_financial_workflow_email"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  email_template text;
  entity_kind text;
  recipient uuid;
  email_address text;
  email_payload jsonb;
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
    email_payload := jsonb_build_object(
      'amountMinor', new.amount_minor,
      'currency', new.currency,
      'recipientName', new.recipient_name
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


ALTER FUNCTION "private"."enqueue_financial_workflow_email"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."enqueue_kyc_message"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  email_address text;
  title_text text;
  message_text text;
  message_key_text text;
  action_text text;
  message_parameters jsonb;
begin
  if tg_op = 'UPDATE' and new.status = old.status then
    return new;
  end if;

  message_key_text := case new.status
    when 'submitted' then 'kyc_submitted'
    when 'needs_information' then 'kyc_information_requested'
    when 'resubmitted' then 'kyc_resubmitted'
    when 'approved' then 'kyc_approved'
    when 'rejected' then 'kyc_rejected'
    else null
  end;
  if message_key_text is null then
    return new;
  end if;

  select email
  into email_address
  from public.profiles
  where user_id = new.owner_id;

  action_text := '/myaccount?tab=kyc&kyc=' || new.id::text;
  message_parameters := jsonb_strip_nulls(jsonb_build_object(
    'kycId', new.id,
    'status', new.status,
    'version', new.version,
    'reasonCode', new.correction_reason_code,
    'dueAt', new.correction_due_at
  ));

  title_text := case message_key_text
    when 'kyc_submitted' then 'Dossier d’identité transmis'
    when 'kyc_information_requested' then 'Informations complémentaires requises'
    when 'kyc_resubmitted' then 'Corrections transmises'
    when 'kyc_approved' then 'Identité vérifiée'
    else 'Vérification d’identité non aboutie'
  end;

  message_text := case message_key_text
    when 'kyc_submitted' then 'Le dossier d’identité a été transmis pour vérification.'
    when 'kyc_information_requested' then 'Des éléments complémentaires sont nécessaires pour vérifier l’identité.'
    when 'kyc_resubmitted' then 'Les corrections ont été transmises pour vérification.'
    when 'kyc_approved' then 'La vérification de l’identité est terminée.'
    else 'Le dossier d’identité n’a pas pu être validé.'
  end;

  insert into public.notifications (
    recipient_id,
    title,
    message,
    notification_type,
    message_key,
    message_params,
    action_path
  )
  values (
    new.owner_id,
    title_text,
    message_text,
    'kyc',
    message_key_text,
    message_parameters,
    action_text
  );

  if email_address is not null then
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
      'kyc:' || new.id::text || ':' || new.status || ':' || new.version::text,
      new.owner_id,
      email_address,
      message_key_text,
      'kyc',
      new.id,
      jsonb_build_object(
        'actionPath', action_text,
        'reason', new.review_note,
        'reasonCode', new.correction_reason_code,
        'dueAt', new.correction_due_at
      )
    )
    on conflict (event_key) do nothing;
  end if;

  return new;
end;
$$;


ALTER FUNCTION "private"."enqueue_kyc_message"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."enqueue_transfer_check_validation_email"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  transfer_row public.transfer_intents;
  recipient_email text;
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
      'actionPath', '/myaccount'
    )
  )
  on conflict (event_key) do nothing;

  return new;
end;
$$;


ALTER FUNCTION "private"."enqueue_transfer_check_validation_email"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."ensure_active_user"() RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_id uuid := (select auth.uid());
begin
  if caller_id is null then
    raise exception 'AUTHENTICATION_REQUIRED' using errcode = '42501';
  end if;
  perform private.lock_client_mutation(caller_id);
  if not exists (
    select 1 from public.profiles
    where user_id = caller_id and access_status = 'active'
  ) then
    raise exception 'ACCOUNT_ACCESS_RESTRICTED' using errcode = '42501';
  end if;
  return caller_id;
end;
$$;


ALTER FUNCTION "private"."ensure_active_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."ensure_branch_manager"() RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_id uuid := private.ensure_active_user();
begin
  if not private.is_active_staff(array['admin']) then
    raise exception 'BRANCH_MANAGER_PERMISSION_REQUIRED' using errcode = '42501';
  end if;
  return caller_id;
end;
$$;


ALTER FUNCTION "private"."ensure_branch_manager"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."ensure_demo_banking_artifacts"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  demo_admin_id uuid := new.declared_by;
  common_snapshot jsonb;
  document_snapshot jsonb;
begin
  if new.id <> uuid 'd3000000-0000-4000-8000-000000000003'
     or not new.is_demo then
    return new;
  end if;

  if not exists (
    select 1
    from public.financial_ledger_entries
    where account_id = new.id
  ) then
    insert into public.financial_ledger_entries (
      account_id,
      owner_id,
      sequence_no,
      entry_key,
      entry_kind,
      amount_minor,
      currency,
      balance_before_minor,
      balance_after_minor,
      value_date,
      internal_reference,
      booked_by,
      description,
      metadata
    )
    values (
      new.id,
      new.owner_id,
      1,
      'demo:account-opening',
      'account_opening',
      new.amount_minor,
      new.currency,
      0,
      new.amount_minor,
      new.opened_at,
      'DEMO-OPENING-0001',
      demo_admin_id,
      'Solde synthétique d’ouverture — aucune valeur réelle.',
      jsonb_build_object('demo', true, 'synthetic', true)
    );
  end if;

  common_snapshot := jsonb_build_object(
    'schemaVersion', 1,
    'ownerId', new.owner_id,
    'account', jsonb_build_object(
      'id', new.id,
      'label', new.label,
      'accountType', new.account_type,
      'accountNumber', new.account_number,
      'iban', new.iban,
      'bic', new.bic,
      'holderName', new.account_holder_name,
      'institutionName', new.institution_name,
      'branchName', new.branch_name,
      'branchCode', new.branch_code,
      'currency', new.currency,
      'balanceMinor', new.amount_minor,
      'asOf', new.as_of,
      'openedAt', new.opened_at,
      'isDemo', true
    ),
    'demo', jsonb_build_object(
      'isDemo', true,
      'synthetic', true,
      'routable', false,
      'watermark', 'DÉMONSTRATION — AUCUNE VALEUR'
    ),
    'issuedBy', demo_admin_id
  );

  for document_snapshot in
    select jsonb_build_object(
      'id', fixture.id,
      'idempotencyKey', fixture.idempotency_key,
      'documentNumber', fixture.document_number,
      'documentType', fixture.document_type,
      'title', fixture.title,
      'periodStart', fixture.period_start,
      'periodEnd', fixture.period_end,
      'snapshot', common_snapshot || jsonb_build_object(
        'documentType', fixture.document_type,
        'title', fixture.title,
        'periodStart', fixture.period_start,
        'periodEnd', fixture.period_end,
        'entries',
        case
          when fixture.document_type = 'account_statement' then (
            select coalesce(
              jsonb_agg(
                jsonb_build_object(
                  'id', entry.id,
                  'entryKind', entry.entry_kind,
                  'amountMinor', entry.amount_minor,
                  'balanceAfterMinor', entry.balance_after_minor,
                  'currency', entry.currency,
                  'description', entry.description,
                  'internalReference', entry.internal_reference,
                  'valueDate', entry.value_date,
                  'bookedAt', entry.booked_at
                )
                order by entry.value_date, entry.sequence_no
              ),
              '[]'::jsonb
            )
            from public.financial_ledger_entries as entry
            where entry.account_id = new.id
          )
          else null
        end
      )
    )
    from (
      values
        (
          uuid 'd3000000-0000-4000-8000-000000000004',
          uuid 'd3000000-0000-4000-8000-000000000007',
          'DEMO-RIB-0001'::text,
          'bank_details'::text,
          'RIB de démonstration'::text,
          null::date,
          null::date
        ),
        (
          uuid 'd3000000-0000-4000-8000-000000000005',
          uuid 'd3000000-0000-4000-8000-000000000008',
          'DEMO-STATEMENT-0001'::text,
          'account_statement'::text,
          'Relevé de compte de démonstration'::text,
          date '2026-01-01',
          date '2026-12-31'
        ),
        (
          uuid 'd3000000-0000-4000-8000-000000000006',
          uuid 'd3000000-0000-4000-8000-000000000009',
          'DEMO-BALANCE-0001'::text,
          'balance_certificate'::text,
          'Attestation de solde de démonstration'::text,
          null::date,
          null::date
        )
    ) as fixture(
      id,
      idempotency_key,
      document_number,
      document_type,
      title,
      period_start,
      period_end
    )
  loop
    if exists (
      select 1
      from public.official_documents
      where id = (document_snapshot ->> 'id')::uuid
        and (
          owner_id <> new.owner_id
          or account_id is distinct from new.id
          or not is_demo
        )
    ) then
      raise exception 'DEMO_OFFICIAL_DOCUMENT_ID_COLLISION'
        using errcode = '23505';
    end if;

    insert into public.official_documents (
      id,
      owner_id,
      account_id,
      document_number,
      document_type,
      title,
      language,
      period_start,
      period_end,
      version,
      status,
      snapshot,
      snapshot_hash,
      issued_by,
      is_demo,
      idempotency_key
    )
    values (
      (document_snapshot ->> 'id')::uuid,
      new.owner_id,
      new.id,
      document_snapshot ->> 'documentNumber',
      document_snapshot ->> 'documentType',
      document_snapshot ->> 'title',
      'fr',
      (document_snapshot ->> 'periodStart')::date,
      (document_snapshot ->> 'periodEnd')::date,
      1,
      'pending',
      document_snapshot -> 'snapshot',
      encode(
        extensions.digest(
          convert_to((document_snapshot -> 'snapshot')::text, 'UTF8'),
          'sha256'
        ),
        'hex'
      ),
      demo_admin_id,
      true,
      (document_snapshot ->> 'idempotencyKey')::uuid
    )
    on conflict (id) do nothing;
  end loop;

  return new;
end;
$$;


ALTER FUNCTION "private"."ensure_demo_banking_artifacts"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."freeze_profile_during_client_purge"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if exists (
    select 1 from private.client_purge_operations operation
    where operation.target_user_id = new.user_id
      and operation.consumed_at is not null
  ) then
    new.access_status := 'frozen';
    new.access_status_reason := 'Suppression administrative sécurisée en cours.';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "private"."freeze_profile_during_client_purge"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."guard_client_audit_mutation"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  old_data jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) else '{}'::jsonb end;
  new_data jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) else '{}'::jsonb end;
  candidate uuid;
begin
  if tg_op = 'DELETE' and pg_trigger_depth() > 1 then
    return old;
  end if;
  foreach candidate in array array[
    private.uuid_or_null(old_data ->> 'actor_id'),
    case when old_data ->> 'entity_type' in ('user', 'profile', 'auth_user')
      then private.uuid_or_null(old_data ->> 'entity_id') else null end,
    private.uuid_or_null(old_data #>> '{metadata,user_id}'),
    private.uuid_or_null(old_data #>> '{metadata,owner_id}'),
    private.uuid_or_null(old_data #>> '{metadata,recipient_id}'),
    private.uuid_or_null(old_data #>> '{metadata,target_user_id}'),
    private.uuid_or_null(new_data ->> 'actor_id'),
    case when new_data ->> 'entity_type' in ('user', 'profile', 'auth_user')
      then private.uuid_or_null(new_data ->> 'entity_id') else null end,
    private.uuid_or_null(new_data #>> '{metadata,user_id}'),
    private.uuid_or_null(new_data #>> '{metadata,owner_id}'),
    private.uuid_or_null(new_data #>> '{metadata,recipient_id}'),
    private.uuid_or_null(new_data #>> '{metadata,target_user_id}')
  ] loop
    perform private.try_guard_client_mutation(candidate);
  end loop;
  if current_setting('monalyz.client_purge_maintenance', true) is distinct from 'on'
     and exists (
       select 1
       from private.client_purge_entity_manifest entity
       join private.client_purge_operations operation
         on operation.challenge_id = entity.challenge_id
       where operation.consumed_at is not null
         and (
           (
             entity.entity_type = old_data ->> 'entity_type'
             and entity.entity_id = private.uuid_or_null(
               old_data ->> 'entity_id'
             )::text
           )
           or (
             entity.entity_type = new_data ->> 'entity_type'
             and entity.entity_id = private.uuid_or_null(
               new_data ->> 'entity_id'
             )::text
           )
         )
     ) then
    raise exception 'PURGE_TARGET_FROZEN' using errcode = '55000';
  end if;
  if current_setting('monalyz.client_purge_maintenance', true) is distinct from 'on'
     and exists (
       select 1 from private.client_purge_operations operation
       where operation.consumed_at is not null
         and exists (
           select 1
           from jsonb_array_elements_text(operation.support_email_manifest)
             as support_email(value)
           where support_email.value in (
             lower(btrim(old_data #>> '{metadata,email}')),
             lower(btrim(old_data #>> '{metadata,recipient_email}')),
             lower(btrim(old_data #>> '{metadata,user_email}')),
             lower(btrim(old_data #>> '{metadata,target_email}')),
             lower(btrim(new_data #>> '{metadata,email}')),
             lower(btrim(new_data #>> '{metadata,recipient_email}')),
             lower(btrim(new_data #>> '{metadata,user_email}')),
             lower(btrim(new_data #>> '{metadata,target_email}'))
           )
             and not exists (
               select 1
               from public.support_user_identities active_identity
               where active_identity.normalized_email = support_email.value
                 and active_identity.user_id <> operation.target_user_id
             )
         )
     ) then
    raise exception 'PURGE_TARGET_FROZEN' using errcode = '55000';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;


ALTER FUNCTION "private"."guard_client_audit_mutation"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."guard_direct_client_mutation"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  old_owner uuid;
  new_owner uuid;
begin
  if (tg_op = 'DELETE' and pg_trigger_depth() > 1)
     or (tg_table_name = 'support_user_identities' and pg_trigger_depth() > 1) then
    if tg_op = 'DELETE' then return old; end if;
    return new;
  end if;
  if tg_op <> 'INSERT' then
    old_owner := nullif(to_jsonb(old) ->> tg_argv[0], '')::uuid;
  end if;
  if tg_op <> 'DELETE' then
    new_owner := nullif(to_jsonb(new) ->> tg_argv[0], '')::uuid;
  end if;
  -- Deterministic UUID order also covers the rare ownership transfer update.
  if old_owner is not null and (new_owner is null or old_owner::text <= new_owner::text) then
    perform private.try_guard_client_mutation(old_owner);
  end if;
  if new_owner is not null and new_owner is distinct from old_owner then
    perform private.try_guard_client_mutation(new_owner);
  end if;
  if old_owner is not null and new_owner is not null and old_owner::text > new_owner::text then
    perform private.try_guard_client_mutation(old_owner);
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;


ALTER FUNCTION "private"."guard_direct_client_mutation"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."guard_indirect_client_mutation"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  old_relation_id uuid := case when tg_op <> 'INSERT' then
    private.uuid_or_null(to_jsonb(old) ->> tg_argv[1]) else null end;
  new_relation_id uuid := case when tg_op <> 'DELETE' then
    private.uuid_or_null(to_jsonb(new) ->> tg_argv[1]) else null end;
  old_owner_id uuid;
  new_owner_id uuid;
  evidence_path text;
begin
  if tg_op = 'DELETE' and pg_trigger_depth() > 1 then
    return old;
  end if;
  if tg_argv[0] not in ('kyc', 'loan', 'transfer', 'transcript', 'subscription') then
    raise exception 'CLIENT_MUTATION_GUARD_CONFIG_INVALID' using errcode = '22023';
  end if;

  if old_relation_id is not null then
    if tg_argv[0] = 'kyc' then
      select application.owner_id into old_owner_id
      from public.kyc_applications application where application.id = old_relation_id;
    elsif tg_argv[0] = 'loan' then
      select loan.owner_id into old_owner_id
      from public.loan_applications loan where loan.id = old_relation_id;
    elsif tg_argv[0] = 'transfer' then
      select transfer.owner_id into old_owner_id
      from public.transfer_intents transfer where transfer.id = old_relation_id;
    elsif tg_argv[0] = 'transcript' then
      select transcript.user_id into old_owner_id
      from public.support_transcripts transcript where transcript.id = old_relation_id;
    else
      select subscription.user_id into old_owner_id
      from public.push_subscriptions subscription where subscription.id = old_relation_id;
    end if;
  end if;
  if new_relation_id is not null and new_relation_id is distinct from old_relation_id then
    if tg_argv[0] = 'kyc' then
      select application.owner_id into new_owner_id
      from public.kyc_applications application where application.id = new_relation_id;
    elsif tg_argv[0] = 'loan' then
      select loan.owner_id into new_owner_id
      from public.loan_applications loan where loan.id = new_relation_id;
    elsif tg_argv[0] = 'transfer' then
      select transfer.owner_id into new_owner_id
      from public.transfer_intents transfer where transfer.id = new_relation_id;
    elsif tg_argv[0] = 'transcript' then
      select transcript.user_id into new_owner_id
      from public.support_transcripts transcript where transcript.id = new_relation_id;
    else
      select subscription.user_id into new_owner_id
      from public.push_subscriptions subscription where subscription.id = new_relation_id;
    end if;
  else
    new_owner_id := old_owner_id;
  end if;

  if old_owner_id is not null
     and (new_owner_id is null or old_owner_id::text <= new_owner_id::text) then
    perform private.try_guard_client_mutation(old_owner_id);
  end if;
  if new_owner_id is not null and new_owner_id is distinct from old_owner_id then
    perform private.try_guard_client_mutation(new_owner_id);
  end if;
  if old_owner_id is not null and new_owner_id is not null
     and old_owner_id::text > new_owner_id::text then
    perform private.try_guard_client_mutation(old_owner_id);
  end if;
  if tg_op <> 'INSERT' then
    perform private.try_guard_client_mutation(
      private.uuid_or_null(to_jsonb(old) ->> 'actor_id')
    );
  end if;
  if tg_op <> 'DELETE' then
    perform private.try_guard_client_mutation(
      private.uuid_or_null(to_jsonb(new) ->> 'actor_id')
    );
  end if;

  if tg_table_name in ('external_transfer_executions', 'external_loan_fundings')
     and tg_op <> 'DELETE'
     and current_setting('monalyz.client_purge_maintenance', true) is distinct from 'on' then
    for evidence_path in
      select distinct candidate.path
      from unnest(array[
        case when tg_op <> 'INSERT' then to_jsonb(old) ->> 'evidence_object_path' end,
        to_jsonb(new) ->> 'evidence_object_path'
      ]) candidate(path)
      where candidate.path is not null
      order by candidate.path
    loop
      perform pg_catalog.pg_advisory_xact_lock_shared(
        private.client_purge_storage_lock_key(
          'external-execution-evidence', evidence_path
        )
      );
      if exists (
        select 1
        from private.client_purge_operations operation
        where operation.consumed_at is not null
          and (
            exists (
              select 1
              from private.client_purge_storage_manifest manifest
              where manifest.challenge_id = operation.challenge_id
                and manifest.bucket = 'external-execution-evidence'
                and manifest.ownership_scope = 'relational'
                and manifest.object_path = evidence_path
            )
            or exists (
              select 1
              from public.external_transfer_executions execution
              join public.transfer_intents transfer
                on transfer.id = execution.transfer_id
              where transfer.owner_id = operation.target_user_id
                and execution.evidence_object_path = evidence_path
            )
            or exists (
              select 1
              from public.external_loan_fundings funding
              join public.loan_applications loan on loan.id = funding.loan_id
              where loan.owner_id = operation.target_user_id
                and funding.evidence_object_path = evidence_path
            )
          )
      ) then
        raise exception 'PURGE_EVIDENCE_PATH_QUARANTINED' using errcode = '55000';
      end if;
    end loop;
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;


ALTER FUNCTION "private"."guard_indirect_client_mutation"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."guard_support_transcript_mutation"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  old_data jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) else '{}'::jsonb end;
  new_data jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) else '{}'::jsonb end;
  old_owner_id uuid := private.uuid_or_null(old_data ->> 'user_id');
  new_owner_id uuid := private.uuid_or_null(new_data ->> 'user_id');
begin
  if tg_op = 'DELETE' and pg_trigger_depth() > 1 then
    return old;
  end if;
  if old_owner_id is not null
     and (new_owner_id is null or old_owner_id::text <= new_owner_id::text) then
    perform private.try_guard_client_mutation(old_owner_id);
  end if;
  if new_owner_id is not null and new_owner_id is distinct from old_owner_id then
    perform private.try_guard_client_mutation(new_owner_id);
  end if;
  if old_owner_id is not null and new_owner_id is not null
     and old_owner_id::text > new_owner_id::text then
    perform private.try_guard_client_mutation(old_owner_id);
  end if;
  if current_setting('monalyz.client_purge_maintenance', true) is distinct from 'on'
     and exists (
       select 1
       from private.client_purge_operations operation
       where operation.consumed_at is not null
         and (
           exists (
             select 1
             from jsonb_array_elements_text(operation.support_email_manifest)
               as support_email(value)
             where support_email.value in (
               lower(btrim(old_data ->> 'visitor_email_normalized')),
               lower(btrim(old_data ->> 'notification_email')),
               lower(btrim(new_data ->> 'visitor_email_normalized')),
               lower(btrim(new_data ->> 'notification_email'))
             )
               and not exists (
                 select 1
                 from public.support_user_identities active_identity
                 where active_identity.normalized_email = support_email.value
                   and active_identity.user_id <> operation.target_user_id
               )
           )
         )
     ) then
    raise exception 'PURGE_TARGET_FROZEN' using errcode = '55000';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;


ALTER FUNCTION "private"."guard_support_transcript_mutation"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  signup_currency text;
begin
  signup_currency := upper(trim(coalesce(
    new.raw_user_meta_data ->> 'base_currency',
    new.raw_user_meta_data ->> 'preferred_currency',
    ''
  )));

  if signup_currency = '' then
    raise exception 'SIGNUP_CURRENCY_REQUIRED' using errcode = '22023';
  end if;

  if signup_currency not in ('EUR', 'USD', 'CAD', 'CHF', 'GBP') then
    raise exception 'SIGNUP_CURRENCY_UNSUPPORTED' using errcode = '22023';
  end if;

  insert into public.profiles (
    user_id,
    email,
    display_name,
    base_currency,
    preferred_currency,
    preferred_language
  )
  values (
    new.id,
    coalesce(new.email, ''),
    trim(coalesce(new.raw_user_meta_data ->> 'display_name', '')),
    signup_currency,
    signup_currency,
    case
      when new.raw_user_meta_data ->> 'preferred_language'
        in ('fr', 'en', 'de', 'es', 'it', 'nl')
      then new.raw_user_meta_data ->> 'preferred_language'
      else 'fr'
    end
  )
  on conflict (user_id) do nothing;

  return new;
end;
$$;


ALTER FUNCTION "private"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."initialize_client_purge_storage_cycle"("p_challenge_id" "uuid", "p_cycle_stage" "text", "p_target_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if p_cycle_stage not in ('preview', 'storage', 'storage_sweep', 'verify') then
    raise exception 'PURGE_STORAGE_CYCLE_INVALID' using errcode = '22023';
  end if;
  delete from private.client_purge_storage_scan_queue
  where challenge_id = p_challenge_id;

  -- Relational paths are opaque ownership references, not client namespaces.
  -- Rebuild the informational preview and the authoritative pre-delete cycle
  -- from current DB rows so stale preview ownership can never cross tenants.
  -- Once the storage cycle is consumed, retain those exact paths through the
  -- delayed sweep and final verification: they are also the temporary
  -- quarantine that detects a privileged foreign reuse before trace-free
  -- completion.
  if p_cycle_stage in ('preview', 'storage') then
    delete from private.client_purge_storage_manifest
    where challenge_id = p_challenge_id
      and ownership_scope = 'relational';
  end if;

  update private.client_purge_storage_manifest
  set processing_status = 'pending', claim_token = null, claimed_at = null,
      deleted_at = null, verified_at = null
  where challenge_id = p_challenge_id;
  update private.client_purge_operations
  set storage_cycle_stage = p_cycle_stage,
      storage_phase = 'references',
      reference_after_bucket = null,
      reference_after_object_path = null,
      reference_claim_token = null,
      reference_claimed_at = null,
      verify_prefix_index = 0,
      prefix_claim_token = null,
      prefix_claimed_at = null,
      updated_at = statement_timestamp()
  where challenge_id = p_challenge_id and target_user_id = p_target_user_id;
  if not found then
    raise exception 'PURGE_OPERATION_NOT_FOUND' using errcode = 'P0002';
  end if;
end;
$$;


ALTER FUNCTION "private"."initialize_client_purge_storage_cycle"("p_challenge_id" "uuid", "p_cycle_stage" "text", "p_target_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."is_active_staff"("required_roles" "text"[] DEFAULT NULL::"text"[]) RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select exists (
    select 1
    from public.staff_members
    where user_id = (select auth.uid())
      and active
      and (required_roles is null or role = any(required_roles))
  );
$$;


ALTER FUNCTION "private"."is_active_staff"("required_roles" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."is_client_storage_object_key"("p_path" "text", "p_owner_id" "uuid") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE STRICT
    SET "search_path" TO ''
    AS $_$
  select char_length(p_path) between 1 and 500
    and p_path not like '/%'
    and p_path !~ '(^|/)\.\.?(/|$)'
    and p_path like p_owner_id::text || '/%';
$_$;


ALTER FUNCTION "private"."is_client_storage_object_key"("p_path" "text", "p_owner_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."is_client_storage_path"("p_path" "text", "p_owner_id" "uuid") RETURNS boolean
    LANGUAGE "sql" IMMUTABLE STRICT
    SET "search_path" TO ''
    AS $_$
  select char_length(p_path) between 1 and 500
    and p_path = btrim(p_path)
    and p_path not like '/%'
    and pg_catalog.strpos(p_path, pg_catalog.chr(92)) = 0
    and p_path !~ '(^|/)\.\.?(/|$)'
    and p_path like p_owner_id::text || '/%';
$_$;


ALTER FUNCTION "private"."is_client_storage_path"("p_path" "text", "p_owner_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."is_valid_iban"("p_iban" "text") RETURNS boolean
    LANGUAGE "plpgsql" IMMUTABLE STRICT PARALLEL SAFE
    SET "search_path" TO ''
    AS $_$
declare
  normalized text := private.normalize_iban(p_iban);
  rearranged text;
  current_character text;
  expanded_character text;
  remainder_value integer := 0;
begin
  if pg_catalog.char_length(normalized) < 15
     or pg_catalog.char_length(normalized) > 34
     or normalized !~ '^[A-Z]{2}[0-9]{2}[A-Z0-9]+$' then
    return false;
  end if;

  rearranged :=
    pg_catalog.substr(normalized, 5)
    || pg_catalog.substr(normalized, 1, 4);

  for character_index in 1..pg_catalog.char_length(rearranged) loop
    current_character := pg_catalog.substr(
      rearranged,
      character_index,
      1
    );

    if current_character ~ '^[0-9]$' then
      expanded_character := current_character;
    else
      expanded_character := (
        pg_catalog.ascii(current_character) - 55
      )::text;
    end if;

    for digit_index in 1..pg_catalog.char_length(expanded_character) loop
      remainder_value := (
        remainder_value * 10
        + pg_catalog.substr(
          expanded_character,
          digit_index,
          1
        )::integer
      ) % 97;
    end loop;
  end loop;

  return remainder_value = 1;
end;
$_$;


ALTER FUNCTION "private"."is_valid_iban"("p_iban" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."lock_client_mutation"("p_owner_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if p_owner_id is null then
    raise exception 'CLIENT_OWNER_REQUIRED' using errcode = '22023';
  end if;
  perform pg_catalog.pg_advisory_xact_lock_shared(
    private.client_purge_lock_key(p_owner_id)
  );
  if exists (
    select 1 from private.client_purge_operations operation
    where operation.target_user_id = p_owner_id
      and operation.consumed_at is not null
  ) then
    raise exception 'PURGE_TARGET_FROZEN' using errcode = '55000';
  end if;
end;
$$;


ALTER FUNCTION "private"."lock_client_mutation"("p_owner_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."new_document_paths_are_owned"("p_owner_id" "uuid", "p_new_paths" "jsonb", "p_old_paths" "jsonb" DEFAULT NULL::"jsonb") RETURNS boolean
    LANGUAGE "plpgsql" IMMUTABLE
    SET "search_path" TO ''
    AS $$
declare
  item jsonb;
  items jsonb;
  old_contains_item boolean;
begin
  if p_owner_id is null
     or jsonb_typeof(p_new_paths) not in ('object', 'array') then
    return false;
  end if;

  if jsonb_typeof(p_new_paths) = 'object' then
    select coalesce(jsonb_agg(value), '[]'::jsonb)
    into items from jsonb_each(p_new_paths);
  else
    items := p_new_paths;
  end if;

  for item in select value from jsonb_array_elements(items)
  loop
    if jsonb_typeof(item) is distinct from 'string' then
      return false;
    end if;
    if private.is_client_storage_path(item #>> '{}', p_owner_id) then
      continue;
    end if;

    old_contains_item := false;
    if jsonb_typeof(p_old_paths) = 'object' then
      select exists (select 1 from jsonb_each(p_old_paths) old where old.value = item)
      into old_contains_item;
    elsif jsonb_typeof(p_old_paths) = 'array' then
      select exists (
        select 1 from jsonb_array_elements(p_old_paths) old where old.value = item
      ) into old_contains_item;
    end if;
    if not old_contains_item then
      return false;
    end if;
  end loop;
  return true;
end;
$$;


ALTER FUNCTION "private"."new_document_paths_are_owned"("p_owner_id" "uuid", "p_new_paths" "jsonb", "p_old_paths" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."normalize_iban"("p_iban" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE STRICT PARALLEL SAFE
    SET "search_path" TO ''
    AS $$
  select pg_catalog.upper(
    pg_catalog.regexp_replace(p_iban, '[[:space:]]+', '', 'g')
  );
$$;


ALTER FUNCTION "private"."normalize_iban"("p_iban" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."normalize_notification_localization"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  searchable text := lower(coalesce(new.title, '') || ' ' || coalesce(new.message, ''));
begin
  if new.message_key is null or new.message_key not in (
    'generic_info',
    'transfer_submitted', 'transfer_approved', 'transfer_completed', 'transfer_rejected', 'transfer_failed',
    'loan_submitted', 'loan_approved', 'loan_disbursed', 'loan_rejected', 'loan_failed',
    'kyc_submitted', 'kyc_information_requested', 'kyc_resubmitted', 'kyc_approved', 'kyc_rejected',
    'document_available'
  ) then
    new.message_key := case
      when new.notification_type = 'info' and searchable like '%document%' then 'document_available'
      when new.notification_type = 'transfer' and searchable ~ '(effectué|exécuté|completed|settlement confirmed|ausgeführt|realizado|ejecutad)' then 'transfer_completed'
      when new.notification_type = 'transfer' and searchable ~ '(refus|reject|abgelehnt|rechaz)' then 'transfer_rejected'
      when new.notification_type = 'transfer' and searchable ~ '(échec|échoué|failed|fehlgeschlagen|fallid|no se pudo)' then 'transfer_failed'
      when new.notification_type = 'transfer' and searchable ~ '(validé|approved|genehmigt|aprob)' then 'transfer_approved'
      when new.notification_type = 'transfer' then 'transfer_submitted'
      when new.notification_type = 'loan' and searchable ~ '(décaissé|versé|paid|disbursed|ausgezahlt|abonado|desembols)' then 'loan_disbursed'
      when new.notification_type = 'loan' and searchable ~ '(refus|reject|abgelehnt|rechaz)' then 'loan_rejected'
      when new.notification_type = 'loan' and searchable ~ '(échec|échoué|failed|fehlgeschlagen|fallid|no se pudo)' then 'loan_failed'
      when new.notification_type = 'loan' and searchable ~ '(validé|approved|genehmigt|aprob)' then 'loan_approved'
      when new.notification_type = 'loan' then 'loan_submitted'
      when new.notification_type = 'kyc' and searchable ~ '(complément|additional|zusätz|adicional|action requise|required)' then 'kyc_information_requested'
      when new.notification_type = 'kyc' and searchable ~ '(correction|resubmi|erneut|reenvi)' then 'kyc_resubmitted'
      when new.notification_type = 'kyc' and searchable ~ '(approuv|confirm|approved|bestätigt|aprob)' then 'kyc_approved'
      when new.notification_type = 'kyc' and searchable ~ '(rejet|reject|abgelehnt|rechaz)' then 'kyc_rejected'
      when new.notification_type = 'kyc' then 'kyc_submitted'
      else 'generic_info'
    end;
  end if;

  if new.message_params is null or jsonb_typeof(new.message_params) <> 'object' then
    new.message_params := '{}'::jsonb;
  end if;

  -- Known events keep canonical French audit copy. Unknown historical entries
  -- retain their original audit text and are localized generically by clients.
  if new.message_key <> 'generic_info' then
    new.title := case new.message_key
      when 'transfer_submitted' then 'Virement enregistré'
      when 'transfer_approved' then 'Virement approuvé'
      when 'transfer_completed' then 'Virement exécuté'
      when 'transfer_rejected' then 'Virement refusé'
      when 'transfer_failed' then 'Virement non exécuté'
      when 'loan_submitted' then 'Demande de prêt enregistrée'
      when 'loan_approved' then 'Prêt approuvé'
      when 'loan_disbursed' then 'Prêt versé'
      when 'loan_rejected' then 'Demande de prêt refusée'
      when 'loan_failed' then 'Versement du prêt interrompu'
      when 'kyc_submitted' then 'Dossier d’identité transmis'
      when 'kyc_information_requested' then 'Informations complémentaires requises'
      when 'kyc_resubmitted' then 'Corrections transmises'
      when 'kyc_approved' then 'Identité vérifiée'
      when 'kyc_rejected' then 'Vérification d’identité non aboutie'
      when 'document_available' then 'Nouveau document disponible'
    end;
    new.message := case new.message_key
      when 'transfer_submitted' then 'L’instruction de virement a été transmise pour vérification.'
      when 'transfer_approved' then 'Le virement a été approuvé pour exécution.'
      when 'transfer_completed' then 'Le virement a été exécuté avec succès.'
      when 'transfer_rejected' then 'L’instruction de virement n’a pas été acceptée.'
      when 'transfer_failed' then 'Le virement n’a pas pu être exécuté.'
      when 'loan_submitted' then 'La demande de prêt a été transmise pour analyse.'
      when 'loan_approved' then 'La demande de prêt a été approuvée.'
      when 'loan_disbursed' then 'Les fonds du prêt ont été crédités sur le compte.'
      when 'loan_rejected' then 'La demande de prêt n’a pas été acceptée.'
      when 'loan_failed' then 'Le versement du prêt n’a pas pu être finalisé.'
      when 'kyc_submitted' then 'Le dossier d’identité a été transmis pour vérification.'
      when 'kyc_information_requested' then 'Des éléments complémentaires sont nécessaires pour vérifier l’identité.'
      when 'kyc_resubmitted' then 'Les corrections ont été transmises pour vérification.'
      when 'kyc_approved' then 'La vérification de l’identité est terminée.'
      when 'kyc_rejected' then 'Le dossier d’identité n’a pas pu être validé.'
      when 'document_available' then 'Un nouveau document officiel est disponible dans l’espace client.'
    end;
  end if;

  return new;
end;
$$;


ALTER FUNCTION "private"."normalize_notification_localization"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."prepare_demo_financial_position"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  demo_admin_id uuid;
  demo_admin_count integer;
  owner_email text;
  owner_metadata jsonb;
begin
  if new.id <> uuid 'd3000000-0000-4000-8000-000000000003' then
    return new;
  end if;

  select
    lower(coalesce(email, '')),
    coalesce(raw_app_meta_data, '{}'::jsonb)
  into owner_email, owner_metadata
  from auth.users
  where id = new.owner_id;

  if not found
     or owner_email <> 'client.demo@monalyz.com'
     or owner_metadata ->> 'monalyz_demo' <> 'true'
     or owner_metadata ->> 'demo_role' <> 'client' then
    raise exception 'INVALID_DEMO_BANK_ACCOUNT_OWNER'
      using errcode = '23514';
  end if;

  select count(*)::integer
  into demo_admin_count
  from auth.users as user_record
  join public.staff_members as staff
    on staff.user_id = user_record.id
  where user_record.raw_app_meta_data ->> 'monalyz_demo' = 'true'
    and user_record.raw_app_meta_data ->> 'demo_role' = 'admin'
    and staff.role = 'admin'
    and staff.active;

  if demo_admin_count <> 1 then
    raise exception 'DEMO_BRANCH_MANAGER_REQUIRED'
      using errcode = '23514';
  end if;

  select user_record.id
  into demo_admin_id
  from auth.users as user_record
  join public.staff_members as staff
    on staff.user_id = user_record.id
  where user_record.raw_app_meta_data ->> 'monalyz_demo' = 'true'
    and user_record.raw_app_meta_data ->> 'demo_role' = 'admin'
    and staff.role = 'admin'
    and staff.active;

  new.account_number := 'DEMO-EUR-000001';
  new.iban := 'FR5299999999990000000000100';
  new.bic := 'DEMOFRP1XXX';
  new.account_holder_name := 'Client Démo Monalyz';
  new.institution_name := 'Monalyz Démonstration — non routable';
  new.branch_name := 'Agence Démonstration';
  new.branch_code := 'DEMO-001';
  new.account_status := 'active';
  new.opened_at := coalesce(
    new.opened_at,
    timestamptz '2026-01-01 00:00:00+00'
  );
  new.declared_by := demo_admin_id;
  new.is_demo := true;

  return new;
end;
$$;


ALTER FUNCTION "private"."prepare_demo_financial_position"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."prevent_financial_ledger_mutation"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if pg_catalog.current_setting(
    'monalyz.allow_ledger_maintenance',
    true
  ) is distinct from 'on' then
    raise exception 'FINANCIAL_LEDGER_IS_APPEND_ONLY'
      using errcode = '55000';
  end if;

  return old;
end;
$$;


ALTER FUNCTION "private"."prevent_financial_ledger_mutation"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."prevent_purge_target_promotion"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if new.user_id is not null then
    if not pg_catalog.pg_try_advisory_xact_lock_shared(
      private.client_purge_lock_key(new.user_id)
    ) then
      raise exception 'PURGE_TARGET_PROMOTION_BUSY' using errcode = '55P03';
    end if;
    if exists (
      select 1 from private.client_purge_operations operation
      where operation.target_user_id = new.user_id
        and operation.consumed_at is not null
    ) then
      raise exception 'PURGE_TARGET_PROMOTION_FORBIDDEN' using errcode = '55000';
    end if;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "private"."prevent_purge_target_promotion"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."protect_official_document"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if tg_op = 'DELETE' then
    if pg_catalog.current_setting('monalyz.allow_official_document_maintenance', true) is distinct from 'on' then
      raise exception 'OFFICIAL_DOCUMENT_RETENTION_REQUIRED' using errcode = '55000';
    end if;
    return old;
  end if;

  if new.owner_id <> old.owner_id
     or new.account_id is distinct from old.account_id
     or new.transfer_id is distinct from old.transfer_id
     or new.loan_id is distinct from old.loan_id
     or new.document_number <> old.document_number
     or new.document_type <> old.document_type
     or new.title <> old.title
     or new.language <> old.language
     or new.period_start is distinct from old.period_start
     or new.period_end is distinct from old.period_end
     or new.version <> old.version
     or new.snapshot <> old.snapshot
     or new.snapshot_hash <> old.snapshot_hash
     or new.issued_by <> old.issued_by
     or new.requested_at <> old.requested_at
     or new.is_demo <> old.is_demo
     or new.idempotency_key <> old.idempotency_key
     or new.localization_revision <> old.localization_revision
     or new.supersedes_document_id is distinct from old.supersedes_document_id
     or new.created_at <> old.created_at then
    raise exception 'OFFICIAL_DOCUMENT_SNAPSHOT_IS_IMMUTABLE' using errcode = '55000';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "private"."protect_official_document"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."refresh_client_purge_entity_manifest"("p_challenge_id" "uuid", "p_target_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if not exists (
    select 1 from private.client_purge_operations operation
    where operation.challenge_id = p_challenge_id
      and operation.target_user_id = p_target_user_id
  ) then
    raise exception 'PURGE_OPERATION_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- A preview is informational and may span several requests. Never reuse its
  -- ownership snapshot for execution: under the caller's owner lock, replace
  -- it with the exact current graph so a relation moved to another client
  -- cannot be deleted through a stale manifest entry.
  delete from private.client_purge_entity_manifest
  where challenge_id = p_challenge_id;

  insert into private.client_purge_entity_manifest (
    challenge_id, entity_type, entity_id
  )
  select p_challenge_id, entity.entity_type, entity.entity_id
  from (
    select 'user'::text, p_target_user_id::text
    union all select 'profile', profile.user_id::text from public.profiles profile
      where profile.user_id = p_target_user_id
    union all select 'kyc_application', application.id::text from public.kyc_applications application
      where application.owner_id = p_target_user_id
    union all select 'kyc_draft', draft.owner_id::text from public.kyc_drafts draft
      where draft.owner_id = p_target_user_id
    union all select 'financial_position', position.id::text from public.financial_positions position
      where position.owner_id = p_target_user_id
    union all select 'financial_ledger_entry', entry.id::text from public.financial_ledger_entries entry
      where entry.owner_id = p_target_user_id
    union all select 'loan_application', loan.id::text from public.loan_applications loan
      where loan.owner_id = p_target_user_id
    union all select 'transfer_intent', transfer.id::text from public.transfer_intents transfer
      where transfer.owner_id = p_target_user_id
    union all select 'official_document', document.id::text from public.official_documents document
      where document.owner_id = p_target_user_id
    union all select 'notification', notification.id::text from public.notifications notification
      where notification.recipient_id = p_target_user_id
    union all select 'email_outbox', outbox.id::text from public.transactional_email_outbox outbox
      where outbox.recipient_id = p_target_user_id or outbox.claimed_by = p_target_user_id
    union all select 'push_subscription', subscription.id::text from public.push_subscriptions subscription
      where subscription.user_id = p_target_user_id
    union all select 'support_identity', identity.id::text from public.support_user_identities identity
      where identity.user_id = p_target_user_id
    union all select 'support_transcript', transcript.id::text from public.support_transcripts transcript
      where transcript.user_id = p_target_user_id
    union all select 'support_push_delivery', delivery.id::text
      from public.support_push_deliveries delivery
      join public.support_transcripts transcript on transcript.id = delivery.transcript_id
      where transcript.user_id = p_target_user_id
    union all select 'kyc_review_checklist', checklist.kyc_id::text
      from public.kyc_review_checklists checklist
      join public.kyc_applications application on application.id = checklist.kyc_id
      where application.owner_id = p_target_user_id
    union all select 'loan_review_check', review.id::text
      from public.loan_review_checks review
      join public.loan_applications loan on loan.id = review.loan_id
      where loan.owner_id = p_target_user_id
    union all select 'transfer_review_check', review.id::text
      from public.transfer_review_checks review
      join public.transfer_intents transfer on transfer.id = review.transfer_id
      where transfer.owner_id = p_target_user_id
    union all select 'external_loan_funding', funding.loan_id::text
      from public.external_loan_fundings funding
      join public.loan_applications loan on loan.id = funding.loan_id
      where loan.owner_id = p_target_user_id
    union all select 'external_transfer_execution', execution.transfer_id::text
      from public.external_transfer_executions execution
      join public.transfer_intents transfer on transfer.id = execution.transfer_id
      where transfer.owner_id = p_target_user_id
    union all select 'kyc_event', event.id::text from public.kyc_events event
      where event.actor_id = p_target_user_id or event.kyc_id in (
        select application.id from public.kyc_applications application
        where application.owner_id = p_target_user_id
      )
    union all select 'loan_event', event.id::text from public.loan_events event
      where event.actor_id = p_target_user_id or event.loan_id in (
        select loan.id from public.loan_applications loan where loan.owner_id = p_target_user_id
      )
    union all select 'transfer_event', event.id::text from public.transfer_events event
      where event.actor_id = p_target_user_id or event.transfer_id in (
        select transfer.id from public.transfer_intents transfer where transfer.owner_id = p_target_user_id
      )
  ) entity(entity_type, entity_id)
  where entity.entity_id is not null
  on conflict (challenge_id, entity_type, entity_id) do nothing;
end;
$$;


ALTER FUNCTION "private"."refresh_client_purge_entity_manifest"("p_challenge_id" "uuid", "p_target_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."reject_reserved_purge_email"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  normalized_new_email text := lower(btrim(new.email));
begin
  -- The retired UUID remains the immutable key of the delayed Storage sweep.
  if tg_op = 'INSERT' and exists (
    select 1
    from private.client_purge_operations operation
    where operation.target_user_id = new.id
      and operation.consumed_at is not null
  ) then
    raise exception 'PURGE_TARGET_ID_RESERVED' using errcode = '55000';
  end if;

  -- The target may not change identity while its guarded erasure is active.
  if tg_op = 'UPDATE' and exists (
    select 1
    from private.client_purge_operations operation
    where operation.target_user_id = old.id
      and operation.consumed_at is not null
  ) then
    raise exception 'PURGE_TARGET_EMAIL_RESERVED' using errcode = '55000';
  end if;

  -- Reserve the address only while the retired Auth row still exists. Once
  -- that UUID has been deleted, the remaining Storage sweep is UUID-scoped
  -- and must not prevent a fresh test account from claiming the same address.
  if normalized_new_email is not null and exists (
    select 1
    from private.client_purge_operations operation
    where operation.consumed_at is not null
      and lower(btrim(operation.target_email)) = normalized_new_email
      and exists (
        select 1
        from auth.users target_user
        where target_user.id = operation.target_user_id
      )
  ) then
    raise exception 'PURGE_TARGET_EMAIL_RESERVED' using errcode = '55000';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "private"."reject_reserved_purge_email"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."remove_iban_from_new_official_document"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  new.snapshot := new.snapshot #- '{account,iban}';
  new.snapshot_hash := encode(
    extensions.digest(
      convert_to(new.snapshot::text, 'UTF8'),
      'sha256'
    ),
    'hex'
  );
  return new;
end;
$$;


ALTER FUNCTION "private"."remove_iban_from_new_official_document"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."require_active_purge_admin"("p_actor_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if p_actor_id is null or not exists (
    select 1
    from public.staff_members as staff
    join auth.users as users on users.id = staff.user_id
    where staff.user_id = p_actor_id
      and staff.role = 'admin'
      and staff.active
  ) then
    raise exception 'ACTIVE_ADMIN_REQUIRED' using errcode = '42501';
  end if;
end;
$$;


ALTER FUNCTION "private"."require_active_purge_admin"("p_actor_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."retire_support_user_identity"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  update public.support_user_identities
  set valid_to = greatest(statement_timestamp(), valid_from)
  where user_id = old.id
    and valid_to is null;

  return old;
end;
$$;


ALTER FUNCTION "private"."retire_support_user_identity"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."seed_client_purge_storage_roots"("p_challenge_id" "uuid", "p_cycle_stage" "text", "p_target_user_id" "uuid") RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  insert into private.client_purge_storage_scan_queue (
    challenge_id, cycle_stage, bucket, prefix
  )
  select p_challenge_id, p_cycle_stage, bucket, p_target_user_id::text
  from unnest(array[
    'upload-staging', 'kyc-evidence', 'loan-evidence', 'official-documents'
  ]) bucket
  on conflict (challenge_id, cycle_stage, bucket, prefix) do nothing;
$$;


ALTER FUNCTION "private"."seed_client_purge_storage_roots"("p_challenge_id" "uuid", "p_cycle_stage" "text", "p_target_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO ''
    AS $$
begin
  new.updated_at := now();
  if to_jsonb(new) ? 'version' then
    new.version := old.version + 1;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "private"."set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."snapshot_official_document_brand"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  select bank_name, revision, pdf_logo_path
  into
    new.brand_name_snapshot,
    new.brand_revision_snapshot,
    new.brand_logo_path_snapshot
  from public.brand_settings
  where singleton = true;

  if new.brand_name_snapshot is null then
    raise exception 'BRAND_SETTINGS_NOT_FOUND' using errcode = 'P0002';
  end if;
  return new;
end;
$$;


ALTER FUNCTION "private"."snapshot_official_document_brand"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."sync_support_user_identity"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  normalized_new_email text := lower(btrim(coalesce(new.email, '')));
  changed_at timestamptz := statement_timestamp();
begin
  update public.support_user_identities
  set valid_to = greatest(changed_at, valid_from)
  where user_id = new.id
    and valid_to is null
    and normalized_email is distinct from normalized_new_email;

  if normalized_new_email = '' then
    return new;
  end if;

  if char_length(normalized_new_email) > 254
     or normalized_new_email !~ '^[^[:space:]@]+@[^[:space:]@]+$'
  then
    raise exception 'INVALID_SUPPORT_IDENTITY_EMAIL' using errcode = '22023';
  end if;

  update public.profiles
  set email = normalized_new_email
  where user_id = new.id
    and email is distinct from normalized_new_email;

  if not exists (
    select 1
    from public.support_user_identities
    where user_id = new.id
      and normalized_email = normalized_new_email
      and valid_to is null
  ) then
    insert into public.support_user_identities (
      user_id,
      normalized_email,
      valid_from
    )
    values (
      new.id,
      normalized_new_email,
      changed_at
    );
  end if;

  return new;
end;
$_$;


ALTER FUNCTION "private"."sync_support_user_identity"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."try_guard_client_mutation"("p_owner_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if p_owner_id is null
     or current_setting('monalyz.client_purge_maintenance', true) = 'on' then
    return;
  end if;
  if not pg_catalog.pg_try_advisory_xact_lock_shared(
    private.client_purge_lock_key(p_owner_id)
  ) then
    raise exception 'PURGE_TARGET_MUTATION_BUSY' using errcode = '55P03';
  end if;
  if exists (
    select 1 from private.client_purge_operations operation
    where operation.target_user_id = p_owner_id
      and operation.consumed_at is not null
  ) then
    raise exception 'PURGE_TARGET_FROZEN' using errcode = '55000';
  end if;
end;
$$;


ALTER FUNCTION "private"."try_guard_client_mutation"("p_owner_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."uuid_or_null"("p_value" "text") RETURNS "uuid"
    LANGUAGE "sql" IMMUTABLE
    SET "search_path" TO ''
    AS $_$
  select case
    when p_value ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      then p_value::uuid
    else null
  end;
$_$;


ALTER FUNCTION "private"."uuid_or_null"("p_value" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."validate_financial_ledger_entry"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  position_row public.financial_positions;
begin
  select *
  into position_row
  from public.financial_positions
  where id = new.account_id;

  if not found then
    raise exception 'LEDGER_POSITION_NOT_FOUND' using errcode = '23503';
  end if;

  if new.owner_id <> position_row.owner_id then
    raise exception 'LEDGER_OWNER_MISMATCH' using errcode = '23514';
  end if;

  if new.currency <> position_row.currency then
    raise exception 'LEDGER_CURRENCY_MISMATCH' using errcode = '23514';
  end if;

  return new;
end;
$$;


ALTER FUNCTION "private"."validate_financial_ledger_entry"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."validate_kyc_submission"("p_first_name" "text", "p_last_name" "text", "p_date_of_birth" "date", "p_place_of_birth" "text", "p_nationality" "text", "p_address" "jsonb", "p_occupation" "text", "p_income_range" "text", "p_document_type" "text", "p_document_number" "text", "p_issuing_country" "text", "p_document_expires_on" "date", "p_document_object_paths" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if nullif(trim(coalesce(p_first_name, '')), '') is null
     or nullif(trim(coalesce(p_last_name, '')), '') is null
     or p_date_of_birth is null
     or p_date_of_birth > current_date - interval '18 years'
     or nullif(trim(coalesce(p_place_of_birth, '')), '') is null
     or nullif(trim(coalesce(p_nationality, '')), '') is null
     or jsonb_typeof(p_address) <> 'object'
     or nullif(trim(coalesce(p_address ->> 'street', '')), '') is null
     or nullif(trim(coalesce(p_address ->> 'postalCode', '')), '') is null
     or nullif(trim(coalesce(p_address ->> 'city', '')), '') is null
     or nullif(trim(coalesce(p_address ->> 'country', '')), '') is null
     or nullif(trim(coalesce(p_occupation, '')), '') is null
     or nullif(trim(coalesce(p_income_range, '')), '') is null
     or p_document_type not in (
       'national_identity_card',
       'passport',
       'residence_permit'
     )
     or nullif(trim(coalesce(p_document_number, '')), '') is null
     or nullif(trim(coalesce(p_issuing_country, '')), '') is null
     or p_document_expires_on is null
     or p_document_expires_on < current_date
     or jsonb_typeof(p_document_object_paths) <> 'object'
     or not (p_document_object_paths ? 'id_front')
     or not (p_document_object_paths ? 'proof_of_address')
     or (
       p_document_type <> 'passport'
       and not (p_document_object_paths ? 'id_back')
     ) then
    raise exception 'INVALID_OR_INCOMPLETE_KYC' using errcode = '22023';
  end if;
end;
$$;


ALTER FUNCTION "private"."validate_kyc_submission"("p_first_name" "text", "p_last_name" "text", "p_date_of_birth" "date", "p_place_of_birth" "text", "p_nationality" "text", "p_address" "jsonb", "p_occupation" "text", "p_income_range" "text", "p_document_type" "text", "p_document_number" "text", "p_issuing_country" "text", "p_document_expires_on" "date", "p_document_object_paths" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."validate_loan_disbursement_target"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if new.status = 'external_settlement_confirmed' then
    if new.credited_position_id is null
       or new.disbursed_by is null
       or new.disbursed_at is null then
      raise exception 'LOAN_DISBURSEMENT_METADATA_REQUIRED' using errcode = '23514';
    end if;

    if not exists (
      select 1
      from public.financial_positions as position
      where position.id = new.credited_position_id
        and position.owner_id = new.owner_id
        and position.currency = new.currency
        and position.account_type = 'current'
    ) then
      raise exception 'INVALID_LOAN_DISBURSEMENT_TARGET' using errcode = '23514';
    end if;
  elsif new.credited_position_id is not null
     or new.disbursed_by is not null
     or new.disbursed_at is not null then
    raise exception 'LOAN_DISBURSEMENT_METADATA_WITHOUT_FINAL_STATUS'
      using errcode = '23514';
  end if;

  return new;
end;
$$;


ALTER FUNCTION "private"."validate_loan_disbursement_target"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."financial_positions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "owner_id" "uuid" NOT NULL,
    "label" "text" NOT NULL,
    "position_kind" "text" DEFAULT 'declared'::"text" NOT NULL,
    "currency" "text" NOT NULL,
    "amount_minor" bigint DEFAULT 0 NOT NULL,
    "reserved_minor" bigint DEFAULT 0 NOT NULL,
    "as_of" timestamp with time zone DEFAULT "now"() NOT NULL,
    "external_identifier_masked" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "version" integer DEFAULT 1 NOT NULL,
    "account_type" "text" DEFAULT 'current'::"text" NOT NULL,
    "account_number" "text",
    "iban" "text",
    "bic" "text",
    "account_holder_name" "text",
    "institution_name" "text",
    "branch_name" "text",
    "branch_code" "text",
    "account_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "opened_at" timestamp with time zone,
    "declared_by" "uuid",
    "is_demo" boolean DEFAULT false NOT NULL,
    "declaration_idempotency_key" "uuid",
    "source_kyc_id" "uuid",
    CONSTRAINT "financial_positions_account_number_check" CHECK ((("account_number" IS NULL) OR (("account_number" = "upper"(TRIM(BOTH FROM "account_number"))) AND ("account_number" ~ '^[A-Z0-9-]{6,34}$'::"text")))),
    CONSTRAINT "financial_positions_account_status_check" CHECK (("account_status" = ANY (ARRAY['pending'::"text", 'active'::"text", 'restricted'::"text", 'closed'::"text"]))),
    CONSTRAINT "financial_positions_account_type_check" CHECK (("account_type" = ANY (ARRAY['current'::"text", 'savings'::"text"]))),
    CONSTRAINT "financial_positions_active_account_check" CHECK ((("account_status" <> 'active'::"text") OR (("account_number" IS NOT NULL) AND ("account_holder_name" IS NOT NULL) AND ("opened_at" IS NOT NULL) AND ("declared_by" IS NOT NULL)))),
    CONSTRAINT "financial_positions_amount_minor_check" CHECK ((("amount_minor" >= 0) AND ("amount_minor" <= '1000000000000000'::bigint))),
    CONSTRAINT "financial_positions_bic_check" CHECK ((("bic" IS NULL) OR (("bic" = "upper"(TRIM(BOTH FROM "bic"))) AND ("bic" ~ '^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$'::"text")))),
    CONSTRAINT "financial_positions_check" CHECK ((("reserved_minor" >= 0) AND ("reserved_minor" <= "amount_minor"))),
    CONSTRAINT "financial_positions_currency_check" CHECK (("currency" ~ '^[A-Z]{3}$'::"text")),
    CONSTRAINT "financial_positions_iban_check" CHECK ((("iban" IS NULL) OR (("iban" = "private"."normalize_iban"("iban")) AND "private"."is_valid_iban"("iban")))),
    CONSTRAINT "financial_positions_label_check" CHECK ((("char_length"("label") >= 1) AND ("char_length"("label") <= 120))),
    CONSTRAINT "financial_positions_official_text_lengths_check" CHECK (((("account_holder_name" IS NULL) OR (("char_length"("account_holder_name") >= 1) AND ("char_length"("account_holder_name") <= 160))) AND (("institution_name" IS NULL) OR (("char_length"("institution_name") >= 1) AND ("char_length"("institution_name") <= 200))) AND (("branch_name" IS NULL) OR (("char_length"("branch_name") >= 1) AND ("char_length"("branch_name") <= 160))) AND (("branch_code" IS NULL) OR ((("char_length"("branch_code") >= 1) AND ("char_length"("branch_code") <= 40)) AND ("branch_code" ~ '^[A-Z0-9-]+$'::"text"))))),
    CONSTRAINT "financial_positions_position_kind_check" CHECK (("position_kind" = ANY (ARRAY['declared'::"text", 'internally_reconciled'::"text"]))),
    CONSTRAINT "financial_positions_version_check" CHECK (("version" > 0))
);


ALTER TABLE "public"."financial_positions" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."adjust_financial_position"("p_position_id" "uuid", "p_delta_minor" bigint, "p_as_of" timestamp with time zone, "p_reason" "text") RETURNS "public"."financial_positions"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_id uuid := (select auth.uid());
  position_row public.financial_positions;
begin
  if caller_id is null or not private.is_active_staff(array['supervisor', 'admin']) then
    raise exception 'SUPERVISOR_PERMISSION_REQUIRED' using errcode = '42501';
  end if;
  if p_delta_minor = 0 or p_as_of is null then
    raise exception 'INVALID_ADJUSTMENT_VALUE' using errcode = '22023';
  end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then
    raise exception 'ADJUSTMENT_REASON_REQUIRED' using errcode = '22023';
  end if;

  select *
  into position_row
  from public.financial_positions
  where id = p_position_id
  for update;

  if not found then
    raise exception 'POSITION_NOT_FOUND' using errcode = 'P0002';
  end if;

  if position_row.amount_minor + p_delta_minor < position_row.reserved_minor then
    raise exception 'ADJUSTMENT_CONFLICTS_WITH_RESERVATIONS' using errcode = '22003';
  end if;

  update public.financial_positions
  set
    amount_minor = amount_minor + p_delta_minor,
    position_kind = 'internally_reconciled',
    as_of = p_as_of
  where id = p_position_id
  returning * into position_row;

  insert into public.audit_events (
    actor_id, action, entity_type, entity_id, metadata
  )
  values (
    caller_id,
    'adjust_financial_position',
    'financial_position',
    p_position_id,
    jsonb_build_object(
      'delta_minor', p_delta_minor,
      'as_of', p_as_of,
      'reason', p_reason
    )
  );

  return position_row;
end;
$$;


ALTER FUNCTION "public"."adjust_financial_position"("p_position_id" "uuid", "p_delta_minor" bigint, "p_as_of" timestamp with time zone, "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_ack_client_purge_storage_work"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_challenge_id" "uuid", "p_claim_token" "uuid", "p_kind" "text", "p_result" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  operation private.client_purge_operations;
  queue_row private.client_purge_storage_scan_queue;
  item jsonb;
  item_path text;
  returned_count integer;
  empty_prefix boolean;
begin
  perform private.require_active_purge_admin(p_actor_id);
  if p_claim_token is null or p_kind is null
     or p_kind not in ('scan', 'delete', 'verify_manifest', 'verify_prefix')
     or p_result is null or jsonb_typeof(p_result) is distinct from 'object' then
    raise exception 'PURGE_STORAGE_ACK_INVALID' using errcode = '22023';
  end if;
  select * into operation from private.client_purge_operations
  where challenge_id = p_challenge_id and actor_id = p_actor_id
    and target_user_id = p_target_user_id for update;
  if not found then
    raise exception 'PURGE_OPERATION_NOT_FOUND' using errcode = 'P0002';
  end if;

  if p_kind = 'scan' then
    if not (p_result ? 'objects' and p_result ? 'prefixes' and p_result ? 'returnedCount')
       or (select count(*) from jsonb_object_keys(p_result)) <> 3
       or jsonb_typeof(p_result -> 'objects') is distinct from 'array'
       or jsonb_typeof(p_result -> 'prefixes') is distinct from 'array'
       or jsonb_typeof(p_result -> 'returnedCount') is distinct from 'number' then
      raise exception 'PURGE_STORAGE_ACK_INVALID' using errcode = '22023';
    end if;
    returned_count := (p_result ->> 'returnedCount')::integer;
    if returned_count not between 0 and 1000
       or returned_count <> jsonb_array_length(p_result -> 'objects')
          + jsonb_array_length(p_result -> 'prefixes') then
      raise exception 'PURGE_STORAGE_ACK_INVALID' using errcode = '22023';
    end if;
    select * into queue_row from private.client_purge_storage_scan_queue queue
    where queue.challenge_id = p_challenge_id and queue.claim_token = p_claim_token
      and queue.status = 'claimed' for update;
    if not found then
      raise exception 'PURGE_STORAGE_CLAIM_INVALID' using errcode = '55000';
    end if;
    for item in select value from jsonb_array_elements(p_result -> 'objects') loop
      if jsonb_typeof(item) is distinct from 'string' then
        raise exception 'PURGE_STORAGE_ACK_INVALID' using errcode = '22023';
      end if;
      item_path := item #>> '{}';
      if not private.is_client_storage_object_key(item_path, p_target_user_id) then
        raise exception 'PURGE_MANIFEST_OWNERSHIP_INVALID' using errcode = '42501';
      end if;
      insert into private.client_purge_storage_manifest (
        challenge_id, bucket, object_path, ownership_scope, processing_status
      ) values (
        p_challenge_id, queue_row.bucket, item_path, 'target_prefix', 'pending'
      ) on conflict (challenge_id, bucket, object_path) do update
      set ownership_scope = 'target_prefix', processing_status = 'pending',
          claim_token = null, claimed_at = null, deleted_at = null, verified_at = null;
    end loop;
    for item in select value from jsonb_array_elements(p_result -> 'prefixes') loop
      if jsonb_typeof(item) is distinct from 'string' then
        raise exception 'PURGE_STORAGE_ACK_INVALID' using errcode = '22023';
      end if;
      item_path := item #>> '{}';
      if not private.is_client_storage_object_key(item_path || '/_', p_target_user_id) then
        raise exception 'PURGE_SCAN_PREFIX_INVALID' using errcode = '42501';
      end if;
      insert into private.client_purge_storage_scan_queue (
        challenge_id, cycle_stage, bucket, prefix
      ) values (p_challenge_id, queue_row.cycle_stage, queue_row.bucket, item_path)
      on conflict (challenge_id, cycle_stage, bucket, prefix) do nothing;
    end loop;
    update private.client_purge_storage_scan_queue
    set status = case when returned_count = 1000 then 'pending' else 'done' end,
        next_offset = case when returned_count = 1000
          then next_offset + returned_count else next_offset end,
        claim_token = null, claimed_at = null, updated_at = statement_timestamp()
    where id = queue_row.id and claim_token = p_claim_token;
  elsif p_kind = 'delete' then
    if not (p_result ? 'removed')
       or (select count(*) from jsonb_object_keys(p_result)) <> 1
       or jsonb_typeof(p_result -> 'removed') is distinct from 'boolean' then
      raise exception 'PURGE_STORAGE_ACK_INVALID' using errcode = '22023';
    end if;
    update private.client_purge_storage_manifest
    set processing_status = case when (p_result ->> 'removed')::boolean
        then 'deleted' else 'pending' end,
      claim_token = null, claimed_at = null,
      deleted_at = case when (p_result ->> 'removed')::boolean
        then pg_catalog.clock_timestamp() else deleted_at end
    where challenge_id = p_challenge_id and claim_token = p_claim_token
      and processing_status = 'delete_claimed';
    if not found then
      raise exception 'PURGE_STORAGE_CLAIM_INVALID' using errcode = '55000';
    end if;
  elsif p_kind = 'verify_manifest' then
    if not (p_result ? 'absent')
       or (select count(*) from jsonb_object_keys(p_result)) <> 1
       or jsonb_typeof(p_result -> 'absent') is distinct from 'boolean' then
      raise exception 'PURGE_STORAGE_ACK_INVALID' using errcode = '22023';
    end if;
    update private.client_purge_storage_manifest
    set processing_status = case when (p_result ->> 'absent')::boolean
        then 'verified' else 'pending' end,
      claim_token = null, claimed_at = null,
      verified_at = case when (p_result ->> 'absent')::boolean
        then pg_catalog.clock_timestamp() else null end
    where challenge_id = p_challenge_id and claim_token = p_claim_token
      and processing_status = 'verify_claimed';
    if not found then
      raise exception 'PURGE_STORAGE_CLAIM_INVALID' using errcode = '55000';
    end if;
    if not (p_result ->> 'absent')::boolean then
      update private.client_purge_operations set storage_phase = 'delete',
        updated_at = statement_timestamp() where challenge_id = p_challenge_id;
    end if;
  else
    if not (p_result ? 'empty')
       or (select count(*) from jsonb_object_keys(p_result)) <> 1
       or jsonb_typeof(p_result -> 'empty') is distinct from 'boolean'
       or operation.prefix_claim_token is distinct from p_claim_token then
      raise exception 'PURGE_STORAGE_ACK_INVALID' using errcode = '22023';
    end if;
    empty_prefix := (p_result ->> 'empty')::boolean;
    if empty_prefix then
      update private.client_purge_operations
      set verify_prefix_index = verify_prefix_index + 1,
          prefix_claim_token = null, prefix_claimed_at = null,
          updated_at = statement_timestamp()
      where challenge_id = p_challenge_id;
    else
      delete from private.client_purge_storage_scan_queue
      where challenge_id = p_challenge_id
        and cycle_stage = operation.storage_cycle_stage
        and bucket = (array[
          'upload-staging', 'kyc-evidence', 'loan-evidence', 'official-documents'
        ])[operation.verify_prefix_index + 1];
      insert into private.client_purge_storage_scan_queue (
        challenge_id, cycle_stage, bucket, prefix
      ) values (
        p_challenge_id, operation.storage_cycle_stage,
        (array['upload-staging', 'kyc-evidence', 'loan-evidence', 'official-documents'])[
          operation.verify_prefix_index + 1
        ], p_target_user_id::text
      );
      update private.client_purge_operations
      set storage_phase = 'scan', prefix_claim_token = null,
          prefix_claimed_at = null, updated_at = statement_timestamp()
      where challenge_id = p_challenge_id;
    end if;
  end if;

  update private.client_purge_operations
  set retry_after = case when consumed_at is null then retry_after
      else statement_timestamp() end,
      expires_at = case when consumed_at is null
        then pg_catalog.clock_timestamp() + interval '5 minutes' else expires_at end,
      updated_at = statement_timestamp()
  where challenge_id = p_challenge_id;
  return jsonb_build_object('acknowledged', true, 'kind', p_kind);
end;
$$;


ALTER FUNCTION "public"."admin_ack_client_purge_storage_work"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_challenge_id" "uuid", "p_claim_token" "uuid", "p_kind" "text", "p_result" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_assert_client_purge_auth_ready"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_challenge_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  operation private.client_purge_operations;
  current_target_email text;
  immediate_release_ready boolean;
  legacy_release_ready boolean;
begin
  perform private.require_active_purge_admin(p_actor_id);
  if p_target_user_id is null or p_target_user_id = p_actor_id then
    raise exception 'SELF_PURGE_FORBIDDEN' using errcode = '42501';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    private.client_purge_lock_key(p_target_user_id)
  );
  if exists (select 1 from public.staff_members where user_id = p_target_user_id) then
    raise exception 'STAFF_PURGE_FORBIDDEN' using errcode = '42501';
  end if;

  select * into operation
  from private.client_purge_operations
  where challenge_id = p_challenge_id
    and actor_id = p_actor_id
    and target_user_id = p_target_user_id
    and consumed_at is not null
  for update;

  immediate_release_ready := found
    and operation.stage = 'auth'
    and operation.storage_cycle_stage = 'storage'
    and operation.storage_phase = 'complete'
    and operation.sweep_not_before is not null;
  legacy_release_ready := found
    and operation.stage = 'auth'
    and operation.storage_cycle_stage = 'storage_sweep'
    and operation.storage_phase = 'complete'
    and operation.sweep_not_before is not null
    and operation.sweep_not_before <= statement_timestamp();
  if not (immediate_release_ready or legacy_release_ready) then
    raise exception 'PURGE_AUTH_STAGE_INVALID' using errcode = '55000';
  end if;
  if exists (
    select 1
    from public.profiles profile
    where profile.user_id = p_target_user_id
      and profile.access_status <> 'frozen'
  ) then
    raise exception 'PURGE_TARGET_NOT_FROZEN' using errcode = '55000';
  end if;

  select lower(btrim(users.email)) into current_target_email
  from auth.users users
  where users.id = p_target_user_id
  for update;
  if found and current_target_email is distinct from lower(btrim(operation.target_email)) then
    raise exception 'PURGE_TARGET_EMAIL_CHANGED' using errcode = '55000';
  end if;

  return jsonb_build_object(
    'allowed', true,
    'targetEmail', operation.target_email,
    'authExists', exists (select 1 from auth.users where id = p_target_user_id),
    'sweepNotBefore', operation.sweep_not_before,
    'ignoredUnsafeStorageReferences', operation.ignored_unsafe_storage_references
  );
end;
$$;


ALTER FUNCTION "public"."admin_assert_client_purge_auth_ready"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_challenge_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_begin_client_purge"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_challenge_id" "uuid", "p_challenge_digest" "text", "p_target_email_digest" "text", "p_idempotency_key" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  operation private.client_purge_operations;
  frozen_profile_count integer;
  current_target_email text;
  support_emails text[];
  current_scope_digest text;
  evidence_path text;
begin
  perform private.require_active_purge_admin(p_actor_id);

  if p_target_user_id = p_actor_id then
    raise exception 'SELF_PURGE_FORBIDDEN' using errcode = '42501';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    private.client_purge_lock_key(p_target_user_id)
  );
  if exists (select 1 from public.staff_members where user_id = p_target_user_id) then
    raise exception 'STAFF_PURGE_FORBIDDEN' using errcode = '42501';
  end if;

  select * into operation
  from private.client_purge_operations
  where challenge_id = p_challenge_id
  for update;

  if not found
     or operation.actor_id is distinct from p_actor_id
     or operation.target_user_id is distinct from p_target_user_id
     or operation.challenge_digest is distinct from p_challenge_digest
     or operation.target_email_digest is distinct from p_target_email_digest
     or operation.idempotency_key is distinct from p_idempotency_key then
    raise exception 'PURGE_CHALLENGE_INVALID' using errcode = '42501';
  end if;
  if operation.status <> 'preview'
     and operation.stage in ('storage', 'database', 'waiting_sweep', 'storage_sweep')
     and exists (
       select 1 from public.profiles
       where user_id = p_target_user_id and access_status <> 'frozen'
     ) then
    raise exception 'PURGE_TARGET_NOT_FROZEN' using errcode = '55000';
  end if;

  if operation.status = 'preview' then
    if operation.expires_at <= statement_timestamp() then
      raise exception 'PURGE_CHALLENGE_EXPIRED' using errcode = '22023';
    end if;
    if operation.storage_cycle_stage is distinct from 'preview'
       or operation.storage_phase is distinct from 'complete' then
      raise exception 'PURGE_PREVIEW_INCOMPLETE' using errcode = '55000';
    end if;
    select users.email into current_target_email
    from auth.users users where users.id = p_target_user_id for update;
    if not found then
      raise exception 'CLIENT_NOT_FOUND' using errcode = 'P0002';
    end if;
    if current_target_email is null
       or current_target_email is distinct from operation.target_email then
      raise exception 'PURGE_TARGET_EMAIL_CHANGED' using errcode = '55000';
    end if;

    for evidence_path in
      select target_path.object_path
      from (
        select execution.evidence_object_path as object_path
        from public.external_transfer_executions execution
        join public.transfer_intents transfer on transfer.id = execution.transfer_id
        where transfer.owner_id = p_target_user_id
        union
        select funding.evidence_object_path
        from public.external_loan_fundings funding
        join public.loan_applications loan on loan.id = funding.loan_id
        where loan.owner_id = p_target_user_id
      ) target_path
      order by target_path.object_path
    loop
      perform pg_catalog.pg_advisory_xact_lock(
        private.client_purge_storage_lock_key(
          'external-execution-evidence', evidence_path
        )
      );
    end loop;

    if exists (
      with target_path as (
        select execution.evidence_object_path as object_path
        from public.external_transfer_executions execution
        join public.transfer_intents transfer on transfer.id = execution.transfer_id
        where transfer.owner_id = p_target_user_id
        union
        select funding.evidence_object_path
        from public.external_loan_fundings funding
        join public.loan_applications loan on loan.id = funding.loan_id
        where loan.owner_id = p_target_user_id
      )
      select 1
      from target_path
      where exists (
        select 1
        from public.external_transfer_executions execution
        join public.transfer_intents transfer on transfer.id = execution.transfer_id
        where transfer.owner_id <> p_target_user_id
          and execution.evidence_object_path = target_path.object_path
      ) or exists (
        select 1
        from public.external_loan_fundings funding
        join public.loan_applications loan on loan.id = funding.loan_id
        where loan.owner_id <> p_target_user_id
          and funding.evidence_object_path = target_path.object_path
      )
    ) then
      raise exception 'PURGE_PREVIEW_STALE' using errcode = '55000';
    end if;

    select coalesce(array_agg(email order by email), array[]::text[])
    into support_emails
    from (
      select candidate.email
      from (
        select identity.normalized_email as email
        from public.support_user_identities identity
        where identity.user_id = p_target_user_id
        union
        select lower(btrim(current_target_email))
      ) candidate
      where not exists (
        select 1
        from public.support_user_identities active_identity
        where active_identity.normalized_email = candidate.email
          and active_identity.user_id <> p_target_user_id
      )
    ) unambiguous_emails;
    perform private.refresh_client_purge_entity_manifest(
      p_challenge_id, p_target_user_id
    );
    current_scope_digest := private.client_purge_scope_digest(
      p_challenge_id, p_target_user_id, to_jsonb(support_emails)
    );
    if operation.scope_digest is null
       or operation.scope_digest is distinct from current_scope_digest then
      raise exception 'PURGE_PREVIEW_STALE' using errcode = '55000';
    end if;
    update public.profiles
    set access_status = 'frozen',
        access_status_reason = 'Suppression administrative sécurisée en cours.'
    where user_id = p_target_user_id;
    get diagnostics frozen_profile_count = row_count;
    if frozen_profile_count > 1 then
      raise exception 'PURGE_PROFILE_CARDINALITY_INVALID' using errcode = '21000';
    end if;
    update private.client_purge_operations
    set status = 'running', stage = 'storage', consumed_at = statement_timestamp(),
        support_email_manifest = to_jsonb(support_emails),
        scope_digest = current_scope_digest,
        retry_after = statement_timestamp() + interval '5 minutes',
        last_error_code = null, updated_at = statement_timestamp()
    where challenge_id = p_challenge_id;

    -- Discard every preview-era relational path while the target's exclusive
    -- owner lock is held. The bounded Storage phase will repopulate only
    -- current references after the account has been frozen.
    perform private.initialize_client_purge_storage_cycle(
      p_challenge_id, 'storage', p_target_user_id
    );

    return jsonb_build_object(
      'status', 'running',
      'stage', 'storage',
      'sweepNotBefore', null
    );
  end if;

  if operation.status = 'waiting_sweep' then
    if operation.sweep_not_before > statement_timestamp() then
      return jsonb_build_object(
        'status', 'waiting_sweep',
        'stage', 'waiting_sweep',
        'sweepNotBefore', operation.sweep_not_before
      );
    end if;
    update private.client_purge_operations
    set status = 'running', stage = 'storage_sweep',
        retry_after = statement_timestamp() + interval '5 minutes',
        last_error_code = null, updated_at = statement_timestamp()
    where challenge_id = p_challenge_id;
    return jsonb_build_object(
      'status', 'running',
      'stage', 'storage_sweep',
      'sweepNotBefore', operation.sweep_not_before
    );
  end if;

  -- The challenge is one-use, but the exact idempotent operation can resume.
  if operation.status = 'running'
     and operation.retry_after is not null
     and operation.retry_after > statement_timestamp() then
    raise exception 'PURGE_OPERATION_IN_PROGRESS' using errcode = '55000';
  end if;
  update private.client_purge_operations
  set status = 'running',
      retry_after = statement_timestamp() + interval '5 minutes',
      last_error_code = null,
      updated_at = statement_timestamp()
  where challenge_id = p_challenge_id;
  return jsonb_build_object(
    'status', 'running',
    'stage', operation.stage,
    'sweepNotBefore', operation.sweep_not_before
  );
end;
$$;


ALTER FUNCTION "public"."admin_begin_client_purge"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_challenge_id" "uuid", "p_challenge_digest" "text", "p_target_email_digest" "text", "p_idempotency_key" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_claim_client_purge_storage_work"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_challenge_id" "uuid", "p_limit" integer DEFAULT 1000) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  operation private.client_purge_operations;
  current_cycle_stage text;
  page_count integer;
  unsafe_count integer;
  last_bucket text;
  last_path text;
  queue_row private.client_purge_storage_scan_queue;
  token uuid;
  claimed_items jsonb;
  claimed_count integer;
  prefix_bucket text;
begin
  perform private.require_active_purge_admin(p_actor_id);
  if p_limit is null or p_limit not between 1 and 1000 then
    raise exception 'INVALID_STORAGE_WORK_LIMIT' using errcode = '22023';
  end if;

  select * into operation from private.client_purge_operations
  where challenge_id = p_challenge_id
    and actor_id = p_actor_id
    and target_user_id = p_target_user_id
  for update;
  if not found then
    raise exception 'PURGE_OPERATION_NOT_FOUND' using errcode = 'P0002';
  end if;
  if operation.consumed_at is null then
    if operation.status <> 'preview' or operation.expires_at <= statement_timestamp() then
      raise exception 'PURGE_PREVIEW_EXPIRED' using errcode = '22023';
    end if;
    current_cycle_stage := 'preview';
  else
    if operation.stage not in ('storage', 'storage_sweep', 'verify') then
      raise exception 'PURGE_STORAGE_STAGE_INVALID' using errcode = '55000';
    end if;
    current_cycle_stage := operation.stage;
  end if;

  if operation.storage_cycle_stage is distinct from current_cycle_stage
     or operation.storage_phase = 'idle' then
    perform private.initialize_client_purge_storage_cycle(
      p_challenge_id, current_cycle_stage, p_target_user_id
    );
    select * into operation from private.client_purge_operations
    where challenge_id = p_challenge_id;
  end if;

  if operation.storage_phase = 'references' then
    with page as materialized (
      select reference.bucket, reference.object_path,
        reference.ownership_scope, reference.ownership_valid
      from private.client_purge_storage_references(p_target_user_id) reference
      where operation.reference_after_bucket is null
         or (reference.bucket, reference.object_path) >
            (operation.reference_after_bucket, operation.reference_after_object_path)
      order by reference.bucket, reference.object_path
      limit p_limit
    ), inserted as (
      insert into private.client_purge_storage_manifest (
        challenge_id, bucket, object_path, ownership_scope, processing_status
      )
      select p_challenge_id, page.bucket, page.object_path,
        page.ownership_scope, 'pending'
      from page where page.ownership_valid is true
      on conflict (challenge_id, bucket, object_path) do update
      set ownership_scope = excluded.ownership_scope
      returning 1
    )
    select count(*),
      count(*) filter (where page.ownership_valid is not true),
      (array_agg(page.bucket order by page.bucket desc, page.object_path desc))[1],
      (array_agg(page.object_path order by page.bucket desc, page.object_path desc))[1]
    into page_count, unsafe_count, last_bucket, last_path
    from page;

    update private.client_purge_operations
    set reference_after_bucket = case when page_count = 0 then reference_after_bucket else last_bucket end,
        reference_after_object_path = case when page_count = 0 then reference_after_object_path else last_path end,
        ignored_unsafe_storage_references = case
          when current_cycle_stage = 'preview'
            then ignored_unsafe_storage_references + unsafe_count
          else ignored_unsafe_storage_references
        end,
        storage_phase = case when page_count < p_limit then 'scan' else 'references' end,
        expires_at = case when current_cycle_stage = 'preview'
          then pg_catalog.clock_timestamp() + interval '5 minutes' else expires_at end,
        retry_after = case when consumed_at is null then retry_after
          else statement_timestamp() end,
        updated_at = statement_timestamp()
    where challenge_id = p_challenge_id;
    if page_count < p_limit then
      perform private.seed_client_purge_storage_roots(
        p_challenge_id, current_cycle_stage, p_target_user_id
      );
    end if;
    return jsonb_build_object(
      'kind', 'database', 'phase', 'references', 'processed', page_count,
      'unsafeIgnored', unsafe_count,
      'complete', false
    );
  end if;

  if operation.storage_phase = 'scan' then
    update private.client_purge_storage_scan_queue
    set status = 'pending', claim_token = null, claimed_at = null,
        updated_at = statement_timestamp()
    where challenge_id = p_challenge_id and cycle_stage = current_cycle_stage
      and status = 'claimed'
      and claimed_at <= statement_timestamp() - interval '5 minutes';

    select * into queue_row
    from private.client_purge_storage_scan_queue queue
    where queue.challenge_id = p_challenge_id
      and queue.cycle_stage = current_cycle_stage
      and queue.status = 'pending'
    order by queue.id
    limit 1
    for update skip locked;
    if not found then
      if exists (
        select 1 from private.client_purge_storage_scan_queue queue
        where queue.challenge_id = p_challenge_id
          and queue.cycle_stage = current_cycle_stage and queue.status = 'claimed'
      ) then
        return jsonb_build_object('kind', 'wait', 'phase', 'scan', 'complete', false);
      end if;
      update private.client_purge_operations
      set storage_phase = case when current_cycle_stage = 'preview' then 'complete' else 'delete' end,
          retry_after = case when consumed_at is null then retry_after
            else statement_timestamp() end,
          updated_at = statement_timestamp()
      where challenge_id = p_challenge_id;
      return jsonb_build_object(
        'kind', 'database', 'phase', 'scan', 'processed', 0,
        'complete', current_cycle_stage = 'preview'
      );
    end if;
    token := gen_random_uuid();
    update private.client_purge_storage_scan_queue
    set status = 'claimed', claim_token = token, claimed_at = statement_timestamp(),
        updated_at = statement_timestamp()
    where id = queue_row.id;
    return jsonb_build_object(
      'kind', 'scan', 'claimToken', token, 'scanId', queue_row.id,
      'bucket', queue_row.bucket, 'prefix', queue_row.prefix,
      'offset', queue_row.next_offset, 'limit', p_limit, 'complete', false
    );
  end if;

  if operation.storage_phase = 'delete' then
    -- A relational evidence key is quarantined for the lifetime of the
    -- operation. Even a privileged/legacy write must never make the Storage
    -- worker delete an object now referenced by another client's parent.
    if exists (
      select 1
      from private.client_purge_storage_manifest manifest
      join public.external_transfer_executions execution
        on execution.evidence_object_path = manifest.object_path
      join public.transfer_intents transfer on transfer.id = execution.transfer_id
      where manifest.challenge_id = p_challenge_id
        and manifest.bucket = 'external-execution-evidence'
        and manifest.ownership_scope = 'relational'
        and transfer.owner_id <> p_target_user_id
    ) or exists (
      select 1
      from private.client_purge_storage_manifest manifest
      join public.external_loan_fundings funding
        on funding.evidence_object_path = manifest.object_path
      join public.loan_applications loan on loan.id = funding.loan_id
      where manifest.challenge_id = p_challenge_id
        and manifest.bucket = 'external-execution-evidence'
        and manifest.ownership_scope = 'relational'
        and loan.owner_id <> p_target_user_id
    ) then
      raise exception 'PURGE_EVIDENCE_PATH_OWNERSHIP_CONFLICT'
        using errcode = '55000';
    end if;

    update private.client_purge_storage_manifest
    set processing_status = 'pending', claim_token = null, claimed_at = null
    where challenge_id = p_challenge_id and processing_status = 'delete_claimed'
      and claimed_at <= statement_timestamp() - interval '5 minutes';
    token := gen_random_uuid();
    with selected as (
      select manifest.bucket, manifest.object_path
      from private.client_purge_storage_manifest manifest
      where manifest.challenge_id = p_challenge_id
        and manifest.processing_status = 'pending'
      order by manifest.bucket, manifest.object_path
      limit p_limit
      for update skip locked
    ), claimed as (
      update private.client_purge_storage_manifest manifest
      set processing_status = 'delete_claimed', claim_token = token,
          claimed_at = statement_timestamp()
      from selected
      where manifest.challenge_id = p_challenge_id
        and manifest.bucket = selected.bucket
        and manifest.object_path = selected.object_path
      returning manifest.bucket, manifest.object_path, manifest.ownership_scope
    )
    select coalesce(jsonb_agg(jsonb_build_object(
      'bucket', claimed.bucket, 'objectPath', claimed.object_path,
      'ownershipScope', claimed.ownership_scope
    ) order by claimed.bucket, claimed.object_path), '[]'::jsonb), count(*)
    into claimed_items, claimed_count from claimed;
    if claimed_count = 0 then
      if exists (select 1 from private.client_purge_storage_manifest manifest
        where manifest.challenge_id = p_challenge_id
          and manifest.processing_status = 'delete_claimed') then
        return jsonb_build_object('kind', 'wait', 'phase', 'delete', 'complete', false);
      end if;
      -- Target-prefix entries are verified in one bounded prefix lookup per
      -- bucket. Exact per-object lookups are reserved for relational external
      -- evidence which lives outside the client namespace.
      update private.client_purge_storage_manifest
      set processing_status = 'verified', verified_at = pg_catalog.clock_timestamp()
      where challenge_id = p_challenge_id
        and ownership_scope = 'target_prefix'
        and processing_status = 'deleted';
      update private.client_purge_operations set storage_phase = 'verify_manifest',
        retry_after = statement_timestamp(),
        updated_at = statement_timestamp() where challenge_id = p_challenge_id;
      return jsonb_build_object('kind', 'database', 'phase', 'delete',
        'processed', 0, 'complete', false);
    end if;
    return jsonb_build_object('kind', 'delete', 'claimToken', token,
      'items', claimed_items, 'complete', false);
  end if;

  if operation.storage_phase = 'verify_manifest' then
    update private.client_purge_storage_manifest
    set processing_status = 'deleted', claim_token = null, claimed_at = null
    where challenge_id = p_challenge_id and processing_status = 'verify_claimed'
      and claimed_at <= statement_timestamp() - interval '5 minutes';
    token := gen_random_uuid();
    with selected as (
      select manifest.bucket, manifest.object_path
      from private.client_purge_storage_manifest manifest
      where manifest.challenge_id = p_challenge_id
        and manifest.processing_status = 'deleted'
        and manifest.ownership_scope = 'relational'
      order by manifest.bucket, manifest.object_path
      limit least(p_limit, 100)
      for update skip locked
    ), claimed as (
      update private.client_purge_storage_manifest manifest
      set processing_status = 'verify_claimed', claim_token = token,
          claimed_at = statement_timestamp()
      from selected
      where manifest.challenge_id = p_challenge_id
        and manifest.bucket = selected.bucket
        and manifest.object_path = selected.object_path
      returning manifest.bucket, manifest.object_path, manifest.ownership_scope
    )
    select coalesce(jsonb_agg(jsonb_build_object(
      'bucket', claimed.bucket, 'objectPath', claimed.object_path,
      'ownershipScope', claimed.ownership_scope
    ) order by claimed.bucket, claimed.object_path), '[]'::jsonb), count(*)
    into claimed_items, claimed_count from claimed;
    if claimed_count = 0 then
      if exists (select 1 from private.client_purge_storage_manifest manifest
        where manifest.challenge_id = p_challenge_id
          and manifest.processing_status = 'verify_claimed') then
        return jsonb_build_object('kind', 'wait', 'phase', 'verify_manifest', 'complete', false);
      end if;
      update private.client_purge_operations set storage_phase = 'verify_prefix',
        verify_prefix_index = 0, retry_after = statement_timestamp(),
        updated_at = statement_timestamp()
      where challenge_id = p_challenge_id;
      return jsonb_build_object('kind', 'database', 'phase', 'verify_manifest',
        'processed', 0, 'complete', false);
    end if;
    return jsonb_build_object('kind', 'verify_manifest', 'claimToken', token,
      'items', claimed_items, 'complete', false);
  end if;

  if operation.storage_phase = 'verify_prefix' then
    if operation.prefix_claim_token is not null
       and operation.prefix_claimed_at > statement_timestamp() - interval '5 minutes' then
      return jsonb_build_object('kind', 'wait', 'phase', 'verify_prefix', 'complete', false);
    end if;
    if operation.verify_prefix_index >= 4 then
      update private.client_purge_operations set storage_phase = 'complete',
        prefix_claim_token = null, prefix_claimed_at = null,
        retry_after = statement_timestamp(),
        updated_at = statement_timestamp() where challenge_id = p_challenge_id;
      return jsonb_build_object('kind', 'database', 'phase', 'verify_prefix',
        'processed', 0, 'complete', true);
    end if;
    prefix_bucket := (array[
      'upload-staging', 'kyc-evidence', 'loan-evidence', 'official-documents'
    ])[operation.verify_prefix_index + 1];
    token := gen_random_uuid();
    update private.client_purge_operations
    set prefix_claim_token = token, prefix_claimed_at = statement_timestamp(),
        updated_at = statement_timestamp()
    where challenge_id = p_challenge_id;
    return jsonb_build_object('kind', 'verify_prefix', 'claimToken', token,
      'bucket', prefix_bucket, 'prefix', p_target_user_id::text,
      'complete', false);
  end if;

  if operation.storage_phase = 'complete' then
    return jsonb_build_object('kind', 'complete', 'phase', 'complete', 'complete', true);
  end if;
  raise exception 'PURGE_STORAGE_PHASE_INVALID' using errcode = '55000';
end;
$$;


ALTER FUNCTION "public"."admin_claim_client_purge_storage_work"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_challenge_id" "uuid", "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_finalize_client_purge"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_challenge_id" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  operation private.client_purge_operations;
  residual record;
  residuals jsonb;
begin
  perform private.require_active_purge_admin(p_actor_id);
  perform pg_catalog.pg_advisory_xact_lock(
    private.client_purge_lock_key(p_target_user_id)
  );
  if exists (select 1 from public.staff_members where user_id = p_target_user_id) then
    raise exception 'STAFF_PURGE_FORBIDDEN' using errcode = '42501';
  end if;
  select * into operation
  from private.client_purge_operations
    where challenge_id = p_challenge_id
      and actor_id = p_actor_id
      and target_user_id = p_target_user_id
      and stage = 'verify'
      and consumed_at is not null
  for update;
  if not found then
    raise exception 'PURGE_FINALIZE_STAGE_INVALID' using errcode = '55000';
  end if;
  if operation.storage_cycle_stage <> 'verify'
     or operation.storage_phase <> 'complete' then
    raise exception 'PURGE_STORAGE_VERIFICATION_INCOMPLETE' using errcode = '55000';
  end if;
  perform pg_catalog.set_config('monalyz.client_purge_maintenance', 'on', true);

  -- Auth deletion retires (but intentionally does not erase) support identity
  -- history. Remove any identity recreated during the signed-URL grace period,
  -- and every transcript linked to the current or historical e-mail manifest.
  with candidate_emails as (
    select jsonb_array_elements_text(operation.support_email_manifest) as email
    union
    select identity.normalized_email
    from public.support_user_identities identity
    where identity.user_id = p_target_user_id
  ), support_emails as (
    select candidate.email
    from candidate_emails candidate
    where not exists (
      select 1
      from public.support_user_identities active_identity
      where active_identity.normalized_email = candidate.email
        and active_identity.user_id <> p_target_user_id
    )
  )
  delete from public.support_transcripts transcript
  where transcript.user_id = p_target_user_id
     or (
       transcript.user_id is null
       and (
         transcript.visitor_email_normalized in (select email from support_emails)
         or transcript.notification_email in (select email from support_emails)
       )
       and not exists (
         select 1 from public.support_user_identities active_identity
         where active_identity.user_id <> p_target_user_id
           and active_identity.normalized_email in (
             transcript.visitor_email_normalized,
             transcript.notification_email
           )
       )
     );
  delete from public.support_user_identities where user_id = p_target_user_id;
  -- Foreign parents are never deleted merely because they reused a quarantined
  -- path. Such a row is reported by residual verification and must be resolved
  -- explicitly before the purge can complete.

  delete from public.audit_events event
  where private.audit_event_matches_client(
    event.actor_id, event.entity_type, event.entity_id, event.metadata,
    p_target_user_id, p_challenge_id
  );
  delete from public.kyc_events event
  where event.actor_id = p_target_user_id or exists (
    select 1 from private.client_purge_entity_manifest entity
    where entity.challenge_id = p_challenge_id
      and entity.entity_type = 'kyc_event'
      and entity.entity_id = event.id::text
  );
  delete from public.loan_events event
  where event.actor_id = p_target_user_id or exists (
    select 1 from private.client_purge_entity_manifest entity
    where entity.challenge_id = p_challenge_id
      and entity.entity_type = 'loan_event'
      and entity.entity_id = event.id::text
  );
  delete from public.transfer_events event
  where event.actor_id = p_target_user_id or exists (
    select 1 from private.client_purge_entity_manifest entity
    where entity.challenge_id = p_challenge_id
      and entity.entity_type = 'transfer_event'
      and entity.entity_id = event.id::text
  );
  delete from public.loan_review_checks review
  where exists (
    select 1 from private.client_purge_entity_manifest entity
    where entity.challenge_id = p_challenge_id
      and entity.entity_type = 'loan_review_check'
      and entity.entity_id = review.id::text
  );
  delete from public.transfer_review_checks review
  where exists (
    select 1 from private.client_purge_entity_manifest entity
    where entity.challenge_id = p_challenge_id
      and entity.entity_type = 'transfer_review_check'
      and entity.entity_id = review.id::text
  );

  residuals := private.client_purge_residuals(p_challenge_id, p_target_user_id);
  for residual in select key, value from jsonb_each_text(residuals)
  loop
    if residual.value::bigint <> 0 then
      raise exception 'PURGE_VERIFICATION_FAILED:%=%', residual.key, residual.value
        using errcode = '55000', detail = residuals::text;
    end if;
  end loop;

  delete from private.client_purge_operations
  where challenge_id = p_challenge_id
    and actor_id = p_actor_id
    and target_user_id = p_target_user_id
    and consumed_at is not null;
  return found;
end;
$$;


ALTER FUNCTION "public"."admin_finalize_client_purge"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_challenge_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_get_client_purge_preview"("p_actor_id" "uuid", "p_target_user_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  operation private.client_purge_operations;
begin
  perform private.require_active_purge_admin(p_actor_id);
  select * into operation from private.client_purge_operations
  where target_user_id = p_target_user_id and status = 'preview'
  for update;
  if not found or operation.actor_id is distinct from p_actor_id then
    raise exception 'PURGE_PREVIEW_NOT_FOUND' using errcode = 'P0002';
  end if;
  if operation.expires_at <= statement_timestamp() then
    delete from private.client_purge_operations
    where challenge_id = operation.challenge_id and status = 'preview';
    return jsonb_build_object('invalidated', true, 'reason', 'expired');
  end if;
  if not exists (
    select 1 from auth.users users
    where users.id = p_target_user_id
      and users.email is not null
      and users.email = operation.target_email
  ) then
    delete from private.client_purge_operations
    where challenge_id = operation.challenge_id and status = 'preview';
    return jsonb_build_object('invalidated', true, 'reason', 'email_changed');
  end if;
  return jsonb_build_object(
    'idempotencyKey', operation.idempotency_key,
    'targetEmail', operation.target_email
  );
end;
$$;


ALTER FUNCTION "public"."admin_get_client_purge_preview"("p_actor_id" "uuid", "p_target_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_get_client_purge_status"("p_actor_id" "uuid", "p_target_user_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  operation private.client_purge_operations;
begin
  perform private.require_active_purge_admin(p_actor_id);
  select * into operation
  from private.client_purge_operations
  where target_user_id = p_target_user_id;
  if not found then
    return null;
  end if;
  return jsonb_build_object(
    'status', operation.status,
    'stage', operation.stage,
    'storagePhase', operation.storage_phase,
    'targetEmail', operation.target_email,
    'authDeleted', not exists (
      select 1 from auth.users users where users.id = p_target_user_id
    ),
    'ignoredUnsafeStorageReferences', operation.ignored_unsafe_storage_references,
    'sweepNotBefore', operation.sweep_not_before,
    'expiresAt', case when operation.status = 'preview' then operation.expires_at else null end,
    'canResume', operation.status = 'failed'
      or (operation.status = 'running' and operation.retry_after <= statement_timestamp())
      or (operation.status = 'waiting_sweep' and operation.sweep_not_before <= statement_timestamp())
  );
end;
$$;


ALTER FUNCTION "public"."admin_get_client_purge_status"("p_actor_id" "uuid", "p_target_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_list_client_purge_candidates"("p_actor_id" "uuid", "p_search" "text" DEFAULT ''::"text", "p_limit" integer DEFAULT 25, "p_offset" integer DEFAULT 0) RETURNS TABLE("user_id" "uuid", "email" "text", "display_name" "text", "access_status" "text", "created_at" timestamp with time zone, "kyc_status" "text", "account_count" bigint, "loan_count" bigint, "transfer_count" bigint, "document_count" bigint, "purge_status" "text", "purge_stage" "text", "purge_sweep_not_before" timestamp with time zone, "total_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  normalized_search text := btrim(coalesce(p_search, ''));
begin
  perform private.require_active_purge_admin(p_actor_id);
  if p_limit is null or p_offset is null
     or p_limit not between 1 and 50 or p_offset not between 0 and 100000
     or char_length(normalized_search) > 100 then
    raise exception 'INVALID_CLIENT_PAGE' using errcode = '22023';
  end if;

  return query
  with sources as (
    select users.id, users.email,
      users.raw_user_meta_data, users.created_at, false as auth_deleted
    from auth.users users
    where users.email is not null
      and not exists (
        select 1 from public.staff_members staff where staff.user_id = users.id
      )
    union all
    select operation.target_user_id, operation.target_email,
      '{}'::jsonb, operation.created_at, true
    from private.client_purge_operations operation
    where operation.consumed_at is not null
      and not exists (select 1 from auth.users users
        where users.id = operation.target_user_id)
      and not exists (select 1 from public.staff_members staff
        where staff.user_id = operation.target_user_id)
  )
  select
    source.id,
    source.email::text,
    coalesce(
      nullif(btrim(profile.display_name), ''),
      nullif(btrim(source.raw_user_meta_data ->> 'full_name'), ''),
      split_part(source.email, '@', 1)
    )::text,
    case when source.auth_deleted then 'auth_deleted'
      else coalesce(profile.access_status, 'missing') end::text,
    source.created_at,
    latest_kyc.status::text,
    (select count(*) from public.financial_positions fp where fp.owner_id = source.id),
    (select count(*) from public.loan_applications loan where loan.owner_id = source.id),
    (select count(*) from public.transfer_intents transfer where transfer.owner_id = source.id),
    (select count(*) from public.official_documents document where document.owner_id = source.id),
    purge.status::text,
    purge.stage::text,
    purge.sweep_not_before,
    count(*) over ()
  from sources source
  left join public.profiles profile on profile.user_id = source.id
  left join lateral (
    select application.status from public.kyc_applications application
    where application.owner_id = source.id
    order by application.submitted_at desc limit 1
  ) latest_kyc on true
  left join private.client_purge_operations purge
    on purge.target_user_id = source.id
  where normalized_search = ''
    or coalesce(profile.display_name, '') ilike '%' || normalized_search || '%'
    or source.email ilike '%' || normalized_search || '%'
  order by source.created_at desc, source.id
  limit p_limit offset p_offset;
end;
$$;


ALTER FUNCTION "public"."admin_list_client_purge_candidates"("p_actor_id" "uuid", "p_search" "text", "p_limit" integer, "p_offset" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_list_pending_client_purges"("p_limit" integer DEFAULT 20) RETURNS TABLE("challenge_id" "uuid", "actor_id" "uuid", "target_user_id" "uuid", "challenge_digest" "text", "target_email_digest" "text", "idempotency_key" "uuid", "stage" "text")
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if p_limit is null or p_limit not between 1 and 50 then
    raise exception 'INVALID_SWEEP_LIMIT' using errcode = '22023';
  end if;
  delete from private.client_purge_operations
  where status = 'preview' and expires_at <= statement_timestamp();

  return query
  with candidates as (
    select operation.challenge_id, resume_admin.user_id as actor_id
    from private.client_purge_operations operation
    cross join lateral (
      select staff.user_id from public.staff_members staff
      join auth.users users on users.id = staff.user_id
      where staff.role = 'admin' and staff.active
      order by (staff.user_id = operation.actor_id) desc, staff.user_id limit 1
    ) resume_admin
    where operation.consumed_at is not null
      and not exists (select 1 from public.staff_members target_staff
        where target_staff.user_id = operation.target_user_id)
      and (
        (operation.status = 'waiting_sweep'
          and operation.sweep_not_before <= statement_timestamp())
        or (operation.status in ('running', 'failed')
          and operation.retry_after <= statement_timestamp())
      )
      and (operation.stage in ('auth', 'verify') or not exists (
        select 1 from public.profiles profile
        where profile.user_id = operation.target_user_id
          and profile.access_status <> 'frozen'
      ))
    order by operation.updated_at
    limit p_limit for update skip locked
  )
  update private.client_purge_operations operation
  set actor_id = candidates.actor_id,
      status = 'running',
      stage = case when operation.stage = 'waiting_sweep'
        then 'storage_sweep' else operation.stage end,
      retry_after = statement_timestamp() + interval '5 minutes',
      updated_at = statement_timestamp()
  from candidates where operation.challenge_id = candidates.challenge_id
  returning operation.challenge_id, operation.actor_id,
    operation.target_user_id, operation.challenge_digest,
    operation.target_email_digest, operation.idempotency_key, operation.stage;
end;
$$;


ALTER FUNCTION "public"."admin_list_pending_client_purges"("p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_mark_client_purge_stage"("p_actor_id" "uuid", "p_challenge_id" "uuid", "p_stage" "text", "p_error_code" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  operation private.client_purge_operations;
  target_auth_exists boolean;
begin
  perform private.require_active_purge_admin(p_actor_id);
  if p_stage is null
     or p_stage not in (
       'storage', 'database', 'auth', 'waiting_sweep', 'storage_sweep', 'verify'
     )
     or (p_error_code is not null and char_length(p_error_code) > 100)
     or (p_stage = 'waiting_sweep' and p_error_code is not null) then
    raise exception 'INVALID_PURGE_STAGE' using errcode = '22023';
  end if;

  select * into operation
  from private.client_purge_operations
  where challenge_id = p_challenge_id
    and actor_id = p_actor_id
    and consumed_at is not null
  for update;
  if not found then
    raise exception 'PURGE_OPERATION_NOT_FOUND' using errcode = 'P0002';
  end if;

  target_auth_exists := exists (
    select 1 from auth.users users where users.id = operation.target_user_id
  );
  if p_stage <> operation.stage and not (
    (
      operation.stage = 'storage'
      and p_stage = 'database'
      and operation.storage_cycle_stage = 'storage'
      and operation.storage_phase = 'complete'
    )
    or (
      operation.stage = 'auth'
      and p_stage = 'waiting_sweep'
      and operation.storage_cycle_stage = 'storage'
      and operation.storage_phase = 'complete'
      and operation.sweep_not_before is not null
      and not target_auth_exists
    )
    or (
      operation.stage = 'storage_sweep'
      and p_stage = 'verify'
      and operation.storage_cycle_stage = 'storage_sweep'
      and operation.storage_phase = 'complete'
      and not target_auth_exists
    )
    -- Compatibility for an operation begun before this migration: its Auth
    -- deletion still occurs after the delayed sweep.
    or (
      operation.stage = 'storage_sweep'
      and p_stage = 'auth'
      and operation.storage_cycle_stage = 'storage_sweep'
      and operation.storage_phase = 'complete'
      and operation.sweep_not_before is not null
      and operation.sweep_not_before <= statement_timestamp()
      and target_auth_exists
    )
    or (
      operation.stage = 'auth'
      and p_stage = 'verify'
      and operation.storage_cycle_stage = 'storage_sweep'
      and operation.storage_phase = 'complete'
      and not target_auth_exists
    )
  ) then
    raise exception 'INVALID_PURGE_STAGE_TRANSITION' using errcode = '55000';
  end if;

  if p_stage = 'waiting_sweep' then
    if target_auth_exists
       or operation.sweep_not_before is null
       or operation.storage_cycle_stage <> 'storage'
       or operation.storage_phase <> 'complete' then
      raise exception 'PURGE_AUTH_DELETE_INCOMPLETE' using errcode = '55000';
    end if;
    update private.client_purge_operations
    set stage = 'waiting_sweep',
        status = 'waiting_sweep',
        last_error_code = null,
        retry_after = operation.sweep_not_before,
        updated_at = statement_timestamp()
    where challenge_id = p_challenge_id;
    return;
  end if;

  update private.client_purge_operations
  set stage = p_stage,
      status = case when p_error_code is null then 'running' else 'failed' end,
      last_error_code = p_error_code,
      retry_after = statement_timestamp() + case
        when p_error_code is null then interval '0 seconds'
        else interval '15 minutes'
      end,
      updated_at = statement_timestamp()
  where challenge_id = p_challenge_id;
end;
$$;


ALTER FUNCTION "public"."admin_mark_client_purge_stage"("p_actor_id" "uuid", "p_challenge_id" "uuid", "p_stage" "text", "p_error_code" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_prepare_client_purge"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_challenge_digest" "text", "p_target_email_digest" "text", "p_target_email" "text", "p_idempotency_key" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  v_challenge_id uuid := gen_random_uuid();
  expiration timestamptz := statement_timestamp() + interval '5 minutes';
  existing_preview private.client_purge_operations;
  impact jsonb;
  storage_references bigint;
  unsafe_storage_references bigint;
  canonical_target_email text;
  support_emails text[];
  current_scope_digest text;
  previous_scope_digest text;
begin
  perform private.require_active_purge_admin(p_actor_id);

  if p_target_user_id is null or p_target_user_id = p_actor_id then
    raise exception 'SELF_PURGE_FORBIDDEN' using errcode = '42501';
  end if;
  if exists (select 1 from public.staff_members where user_id = p_target_user_id) then
    raise exception 'STAFF_PURGE_FORBIDDEN' using errcode = '42501';
  end if;
  select users.email into canonical_target_email
  from auth.users users where users.id = p_target_user_id;
  if not found or canonical_target_email is null then
    raise exception 'CLIENT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_challenge_digest is null
     or p_target_email_digest is null
     or p_target_email is null
     or p_challenge_digest !~ '^[0-9a-f]{64}$'
     or p_target_email_digest !~ '^[0-9a-f]{64}$'
     or p_target_email is distinct from canonical_target_email
     or encode(
       extensions.digest(convert_to(p_target_email, 'UTF8'), 'sha256'), 'hex'
     ) is distinct from p_target_email_digest
     or p_idempotency_key is null then
    raise exception 'INVALID_PURGE_CHALLENGE' using errcode = '22023';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_target_user_id::text, 847231)
  );

  select * into existing_preview
  from private.client_purge_operations
  where target_user_id = p_target_user_id
  for update;

  if found and existing_preview.consumed_at is not null then
    raise exception 'PURGE_ALREADY_STARTED' using errcode = '55000';
  end if;

  if found and existing_preview.status = 'preview'
     and existing_preview.expires_at > statement_timestamp() then
    if existing_preview.actor_id = p_actor_id
       and existing_preview.idempotency_key = p_idempotency_key
       and existing_preview.challenge_digest = p_challenge_digest
       and existing_preview.target_email_digest = p_target_email_digest
       and existing_preview.target_email = p_target_email then
      -- Exact retries and lost responses retain the same durable scan cursor.
      v_challenge_id := existing_preview.challenge_id;
      expiration := existing_preview.expires_at;
    else
      raise exception 'PURGE_PREVIEW_EXISTS' using errcode = '55000';
    end if;
  else
    -- Only an expired unconsumed preview may be atomically rotated.
    delete from private.client_purge_operations
    where target_user_id = p_target_user_id
      and status = 'preview'
      and expires_at <= statement_timestamp();

    insert into private.client_purge_operations (
      challenge_id,
      actor_id,
      target_user_id,
      challenge_digest,
      target_email_digest,
      target_email,
      idempotency_key,
      expires_at,
      storage_cycle_stage,
      storage_phase
    ) values (
      v_challenge_id,
      p_actor_id,
      p_target_user_id,
      p_challenge_digest,
      p_target_email_digest,
      p_target_email,
      p_idempotency_key,
      expiration,
      'preview',
      'references'
    );
  end if;

  perform private.refresh_client_purge_entity_manifest(
    v_challenge_id, p_target_user_id
  );

  select
    count(*) filter (where reference.ownership_valid is true),
    count(*) filter (where reference.ownership_valid is not true)
  into storage_references, unsafe_storage_references
  from private.client_purge_storage_references(p_target_user_id) reference;

  canonical_target_email := lower(btrim(canonical_target_email));
  select coalesce(array_agg(email order by email), array[]::text[])
  into support_emails
  from (
    select candidate.email
    from (
      select identity.normalized_email as email
      from public.support_user_identities identity
      where identity.user_id = p_target_user_id
      union
      select canonical_target_email where canonical_target_email is not null
    ) candidate
    where not exists (
      select 1
      from public.support_user_identities active_identity
      where active_identity.normalized_email = candidate.email
        and active_identity.user_id <> p_target_user_id
    )
  ) unambiguous_emails;

  current_scope_digest := private.client_purge_scope_digest(
    v_challenge_id, p_target_user_id, to_jsonb(support_emails)
  );
  select operation.scope_digest into previous_scope_digest
  from private.client_purge_operations operation
  where operation.challenge_id = v_challenge_id;

  if previous_scope_digest is not null
     and previous_scope_digest is distinct from current_scope_digest then
    -- A recovered preview must restart its bounded Storage inventory when the
    -- confirmed relational scope changed. This makes a fresh preview the only
    -- way to consume the challenge after PURGE_PREVIEW_STALE.
    delete from private.client_purge_storage_scan_queue queue
    where queue.challenge_id = v_challenge_id;
    delete from private.client_purge_storage_manifest manifest
    where manifest.challenge_id = v_challenge_id;
    update private.client_purge_operations operation
    set storage_cycle_stage = null,
        storage_phase = 'idle',
        reference_after_bucket = null,
        reference_after_object_path = null,
        reference_claim_token = null,
        reference_claimed_at = null,
        verify_prefix_index = 0,
        prefix_claim_token = null,
        prefix_claimed_at = null,
        ignored_unsafe_storage_references = 0
    where operation.challenge_id = v_challenge_id;
  end if;

  update private.client_purge_operations operation
  set support_email_manifest = to_jsonb(support_emails),
      scope_digest = current_scope_digest,
      updated_at = statement_timestamp()
  where operation.idempotency_key = p_idempotency_key
    and operation.actor_id = p_actor_id
    and operation.target_user_id = p_target_user_id
    and operation.consumed_at is null;

  impact := jsonb_build_object(
    'preservedAdmins', (
      select count(*)
      from public.staff_members staff
      join auth.users users on users.id = staff.user_id
      where staff.role = 'admin'
    ),
    'kycApplications', (select count(*) from public.kyc_applications where owner_id = p_target_user_id),
    'kycDrafts', (select count(*) from public.kyc_drafts where owner_id = p_target_user_id),
    'accounts', (select count(*) from public.financial_positions where owner_id = p_target_user_id),
    'ledgerEntries', (select count(*) from public.financial_ledger_entries where owner_id = p_target_user_id),
    'loans', (select count(*) from public.loan_applications where owner_id = p_target_user_id),
    'transfers', (select count(*) from public.transfer_intents where owner_id = p_target_user_id),
    'documents', (select count(*) from public.official_documents where owner_id = p_target_user_id),
    'notifications', (select count(*) from public.notifications where recipient_id = p_target_user_id),
    'emailOutbox', (
      select count(*) from public.transactional_email_outbox
      where recipient_id = p_target_user_id or claimed_by = p_target_user_id
    ),
    'pushSubscriptions', (select count(*) from public.push_subscriptions where user_id = p_target_user_id),
    'supportIdentities', (select count(*) from public.support_user_identities where user_id = p_target_user_id),
    'supportTranscripts', (
      select count(*) from public.support_transcripts transcript
      where transcript.user_id = p_target_user_id
         or (
           transcript.user_id is null
           and (
             transcript.visitor_email_normalized = any(support_emails)
             or transcript.notification_email = any(support_emails)
           )
           and not exists (
             select 1 from public.support_user_identities active_identity
             where active_identity.user_id <> p_target_user_id
               and active_identity.normalized_email in (
                 transcript.visitor_email_normalized,
                 transcript.notification_email
               )
           )
         )
    ),
    'auditEvents', (
      select count(*) from public.audit_events event
      where private.audit_event_matches_client(
        event.actor_id, event.entity_type, event.entity_id, event.metadata,
        p_target_user_id, v_challenge_id
      )
    ),
    'workflowEvents', (
      (select count(*) from public.kyc_events event
        where event.actor_id = p_target_user_id
          or event.kyc_id in (
            select id from public.kyc_applications where owner_id = p_target_user_id
          ))
      + (select count(*) from public.loan_events event
        where event.actor_id = p_target_user_id
          or event.loan_id in (
            select id from public.loan_applications where owner_id = p_target_user_id
          ))
      + (select count(*) from public.transfer_events event
        where event.actor_id = p_target_user_id
          or event.transfer_id in (
            select id from public.transfer_intents where owner_id = p_target_user_id
          ))
    ),
    'externalExecutions', (
      (select count(*) from public.external_transfer_executions execution
        join public.transfer_intents transfer on transfer.id = execution.transfer_id
        where transfer.owner_id = p_target_user_id)
      + (select count(*) from public.external_loan_fundings funding
        join public.loan_applications loan on loan.id = funding.loan_id
        where loan.owner_id = p_target_user_id)
    ),
    'profileRecords', (select count(*) from public.profiles where user_id = p_target_user_id),
    'authRecords', 1,
    'storageReferences', storage_references,
    'unsafeStorageReferences', unsafe_storage_references,
    'storageObjects', (
      select count(*) from private.client_purge_storage_manifest manifest
      where manifest.challenge_id = v_challenge_id
    )
  );

  return jsonb_build_object(
    'challengeId', v_challenge_id,
    'expiresAt', expiration,
    'inventoryComplete', (
      select operation.storage_phase = 'complete'
      from private.client_purge_operations operation
      where operation.challenge_id = v_challenge_id
    ),
    'impact', impact
  );
end;
$_$;


ALTER FUNCTION "public"."admin_prepare_client_purge"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_challenge_digest" "text", "p_target_email_digest" "text", "p_target_email" "text", "p_idempotency_key" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_purge_client_relational_data"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_challenge_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  operation private.client_purge_operations;
  target_email text;
  support_emails jsonb;
  purge_completed_at timestamptz;
  sweep_time timestamptz;
begin
  perform private.require_active_purge_admin(p_actor_id);
  if p_target_user_id = p_actor_id then
    raise exception 'SELF_PURGE_FORBIDDEN' using errcode = '42501';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    private.client_purge_lock_key(p_target_user_id)
  );
  if exists (select 1 from public.staff_members where user_id = p_target_user_id) then
    raise exception 'STAFF_PURGE_FORBIDDEN' using errcode = '42501';
  end if;

  select * into operation
  from private.client_purge_operations
  where challenge_id = p_challenge_id
    and actor_id = p_actor_id
    and target_user_id = p_target_user_id
    and consumed_at is not null
  for update;
  if not found
     or operation.stage <> 'database'
     or operation.storage_cycle_stage <> 'storage'
     or operation.storage_phase <> 'complete' then
    raise exception 'PURGE_OPERATION_NOT_FOUND' using errcode = 'P0002';
  end if;

  perform 1 from public.profiles where user_id = p_target_user_id for update;
  if exists (
    select 1 from public.profiles
    where user_id = p_target_user_id and access_status <> 'frozen'
  ) then
    raise exception 'PURGE_TARGET_NOT_FROZEN' using errcode = '55000';
  end if;
  select lower(btrim(users.email)) into target_email
  from auth.users users where users.id = p_target_user_id;
  target_email := coalesce(target_email, lower(btrim(operation.target_email)));
  perform private.refresh_client_purge_entity_manifest(
    p_challenge_id, p_target_user_id
  );

  select coalesce(jsonb_agg(email order by email), '[]'::jsonb)
  into support_emails
  from (
    select candidate.email
    from (
      select identity.normalized_email as email
      from public.support_user_identities identity
      where identity.user_id = p_target_user_id
      union
      select target_email where target_email is not null
    ) candidate
    where not exists (
      select 1
      from public.support_user_identities active_identity
      where active_identity.normalized_email = candidate.email
        and active_identity.user_id <> p_target_user_id
    )
  ) unambiguous_emails;

  -- Audit/transcript matching below must read the authoritative aliases from
  -- this locked execution snapshot, never the stale preview snapshot.
  update private.client_purge_operations
  set support_email_manifest = support_emails,
      updated_at = statement_timestamp()
  where challenge_id = p_challenge_id;

  operation.support_email_manifest := support_emails;

  perform pg_catalog.set_config('monalyz.allow_ledger_maintenance', 'on', true);
  perform pg_catalog.set_config('monalyz.allow_official_document_maintenance', 'on', true);
  perform pg_catalog.set_config('monalyz.client_purge_maintenance', 'on', true);

  delete from public.support_transcripts transcript
  where transcript.user_id = p_target_user_id
     or (
       transcript.user_id is null
       and (
         transcript.visitor_email_normalized in (
           select jsonb_array_elements_text(support_emails)
         )
         or transcript.notification_email in (
           select jsonb_array_elements_text(support_emails)
         )
       )
       and not exists (
         select 1 from public.support_user_identities active_identity
         where active_identity.user_id <> p_target_user_id
           and active_identity.normalized_email in (
             transcript.visitor_email_normalized,
             transcript.notification_email
           )
       )
     );
  delete from public.support_user_identities where user_id = p_target_user_id;
  delete from public.transactional_email_outbox where recipient_id = p_target_user_id;
  update public.transactional_email_outbox set claimed_by = null where claimed_by = p_target_user_id;
  delete from public.notifications where recipient_id = p_target_user_id;
  delete from public.push_subscriptions where user_id = p_target_user_id;

  delete from public.audit_events
  where private.audit_event_matches_client(
    actor_id, entity_type, entity_id, metadata, p_target_user_id, p_challenge_id
  );
  delete from public.kyc_events event
  where event.actor_id = p_target_user_id or exists (
    select 1 from private.client_purge_entity_manifest entity
    where entity.challenge_id = p_challenge_id
      and entity.entity_type = 'kyc_event'
      and entity.entity_id = event.id::text
  );
  delete from public.loan_events event
  where event.actor_id = p_target_user_id or exists (
    select 1 from private.client_purge_entity_manifest entity
    where entity.challenge_id = p_challenge_id
      and entity.entity_type = 'loan_event'
      and entity.entity_id = event.id::text
  );
  delete from public.transfer_events event
  where event.actor_id = p_target_user_id or exists (
    select 1 from private.client_purge_entity_manifest entity
    where entity.challenge_id = p_challenge_id
      and entity.entity_type = 'transfer_event'
      and entity.entity_id = event.id::text
  );
  delete from public.loan_review_checks review
  where exists (
    select 1 from private.client_purge_entity_manifest entity
    where entity.challenge_id = p_challenge_id
      and entity.entity_type = 'loan_review_check'
      and entity.entity_id = review.id::text
  );
  delete from public.transfer_review_checks review
  where exists (
    select 1 from private.client_purge_entity_manifest entity
    where entity.challenge_id = p_challenge_id
      and entity.entity_type = 'transfer_review_check'
      and entity.entity_id = review.id::text
  );

  delete from public.official_documents where owner_id = p_target_user_id;
  delete from public.financial_ledger_entries where owner_id = p_target_user_id;
  delete from public.external_transfer_executions
  where transfer_id in (
    select transfer.id from public.transfer_intents transfer
    where transfer.owner_id = p_target_user_id
  );
  delete from public.external_loan_fundings
  where loan_id in (
    select loan.id from public.loan_applications loan
    where loan.owner_id = p_target_user_id
  );
  delete from public.transfer_intents where owner_id = p_target_user_id;
  delete from public.loan_applications where owner_id = p_target_user_id;
  delete from public.financial_positions where owner_id = p_target_user_id;
  delete from public.kyc_drafts where owner_id = p_target_user_id;
  delete from public.kyc_applications where owner_id = p_target_user_id;

  purge_completed_at := pg_catalog.clock_timestamp();
  -- Signed upload URLs remain valid for at most two hours. Keep the existing
  -- five-minute margin, but release Auth now and sweep only the retired UUID
  -- after the grace period.
  sweep_time := purge_completed_at + interval '2 hours 5 minutes';
  update private.client_purge_operations
  set stage = 'auth',
      status = 'running',
      sweep_not_before = sweep_time,
      retry_after = statement_timestamp(),
      last_error_code = null,
      updated_at = purge_completed_at
  where challenge_id = p_challenge_id;

  return jsonb_build_object(
    'status', 'running',
    'stage', 'auth',
    'sweepNotBefore', sweep_time,
    'ignoredUnsafeStorageReferences', operation.ignored_unsafe_storage_references
  );
end;
$$;


ALTER FUNCTION "public"."admin_purge_client_relational_data"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_challenge_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_resume_client_purge"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_target_email_digest" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  operation private.client_purge_operations;
begin
  perform private.require_active_purge_admin(p_actor_id);
  if p_target_user_id = p_actor_id then
    raise exception 'SELF_PURGE_FORBIDDEN' using errcode = '42501';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(
    private.client_purge_lock_key(p_target_user_id)
  );
  if exists (select 1 from public.staff_members where user_id = p_target_user_id) then
    raise exception 'STAFF_PURGE_FORBIDDEN' using errcode = '42501';
  end if;

  select * into operation
  from private.client_purge_operations
  where target_user_id = p_target_user_id
  for update;
  if not found or operation.consumed_at is null
     or operation.target_email_digest is distinct from p_target_email_digest then
    raise exception 'PURGE_RESUME_INVALID' using errcode = '42501';
  end if;
  if operation.stage in ('storage', 'database', 'waiting_sweep', 'storage_sweep')
     and exists (
       select 1 from public.profiles
       where user_id = p_target_user_id and access_status <> 'frozen'
     ) then
    raise exception 'PURGE_TARGET_NOT_FROZEN' using errcode = '55000';
  end if;

  if operation.status = 'waiting_sweep'
     and operation.sweep_not_before > statement_timestamp() then
    return jsonb_build_object(
      'status', 'waiting_sweep',
      'stage', 'waiting_sweep',
      'challengeId', operation.challenge_id,
      'sweepNotBefore', operation.sweep_not_before
    );
  end if;
  if operation.status = 'running'
     and operation.retry_after > statement_timestamp() then
    raise exception 'PURGE_OPERATION_IN_PROGRESS' using errcode = '55000';
  end if;

  update private.client_purge_operations
  set actor_id = p_actor_id,
      status = 'running',
      stage = case
        when operation.stage = 'waiting_sweep' then 'storage_sweep'
        else operation.stage
      end,
      retry_after = statement_timestamp() + interval '5 minutes',
      last_error_code = null,
      updated_at = statement_timestamp()
  where challenge_id = operation.challenge_id;

  return jsonb_build_object(
    'status', 'running',
    'stage', case
      when operation.stage = 'waiting_sweep' then 'storage_sweep'
      else operation.stage
    end,
    'challengeId', operation.challenge_id,
    'sweepNotBefore', operation.sweep_not_before
  );
end;
$$;


ALTER FUNCTION "public"."admin_resume_client_purge"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_target_email_digest" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."kyc_applications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "owner_id" "uuid" NOT NULL,
    "idempotency_key" "uuid" NOT NULL,
    "first_name" "text" NOT NULL,
    "last_name" "text" NOT NULL,
    "date_of_birth" "date" NOT NULL,
    "place_of_birth" "text" NOT NULL,
    "nationality" "text" NOT NULL,
    "address" "jsonb" NOT NULL,
    "occupation" "text" NOT NULL,
    "income_range" "text" NOT NULL,
    "fatca" boolean NOT NULL,
    "pep" boolean NOT NULL,
    "document_object_paths" "jsonb" NOT NULL,
    "status" "text" DEFAULT 'submitted'::"text" NOT NULL,
    "submitted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reviewed_at" timestamp with time zone,
    "reviewed_by" "uuid",
    "review_note" "text",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "version" integer DEFAULT 1 NOT NULL,
    "document_type" "text",
    "document_number" "text",
    "issuing_country" "text",
    "document_expires_on" "date",
    "requested_items" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "correction_reason_code" "text",
    "correction_due_at" timestamp with time zone,
    CONSTRAINT "kyc_applications_address_check" CHECK (("jsonb_typeof"("address") = 'object'::"text")),
    CONSTRAINT "kyc_applications_correction_reason_code_check" CHECK ((("correction_reason_code" IS NULL) OR ("correction_reason_code" = ANY (ARRAY['unreadable_document'::"text", 'expired_document'::"text", 'inconsistent_information'::"text", 'missing_document'::"text", 'selfie_mismatch'::"text", 'address_not_verified'::"text", 'regulatory_information'::"text", 'other'::"text"])))),
    CONSTRAINT "kyc_applications_correction_state_check" CHECK ((("status" = ANY (ARRAY['needs_information'::"text", 'rejected'::"text"])) OR (("cardinality"("requested_items") = 0) AND ("correction_reason_code" IS NULL) AND ("correction_due_at" IS NULL)))),
    CONSTRAINT "kyc_applications_date_of_birth_check" CHECK (("date_of_birth" <= (CURRENT_DATE - '18 years'::interval))),
    CONSTRAINT "kyc_applications_document_number_check" CHECK ((("document_number" IS NULL) OR (("char_length"("document_number") >= 2) AND ("char_length"("document_number") <= 100)))),
    CONSTRAINT "kyc_applications_document_object_paths_check" CHECK (("jsonb_typeof"("document_object_paths") = 'object'::"text")),
    CONSTRAINT "kyc_applications_document_type_check" CHECK ((("document_type" IS NULL) OR ("document_type" = ANY (ARRAY['national_identity_card'::"text", 'passport'::"text", 'residence_permit'::"text"])))),
    CONSTRAINT "kyc_applications_first_name_check" CHECK ((("char_length"("first_name") >= 1) AND ("char_length"("first_name") <= 100))),
    CONSTRAINT "kyc_applications_income_range_check" CHECK ((("char_length"("income_range") >= 1) AND ("char_length"("income_range") <= 100))),
    CONSTRAINT "kyc_applications_issuing_country_check" CHECK ((("issuing_country" IS NULL) OR (("char_length"("issuing_country") >= 2) AND ("char_length"("issuing_country") <= 100)))),
    CONSTRAINT "kyc_applications_last_name_check" CHECK ((("char_length"("last_name") >= 1) AND ("char_length"("last_name") <= 100))),
    CONSTRAINT "kyc_applications_nationality_check" CHECK ((("char_length"("nationality") >= 1) AND ("char_length"("nationality") <= 100))),
    CONSTRAINT "kyc_applications_occupation_check" CHECK ((("char_length"("occupation") >= 1) AND ("char_length"("occupation") <= 100))),
    CONSTRAINT "kyc_applications_place_of_birth_check" CHECK ((("char_length"("place_of_birth") >= 1) AND ("char_length"("place_of_birth") <= 160))),
    CONSTRAINT "kyc_applications_requested_items_check" CHECK (("requested_items" <@ ARRAY['identity'::"text", 'birth'::"text", 'address'::"text", 'profile'::"text", 'document_metadata'::"text", 'id_front'::"text", 'id_back'::"text", 'selfie'::"text", 'proof_of_address'::"text"])),
    CONSTRAINT "kyc_applications_review_note_check" CHECK ((("review_note" IS NULL) OR ("char_length"("review_note") <= 1000))),
    CONSTRAINT "kyc_applications_status_check" CHECK (("status" = ANY (ARRAY['submitted'::"text", 'under_review'::"text", 'needs_information'::"text", 'resubmitted'::"text", 'approved'::"text", 'rejected'::"text"]))),
    CONSTRAINT "kyc_applications_version_check" CHECK (("version" > 0))
);


ALTER TABLE "public"."kyc_applications" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."begin_kyc_review"("p_kyc_id" "uuid") RETURNS "public"."kyc_applications"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_id uuid := (select auth.uid());
  kyc_row public.kyc_applications;
  old_status text;
begin
  if caller_id is null
     or not private.is_active_staff(array['reviewer', 'supervisor', 'admin']) then
    raise exception 'STAFF_PERMISSION_REQUIRED' using errcode = '42501';
  end if;

  select * into kyc_row
  from public.kyc_applications
  where id = p_kyc_id
  for update;

  if not found then
    raise exception 'KYC_NOT_FOUND' using errcode = 'P0002';
  end if;
  if kyc_row.status not in ('submitted', 'resubmitted') then
    raise exception 'INVALID_KYC_TRANSITION' using errcode = '55000';
  end if;

  old_status := kyc_row.status;
  update public.kyc_applications
  set
    status = 'under_review',
    reviewed_by = caller_id,
    reviewed_at = null,
    review_note = null,
    requested_items = '{}',
    correction_reason_code = null,
    correction_due_at = null
  where id = p_kyc_id
  returning * into kyc_row;

  insert into public.kyc_review_checklists (
    kyc_id,
    selfie_match,
    updated_by
  )
  values (
    p_kyc_id,
    case
      when kyc_row.document_object_paths ? 'selfie' then 'pending'
      else 'not_applicable'
    end,
    caller_id
  )
  on conflict (kyc_id) do update
  set
    document_quality = 'pending',
    data_consistency = 'pending',
    selfie_match = case
      when kyc_row.document_object_paths ? 'selfie' then 'pending'
      else 'not_applicable'
    end,
    adulthood = 'pending',
    fatca = 'pending',
    pep = 'pending',
    internal_comments = null,
    updated_by = caller_id;

  insert into public.kyc_events (
    kyc_id, actor_id, event_type, from_status, to_status
  )
  values (p_kyc_id, caller_id, 'review_started', old_status, 'under_review');

  return kyc_row;
end;
$$;


ALTER FUNCTION "public"."begin_kyc_review"("p_kyc_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."branch_manager_adjust_balance"("p_account_id" "uuid", "p_target_amount_minor" bigint, "p_value_date" timestamp with time zone, "p_reason" "text", "p_idempotency_key" "uuid") RETURNS "public"."financial_positions"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_id uuid := private.ensure_branch_manager();
  position_row public.financial_positions;
  existing_entry public.financial_ledger_entries;
  normalized_reference text :=
    'ADJ-' || upper(replace(p_idempotency_key::text, '-', ''));
  normalized_reason text := nullif(trim(coalesce(p_reason, '')), '');
  delta_minor bigint;
  next_sequence bigint;
begin
  if p_idempotency_key is null then
    raise exception 'ADJUSTMENT_IDEMPOTENCY_KEY_REQUIRED'
      using errcode = '22023';
  end if;

  select *
  into existing_entry
  from public.financial_ledger_entries
  where entry_key = 'adjustment:' || p_idempotency_key::text;

  if found then
    if existing_entry.account_id <> p_account_id
       or existing_entry.balance_after_minor <> p_target_amount_minor
       or existing_entry.description <> normalized_reason then
      raise exception 'ADJUSTMENT_IDEMPOTENCY_PAYLOAD_MISMATCH'
        using errcode = '22023';
    end if;

    select *
    into position_row
    from public.financial_positions
    where id = p_account_id;

    return position_row;
  end if;

  if p_target_amount_minor < 0
     or p_target_amount_minor > 1000000000000000
     or p_value_date is null
     or normalized_reason is null then
    raise exception 'INVALID_BALANCE_ADJUSTMENT' using errcode = '22023';
  end if;

  select *
  into position_row
  from public.financial_positions
  where id = p_account_id
  for update;

  if not found then
    raise exception 'POSITION_NOT_FOUND' using errcode = 'P0002';
  end if;

  if position_row.account_status <> 'active' then
    raise exception 'ACCOUNT_NOT_ACTIVE' using errcode = '55000';
  end if;

  if p_target_amount_minor < position_row.reserved_minor then
    raise exception 'ADJUSTMENT_CONFLICTS_WITH_RESERVATIONS'
      using errcode = '22003';
  end if;

  delta_minor := p_target_amount_minor - position_row.amount_minor;

  if delta_minor = 0 then
    raise exception 'ADJUSTMENT_DELTA_REQUIRED' using errcode = '22023';
  end if;

  select coalesce(max(sequence_no), 0) + 1
  into next_sequence
  from public.financial_ledger_entries
  where account_id = p_account_id;

  insert into public.financial_ledger_entries (
    account_id,
    owner_id,
    sequence_no,
    entry_key,
    entry_kind,
    amount_minor,
    currency,
    balance_before_minor,
    balance_after_minor,
    value_date,
    internal_reference,
    booked_by,
    description,
    metadata
  )
  values (
    position_row.id,
    position_row.owner_id,
    next_sequence,
    'adjustment:' || p_idempotency_key::text,
    'manual_adjustment',
    delta_minor,
    position_row.currency,
    position_row.amount_minor,
    p_target_amount_minor,
    p_value_date,
    normalized_reference,
    caller_id,
    normalized_reason,
    jsonb_build_object('idempotency_key', p_idempotency_key)
  );

  update public.financial_positions
  set
    amount_minor = p_target_amount_minor,
    position_kind = 'internally_reconciled',
    as_of = p_value_date
  where id = p_account_id
  returning * into position_row;

  insert into public.audit_events (
    actor_id,
    action,
    entity_type,
    entity_id,
    metadata
  )
  values (
    caller_id,
    'branch_manager_adjust_balance',
    'financial_position',
    p_account_id,
    jsonb_build_object(
      'delta_minor', delta_minor,
      'target_amount_minor', p_target_amount_minor,
      'as_of', p_value_date,
      'internal_reference', normalized_reference,
      'reason', normalized_reason
    )
  );

  return position_row;
end;
$$;


ALTER FUNCTION "public"."branch_manager_adjust_balance"("p_account_id" "uuid", "p_target_amount_minor" bigint, "p_value_date" timestamp with time zone, "p_reason" "text", "p_idempotency_key" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."loan_applications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "owner_id" "uuid" NOT NULL,
    "idempotency_key" "uuid" NOT NULL,
    "reference" "text" NOT NULL,
    "requested_amount_minor" bigint NOT NULL,
    "currency" "text" NOT NULL,
    "duration_months" integer NOT NULL,
    "indicative_monthly_payment_minor" bigint,
    "indicative_annual_rate" numeric(8,5),
    "motive" "text" NOT NULL,
    "document_object_paths" "jsonb" NOT NULL,
    "status" "text" DEFAULT 'submitted'::"text" NOT NULL,
    "submitted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "version" integer DEFAULT 1 NOT NULL,
    "credited_position_id" "uuid",
    "disbursed_by" "uuid",
    "disbursed_at" timestamp with time zone,
    "internal_disbursement_reference" "text",
    "motive_code" "text" NOT NULL,
    CONSTRAINT "loan_applications_currency_check" CHECK (("currency" ~ '^[A-Z]{3}$'::"text")),
    CONSTRAINT "loan_applications_disbursement_check" CHECK (((("status" = 'external_settlement_confirmed'::"text") AND ("credited_position_id" IS NOT NULL) AND ("disbursed_by" IS NOT NULL) AND ("disbursed_at" IS NOT NULL)) OR (("status" <> 'external_settlement_confirmed'::"text") AND ("credited_position_id" IS NULL) AND ("disbursed_by" IS NULL) AND ("disbursed_at" IS NULL)))),
    CONSTRAINT "loan_applications_document_object_paths_check" CHECK (("jsonb_typeof"("document_object_paths") = 'array'::"text")),
    CONSTRAINT "loan_applications_duration_months_check" CHECK ((("duration_months" >= 1) AND ("duration_months" <= 600))),
    CONSTRAINT "loan_applications_indicative_annual_rate_check" CHECK ((("indicative_annual_rate" IS NULL) OR ("indicative_annual_rate" >= (0)::numeric))),
    CONSTRAINT "loan_applications_indicative_monthly_payment_minor_check" CHECK ((("indicative_monthly_payment_minor" IS NULL) OR ("indicative_monthly_payment_minor" > 0))),
    CONSTRAINT "loan_applications_internal_disbursement_reference_check" CHECK ((("internal_disbursement_reference" IS NULL) OR (("char_length"("internal_disbursement_reference") >= 3) AND ("char_length"("internal_disbursement_reference") <= 160)))),
    CONSTRAINT "loan_applications_motive_check" CHECK ((("char_length"("motive") >= 1) AND ("char_length"("motive") <= 500))),
    CONSTRAINT "loan_applications_motive_code_check" CHECK (("motive_code" = ANY (ARRAY['personal'::"text", 'real_estate'::"text", 'vehicle'::"text", 'renovation'::"text", 'business_cashflow'::"text", 'other'::"text"]))),
    CONSTRAINT "loan_applications_requested_amount_minor_check" CHECK ((("requested_amount_minor" > 0) AND ("requested_amount_minor" <= '1000000000000000'::bigint))),
    CONSTRAINT "loan_applications_status_check" CHECK (("status" = ANY (ARRAY['submitted'::"text", 'under_review'::"text", 'approved_for_external_funding'::"text", 'external_funding_recorded'::"text", 'external_settlement_confirmed'::"text", 'rejected'::"text", 'cancelled'::"text", 'external_failed'::"text"]))),
    CONSTRAINT "loan_applications_version_check" CHECK (("version" > 0))
);


ALTER TABLE "public"."loan_applications" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."branch_manager_approve_loan"("p_loan_id" "uuid", "p_note" "text" DEFAULT NULL::"text") RETURNS "public"."loan_applications"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_id uuid := private.ensure_branch_manager();
  owner_id uuid;
  loan_row public.loan_applications;
  old_status text;
  completed_check_count integer;
  normalized_note text := nullif(trim(coalesce(p_note, '')), '');
begin
  select loan.owner_id into owner_id from public.loan_applications loan
  where loan.id = p_loan_id;
  if not found then
    raise exception 'LOAN_NOT_FOUND' using errcode = 'P0002';
  end if;
  perform private.lock_client_mutation(owner_id);
  select * into loan_row from public.loan_applications
  where id = p_loan_id for update;
  if not found then
    raise exception 'LOAN_NOT_FOUND' using errcode = 'P0002';
  end if;
  if loan_row.owner_id is distinct from owner_id then
    raise exception 'LOAN_OWNER_CHANGED' using errcode = '40001';
  end if;
  if loan_row.status not in ('submitted', 'under_review') then
    raise exception 'LOAN_CANNOT_BE_APPROVED' using errcode = '55000';
  end if;
  old_status := loan_row.status;
  update public.loan_review_checks
  set status = 'completed', reviewer_id = caller_id, reviewed_at = now(),
      note = coalesce(normalized_note,
        'Contrôles internes confirmés par le chef d’agence.')
  where loan_id = p_loan_id;
  select count(*) into completed_check_count from public.loan_review_checks
  where loan_id = p_loan_id and status = 'completed';
  if completed_check_count <> 4 then
    raise exception 'LOAN_REVIEW_CHECKS_INCOMPLETE' using errcode = '23514';
  end if;
  update public.loan_applications set status = 'approved_for_external_funding'
  where id = p_loan_id returning * into loan_row;
  insert into public.loan_events (
    loan_id, actor_id, event_type, from_status, to_status, reason
  ) values (
    p_loan_id, caller_id, 'branch_manager_approved', old_status,
    loan_row.status, normalized_note
  );
  insert into public.audit_events (
    actor_id, action, entity_type, entity_id, metadata
  ) values (
    caller_id, 'branch_manager_approve_loan', 'loan_application', p_loan_id,
    jsonb_build_object('from_status', old_status, 'to_status', loan_row.status)
  );
  insert into public.notifications (
    recipient_id, title, message, notification_type
  ) values (
    loan_row.owner_id, 'Prêt validé',
    'Le chef d’agence a validé votre demande de prêt. Le décaissement reste effectué en interne avant son enregistrement dans Monalyz.',
    'loan'
  );
  return loan_row;
end;
$$;


ALTER FUNCTION "public"."branch_manager_approve_loan"("p_loan_id" "uuid", "p_note" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."transfer_intents" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "owner_id" "uuid" NOT NULL,
    "source_position_id" "uuid" NOT NULL,
    "idempotency_key" "uuid" NOT NULL,
    "recipient_name" "text" NOT NULL,
    "recipient_account_masked" "text" NOT NULL,
    "beneficiary_details" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "transfer_type" "text" NOT NULL,
    "amount_minor" bigint NOT NULL,
    "currency" "text" NOT NULL,
    "target_amount_minor" bigint NOT NULL,
    "target_currency" "text" NOT NULL,
    "quote_rate" numeric(24,12) NOT NULL,
    "quote_as_of" timestamp with time zone NOT NULL,
    "motive" "text",
    "status" "text" DEFAULT 'submitted'::"text" NOT NULL,
    "submitted_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "version" integer DEFAULT 1 NOT NULL,
    "internal_execution_reference" "text",
    "settled_by" "uuid",
    "settled_at" timestamp with time zone,
    CONSTRAINT "transfer_intents_amount_minor_check" CHECK ((("amount_minor" > 0) AND ("amount_minor" <= '1000000000000000'::bigint))),
    CONSTRAINT "transfer_intents_beneficiary_details_check" CHECK (("jsonb_typeof"("beneficiary_details") = 'object'::"text")),
    CONSTRAINT "transfer_intents_currency_check" CHECK (("currency" ~ '^[A-Z]{3}$'::"text")),
    CONSTRAINT "transfer_intents_internal_execution_reference_check" CHECK ((("internal_execution_reference" IS NULL) OR (("char_length"("internal_execution_reference") >= 3) AND ("char_length"("internal_execution_reference") <= 160)))),
    CONSTRAINT "transfer_intents_motive_check" CHECK ((("motive" IS NULL) OR ("char_length"("motive") <= 500))),
    CONSTRAINT "transfer_intents_quote_rate_check" CHECK (("quote_rate" > (0)::numeric)),
    CONSTRAINT "transfer_intents_recipient_account_masked_check" CHECK ((("char_length"("recipient_account_masked") >= 1) AND ("char_length"("recipient_account_masked") <= 160))),
    CONSTRAINT "transfer_intents_recipient_name_check" CHECK ((("char_length"("recipient_name") >= 1) AND ("char_length"("recipient_name") <= 160))),
    CONSTRAINT "transfer_intents_status_check" CHECK (("status" = ANY (ARRAY['submitted'::"text", 'under_review'::"text", 'approved_for_external_execution'::"text", 'external_execution_recorded'::"text", 'external_settlement_confirmed'::"text", 'rejected'::"text", 'cancelled'::"text", 'external_failed'::"text"]))),
    CONSTRAINT "transfer_intents_target_amount_minor_check" CHECK ((("target_amount_minor" > 0) AND ("target_amount_minor" <= '1000000000000000'::bigint))),
    CONSTRAINT "transfer_intents_target_currency_check" CHECK (("target_currency" ~ '^[A-Z]{3}$'::"text")),
    CONSTRAINT "transfer_intents_transfer_type_check" CHECK (("transfer_type" = ANY (ARRAY['canada'::"text", 'eurozone'::"text", 'usa'::"text", 'swiss'::"text", 'uk'::"text", 'latam'::"text", 'africa'::"text"]))),
    CONSTRAINT "transfer_intents_version_check" CHECK (("version" > 0))
);


ALTER TABLE "public"."transfer_intents" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."branch_manager_approve_transfer"("p_transfer_id" "uuid", "p_note" "text" DEFAULT NULL::"text") RETURNS "public"."transfer_intents"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_id uuid := private.ensure_branch_manager();
  transfer_row public.transfer_intents;
  old_status text;
  completed_check_count integer;
  normalized_note text := nullif(trim(coalesce(p_note, '')), '');
begin
  select *
  into transfer_row
  from public.transfer_intents
  where id = p_transfer_id
  for update;

  if not found then
    raise exception 'TRANSFER_NOT_FOUND' using errcode = 'P0002';
  end if;

  if transfer_row.status not in ('submitted', 'under_review') then
    raise exception 'TRANSFER_CANNOT_BE_APPROVED' using errcode = '55000';
  end if;

  old_status := transfer_row.status;

  update public.transfer_review_checks
  set
    status = 'completed',
    reviewer_id = caller_id,
    reviewed_at = now(),
    note = coalesce(normalized_note, 'Contrôles internes confirmés par le chef d’agence.')
  where transfer_id = p_transfer_id;

  select count(*)
  into completed_check_count
  from public.transfer_review_checks
  where transfer_id = p_transfer_id
    and status = 'completed';

  if completed_check_count <> 4 then
    raise exception 'TRANSFER_REVIEW_CHECKS_INCOMPLETE' using errcode = '23514';
  end if;

  update public.transfer_intents
  set status = 'approved_for_external_execution'
  where id = p_transfer_id
  returning * into transfer_row;

  insert into public.transfer_events (
    transfer_id, actor_id, event_type, from_status, to_status, reason
  )
  values (
    p_transfer_id,
    caller_id,
    'branch_manager_approved',
    old_status,
    transfer_row.status,
    normalized_note
  );

  insert into public.audit_events (
    actor_id, action, entity_type, entity_id, metadata
  )
  values (
    caller_id,
    'branch_manager_approve_transfer',
    'transfer_intent',
    p_transfer_id,
    jsonb_build_object('from_status', old_status, 'to_status', transfer_row.status)
  );

  insert into public.notifications (
    recipient_id, title, message, notification_type
  )
  values (
    transfer_row.owner_id,
    'Virement validé',
    'Le chef d’agence a validé votre demande. Le virement doit maintenant être exécuté hors de Monalyz.',
    'transfer'
  );

  return transfer_row;
end;
$$;


ALTER FUNCTION "public"."branch_manager_approve_transfer"("p_transfer_id" "uuid", "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."branch_manager_declare_account"("p_owner_id" "uuid", "p_label" "text", "p_account_type" "text", "p_currency" "text", "p_iban" "text", "p_bic" "text", "p_account_holder_name" "text", "p_institution_name" "text", "p_branch_name" "text", "p_branch_code" "text", "p_opening_balance_minor" bigint, "p_opened_at" timestamp with time zone, "p_is_demo" boolean, "p_reason" "text", "p_idempotency_key" "uuid") RETURNS "public"."financial_positions"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  caller_id uuid := private.ensure_branch_manager();
  position_row public.financial_positions;
  configuration private.account_number_configuration;
  normalized_account_number text;
  normalized_iban text :=
    private.normalize_iban(coalesce(p_iban, ''));
  normalized_bic text := upper(trim(coalesce(p_bic, '')));
  normalized_branch_code text :=
    upper(trim(coalesce(p_branch_code, '')));
  normalized_reason text := nullif(trim(coalesce(p_reason, '')), '');
  suffix_width integer;
  suffix_capacity integer;
  random_start integer;
begin
  if p_idempotency_key is null then
    raise exception 'ACCOUNT_IDEMPOTENCY_KEY_REQUIRED'
      using errcode = '22023';
  end if;

  select *
  into position_row
  from public.financial_positions
  where declaration_idempotency_key = p_idempotency_key;

  if found then
    if position_row.owner_id <> p_owner_id
       or position_row.label <> trim(coalesce(p_label, ''))
       or position_row.account_type <> p_account_type
       or position_row.currency <> upper(trim(coalesce(p_currency, '')))
       or position_row.amount_minor <> p_opening_balance_minor
       or position_row.iban <> normalized_iban
       or position_row.bic <> normalized_bic
       or position_row.account_holder_name
          <> trim(coalesce(p_account_holder_name, ''))
       or position_row.institution_name
          <> trim(coalesce(p_institution_name, ''))
       or position_row.branch_name <> trim(coalesce(p_branch_name, ''))
       or position_row.branch_code <> normalized_branch_code
       or position_row.opened_at is distinct from p_opened_at
       or position_row.is_demo <> coalesce(p_is_demo, false) then
      raise exception 'ACCOUNT_IDEMPOTENCY_PAYLOAD_MISMATCH'
        using errcode = '22023';
    end if;

    if not exists (
      select 1
      from public.financial_ledger_entries
      where account_id = position_row.id
        and entry_key =
          'account-opening:' || p_idempotency_key::text
        and description = normalized_reason
    ) then
      raise exception 'ACCOUNT_IDEMPOTENCY_PAYLOAD_MISMATCH'
        using errcode = '22023';
    end if;

    return position_row;
  end if;

  if not exists (
    select 1
    from public.profiles
    where user_id = p_owner_id
      and access_status = 'active'
  ) then
    raise exception 'ACCOUNT_OWNER_NOT_ACTIVE' using errcode = '22023';
  end if;

  if not exists (
    select 1
    from public.kyc_applications
    where owner_id = p_owner_id
      and status = 'approved'
  ) then
    raise exception 'APPROVED_KYC_REQUIRED' using errcode = '23514';
  end if;

  if p_account_type <> 'current'
     or upper(trim(coalesce(p_currency, ''))) !~ '^[A-Z]{3}$'
     or p_opening_balance_minor < 0
     or p_opening_balance_minor > 1000000000000000
     or p_opened_at is null
     or normalized_reason is null
     or nullif(trim(coalesce(p_label, '')), '') is null
     or nullif(trim(coalesce(p_account_holder_name, '')), '') is null
     or nullif(trim(coalesce(p_institution_name, '')), '') is null
     or nullif(trim(coalesce(p_branch_name, '')), '') is null then
    raise exception 'INVALID_ACCOUNT_DECLARATION' using errcode = '22023';
  end if;

  if not private.is_valid_iban(normalized_iban)
     or normalized_bic !~ '^[A-Z]{6}[A-Z0-9]{2}([A-Z0-9]{3})?$'
     or normalized_branch_code !~ '^[A-Z0-9-]{1,40}$' then
    raise exception 'INVALID_ACCOUNT_IDENTIFIER' using errcode = '22023';
  end if;

  select *
  into configuration
  from private.account_number_configuration
  where singleton
  for update;

  if not found then
    raise exception 'ACCOUNT_NUMBER_PREFIX_NOT_CONFIGURED'
      using errcode = '55000';
  end if;

  suffix_width := 10 - char_length(configuration.prefix);
  suffix_capacity :=
    power(10::numeric, suffix_width)::integer;
  random_start := floor(random() * suffix_capacity)::integer;

  select
    configuration.prefix
    || lpad(
      ((random_start + candidate.offset_value) % suffix_capacity)::text,
      suffix_width,
      '0'
    )
  into normalized_account_number
  from generate_series(0, suffix_capacity - 1)
    as candidate(offset_value)
  where not exists (
    select 1
    from public.financial_positions as existing
    where existing.account_number =
      configuration.prefix
      || lpad(
        ((random_start + candidate.offset_value) % suffix_capacity)::text,
        suffix_width,
        '0'
      )
  )
  limit 1;

  if normalized_account_number is null then
    raise exception 'ACCOUNT_NUMBER_PREFIX_EXHAUSTED'
      using errcode = '54000';
  end if;

  insert into public.financial_positions (
    owner_id,
    label,
    position_kind,
    currency,
    amount_minor,
    reserved_minor,
    as_of,
    external_identifier_masked,
    account_type,
    account_number,
    iban,
    bic,
    account_holder_name,
    institution_name,
    branch_name,
    branch_code,
    account_status,
    opened_at,
    declared_by,
    is_demo,
    declaration_idempotency_key
  )
  values (
    p_owner_id,
    trim(p_label),
    'internally_reconciled',
    upper(trim(p_currency)),
    p_opening_balance_minor,
    0,
    p_opened_at,
    '••••' || right(normalized_account_number, 4),
    p_account_type,
    normalized_account_number,
    normalized_iban,
    normalized_bic,
    trim(p_account_holder_name),
    trim(p_institution_name),
    trim(p_branch_name),
    normalized_branch_code,
    'active',
    p_opened_at,
    caller_id,
    coalesce(p_is_demo, false),
    p_idempotency_key
  )
  returning * into position_row;

  insert into public.financial_ledger_entries (
    account_id,
    owner_id,
    sequence_no,
    entry_key,
    entry_kind,
    amount_minor,
    currency,
    balance_before_minor,
    balance_after_minor,
    value_date,
    internal_reference,
    booked_by,
    description,
    metadata
  )
  values (
    position_row.id,
    position_row.owner_id,
    1,
    'account-opening:' || p_idempotency_key::text,
    'account_opening',
    p_opening_balance_minor,
    position_row.currency,
    0,
    p_opening_balance_minor,
    p_opened_at,
    'ACCOUNT-' || upper(replace(position_row.id::text, '-', '')),
    caller_id,
    normalized_reason,
    jsonb_build_object(
      'account_number', normalized_account_number
    )
  );

  insert into public.audit_events (
    actor_id,
    action,
    entity_type,
    entity_id,
    metadata
  )
  values (
    caller_id,
    'branch_manager_declare_account',
    'financial_position',
    position_row.id,
    jsonb_build_object(
      'account_number', normalized_account_number,
      'account_number_prefix', configuration.prefix,
      'currency', position_row.currency,
      'opening_amount_minor', p_opening_balance_minor,
      'reason', normalized_reason
    )
  );

  return position_row;
exception
  when unique_violation then
    raise exception 'ACCOUNT_IDENTIFIER_ALREADY_EXISTS'
      using errcode = '23505';
end;
$_$;


ALTER FUNCTION "public"."branch_manager_declare_account"("p_owner_id" "uuid", "p_label" "text", "p_account_type" "text", "p_currency" "text", "p_iban" "text", "p_bic" "text", "p_account_holder_name" "text", "p_institution_name" "text", "p_branch_name" "text", "p_branch_code" "text", "p_opening_balance_minor" bigint, "p_opened_at" timestamp with time zone, "p_is_demo" boolean, "p_reason" "text", "p_idempotency_key" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."branch_manager_disburse_loan"("p_loan_id" "uuid", "p_destination_position_id" "uuid", "p_note" "text") RETURNS "public"."loan_applications"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_id uuid := private.ensure_branch_manager();
  loan_row public.loan_applications;
  position_row public.financial_positions;
  old_status text;
  normalized_note text := nullif(trim(coalesce(p_note, '')), '');
  generated_reference text;
  next_sequence bigint;
  ledger_entry_id uuid;
begin
  if normalized_note is null then
    raise exception 'DISBURSEMENT_NOTE_REQUIRED' using errcode = '22023';
  end if;

  select *
  into loan_row
  from public.loan_applications
  where id = p_loan_id
  for update;

  if not found then
    raise exception 'LOAN_NOT_FOUND' using errcode = 'P0002';
  end if;

  if loan_row.status not in (
    'approved_for_external_funding',
    'external_funding_recorded'
  ) then
    raise exception 'LOAN_NOT_READY_FOR_DISBURSEMENT'
      using errcode = '55000';
  end if;

  select *
  into position_row
  from public.financial_positions
  where id = p_destination_position_id
    and owner_id = loan_row.owner_id
  for update;

  if not found then
    raise exception 'LOAN_DESTINATION_POSITION_NOT_FOUND'
      using errcode = 'P0002';
  end if;

  if position_row.account_status <> 'active' then
    raise exception 'LOAN_DESTINATION_ACCOUNT_NOT_ACTIVE'
      using errcode = '55000';
  end if;

  if position_row.account_type <> 'current' then
    raise exception 'LOAN_DESTINATION_MUST_BE_CURRENT_ACCOUNT'
      using errcode = '22023';
  end if;

  if position_row.currency <> loan_row.currency then
    raise exception 'LOAN_DESTINATION_CURRENCY_MISMATCH'
      using errcode = '22023';
  end if;

  if position_row.amount_minor
     > 1000000000000000 - loan_row.requested_amount_minor then
    raise exception 'FINANCIAL_POSITION_LIMIT_EXCEEDED'
      using errcode = '22003';
  end if;

  old_status := loan_row.status;
  generated_reference :=
    'MONALYZ-LOAN-' || upper(replace(loan_row.id::text, '-', ''));

  select coalesce(max(sequence_no), 0) + 1
  into next_sequence
  from public.financial_ledger_entries
  where account_id = position_row.id;

  insert into public.financial_ledger_entries (
    account_id,
    owner_id,
    sequence_no,
    entry_key,
    entry_kind,
    amount_minor,
    currency,
    balance_before_minor,
    balance_after_minor,
    value_date,
    internal_reference,
    source_loan_id,
    booked_by,
    description,
    metadata
  )
  values (
    position_row.id,
    loan_row.owner_id,
    next_sequence,
    'loan:' || loan_row.id::text,
    'loan_credit',
    loan_row.requested_amount_minor,
    loan_row.currency,
    position_row.amount_minor,
    position_row.amount_minor + loan_row.requested_amount_minor,
    now(),
    generated_reference,
    loan_row.id,
    caller_id,
    normalized_note,
    jsonb_build_object('loan_reference', loan_row.reference)
  )
  returning id into ledger_entry_id;

  update public.financial_positions
  set
    amount_minor = amount_minor + loan_row.requested_amount_minor,
    position_kind = 'internally_reconciled',
    as_of = now()
  where id = p_destination_position_id;

  update public.loan_applications
  set
    status = 'external_settlement_confirmed',
    credited_position_id = p_destination_position_id,
    disbursed_by = caller_id,
    disbursed_at = now(),
    internal_disbursement_reference = generated_reference
  where id = p_loan_id
  returning * into loan_row;

  insert into public.loan_events (
    loan_id,
    actor_id,
    event_type,
    from_status,
    to_status,
    reason,
    metadata
  )
  values (
    p_loan_id,
    caller_id,
    'branch_manager_disbursed',
    old_status,
    loan_row.status,
    normalized_note,
    jsonb_build_object(
      'credited_position_id', p_destination_position_id,
      'ledger_entry_id', ledger_entry_id,
      'internal_disbursement_reference', generated_reference
    )
  );

  insert into public.audit_events (
    actor_id,
    action,
    entity_type,
    entity_id,
    metadata
  )
  values (
    caller_id,
    'branch_manager_disburse_loan',
    'loan_application',
    p_loan_id,
    jsonb_build_object(
      'from_status', old_status,
      'to_status', loan_row.status,
      'credited_position_id', p_destination_position_id,
      'ledger_entry_id', ledger_entry_id,
      'internal_disbursement_reference', generated_reference,
      'amount_minor', loan_row.requested_amount_minor,
      'currency', loan_row.currency
    )
  );

  insert into public.notifications (
    recipient_id,
    title,
    message,
    notification_type
  )
  values (
    loan_row.owner_id,
    'Prêt décaissé',
    'Votre prêt a été décaissé avec succès et votre compte courant Monalyz a été crédité.',
    'loan'
  );

  return loan_row;
end;
$$;


ALTER FUNCTION "public"."branch_manager_disburse_loan"("p_loan_id" "uuid", "p_destination_position_id" "uuid", "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."branch_manager_finalize_transfer"("p_transfer_id" "uuid", "p_note" "text" DEFAULT NULL::"text") RETURNS "public"."transfer_intents"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_id uuid := private.ensure_branch_manager();
  transfer_row public.transfer_intents;
  position_row public.financial_positions;
  old_status text;
  normalized_note text := nullif(trim(coalesce(p_note, '')), '');
  ledger_description text := coalesce(
    normalized_note,
    'Virement confirmé après validation finale.'
  );
  generated_reference text;
  next_sequence bigint;
  ledger_entry_id uuid;
begin
  select * into transfer_row
  from public.transfer_intents
  where id = p_transfer_id
  for update;

  if not found then
    raise exception 'TRANSFER_NOT_FOUND' using errcode = 'P0002';
  end if;

  if transfer_row.status = 'under_review'
     and exists (
       select 1 from public.transfer_review_checks
       where transfer_id = p_transfer_id and status <> 'completed'
     ) then
    raise exception 'TRANSFER_REVIEW_CHECKS_INCOMPLETE' using errcode = '23514';
  end if;

  if transfer_row.status not in (
    'under_review', 'approved_for_external_execution', 'external_execution_recorded'
  ) then
    raise exception 'TRANSFER_NOT_READY_FOR_FINALIZATION' using errcode = '55000';
  end if;

  select * into position_row
  from public.financial_positions
  where id = transfer_row.source_position_id
    and owner_id = transfer_row.owner_id
  for update;

  if not found then
    raise exception 'TRANSFER_SOURCE_ACCOUNT_NOT_FOUND' using errcode = 'P0002';
  end if;
  if position_row.account_status <> 'active' then
    raise exception 'TRANSFER_SOURCE_ACCOUNT_NOT_ACTIVE' using errcode = '55000';
  end if;
  if position_row.amount_minor < transfer_row.amount_minor
     or position_row.reserved_minor < transfer_row.amount_minor then
    raise exception 'TRANSFER_POSITION_RECONCILIATION_CONFLICT' using errcode = '55000';
  end if;

  old_status := transfer_row.status;
  generated_reference := 'MONALYZ-TRF-' || upper(replace(transfer_row.id::text, '-', ''));

  select coalesce(max(sequence_no), 0) + 1 into next_sequence
  from public.financial_ledger_entries where account_id = position_row.id;

  insert into public.financial_ledger_entries (
    account_id, owner_id, sequence_no, entry_key, entry_kind, amount_minor,
    currency, balance_before_minor, balance_after_minor, value_date,
    internal_reference, source_transfer_id, booked_by, description, metadata
  ) values (
    position_row.id, transfer_row.owner_id, next_sequence,
    'transfer:' || transfer_row.id::text, 'transfer_debit', -transfer_row.amount_minor,
    transfer_row.currency, position_row.amount_minor,
    position_row.amount_minor - transfer_row.amount_minor, now(),
    generated_reference, transfer_row.id, caller_id, ledger_description,
    jsonb_build_object(
      'recipient_name', transfer_row.recipient_name,
      'target_amount_minor', transfer_row.target_amount_minor,
      'target_currency', transfer_row.target_currency
    )
  ) returning id into ledger_entry_id;

  update public.financial_positions
  set amount_minor = amount_minor - transfer_row.amount_minor,
      reserved_minor = reserved_minor - transfer_row.amount_minor,
      position_kind = 'internally_reconciled', as_of = now()
  where id = position_row.id;

  update public.transfer_intents
  set status = 'external_settlement_confirmed',
      internal_execution_reference = generated_reference,
      settled_by = caller_id, settled_at = now()
  where id = p_transfer_id
  returning * into transfer_row;

  insert into public.transfer_events (
    transfer_id, actor_id, event_type, from_status, to_status, reason, metadata
  ) values (
    p_transfer_id, caller_id, 'branch_manager_confirmed_effective_transfer',
    old_status, transfer_row.status, normalized_note,
    jsonb_build_object(
      'ledger_entry_id', ledger_entry_id,
      'internal_execution_reference', generated_reference
    )
  );

  insert into public.audit_events (
    actor_id, action, entity_type, entity_id, metadata
  ) values (
    caller_id, 'branch_manager_finalize_transfer', 'transfer_intent', p_transfer_id,
    jsonb_build_object(
      'from_status', old_status,
      'to_status', transfer_row.status,
      'ledger_entry_id', ledger_entry_id,
      'internal_execution_reference', generated_reference,
      'amount_minor', transfer_row.amount_minor,
      'currency', transfer_row.currency,
      'note', normalized_note
    )
  );

  insert into public.notifications (recipient_id, title, message, notification_type)
  values (
    transfer_row.owner_id, 'Virement effectué',
    'Votre virement a été confirmé comme effectué avec succès.', 'transfer'
  );

  return transfer_row;
end;
$$;


ALTER FUNCTION "public"."branch_manager_finalize_transfer"("p_transfer_id" "uuid", "p_note" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."official_documents" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "owner_id" "uuid" NOT NULL,
    "account_id" "uuid",
    "transfer_id" "uuid",
    "loan_id" "uuid",
    "document_number" "text" NOT NULL,
    "document_type" "text" NOT NULL,
    "title" "text" NOT NULL,
    "language" "text" DEFAULT 'fr'::"text" NOT NULL,
    "period_start" "date",
    "period_end" "date",
    "version" integer DEFAULT 1 NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "snapshot" "jsonb" NOT NULL,
    "snapshot_hash" "text" NOT NULL,
    "content_hash" "text",
    "storage_path" "text",
    "issued_by" "uuid" NOT NULL,
    "requested_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "issued_at" timestamp with time zone,
    "revoked_by" "uuid",
    "revoked_at" timestamp with time zone,
    "revocation_reason" "text",
    "failure_reason" "text",
    "is_demo" boolean DEFAULT false NOT NULL,
    "idempotency_key" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "localization_revision" integer DEFAULT 2 NOT NULL,
    "supersedes_document_id" "uuid",
    "brand_name_snapshot" "text" DEFAULT 'Monalyz'::"text" NOT NULL,
    "brand_revision_snapshot" bigint DEFAULT 1 NOT NULL,
    "brand_logo_path_snapshot" "text" DEFAULT '/brand/monalyz/monalyz-wordmark-reversed-white.png'::"text" NOT NULL,
    CONSTRAINT "official_documents_check" CHECK (((("document_type" = ANY (ARRAY['bank_details'::"text", 'account_statement'::"text", 'balance_certificate'::"text"])) AND ("account_id" IS NOT NULL) AND ("transfer_id" IS NULL) AND ("loan_id" IS NULL)) OR (("document_type" = 'transfer_confirmation'::"text") AND ("account_id" IS NOT NULL) AND ("transfer_id" IS NOT NULL) AND ("loan_id" IS NULL)) OR (("document_type" = 'loan_disbursement_confirmation'::"text") AND ("account_id" IS NOT NULL) AND ("transfer_id" IS NULL) AND ("loan_id" IS NOT NULL)) OR (("document_type" = 'loan_decision'::"text") AND ("transfer_id" IS NULL) AND ("loan_id" IS NOT NULL)))),
    CONSTRAINT "official_documents_check1" CHECK (((("document_type" = 'account_statement'::"text") AND ("period_start" IS NOT NULL) AND ("period_end" IS NOT NULL) AND ("period_end" >= "period_start") AND ("period_end" <= ("period_start" + 366))) OR (("document_type" <> 'account_statement'::"text") AND ("period_start" IS NULL) AND ("period_end" IS NULL)))),
    CONSTRAINT "official_documents_check2" CHECK (((("status" = 'pending'::"text") AND ("storage_path" IS NULL) AND ("content_hash" IS NULL) AND ("issued_at" IS NULL) AND ("failure_reason" IS NULL) AND ("revoked_by" IS NULL) AND ("revoked_at" IS NULL) AND ("revocation_reason" IS NULL)) OR (("status" = 'issued'::"text") AND ("storage_path" IS NOT NULL) AND ("content_hash" IS NOT NULL) AND ("issued_at" IS NOT NULL) AND ("failure_reason" IS NULL) AND ("revoked_by" IS NULL) AND ("revoked_at" IS NULL) AND ("revocation_reason" IS NULL)) OR (("status" = 'failed'::"text") AND ("storage_path" IS NULL) AND ("content_hash" IS NULL) AND ("issued_at" IS NULL) AND ("failure_reason" IS NOT NULL) AND ("revoked_by" IS NULL) AND ("revoked_at" IS NULL) AND ("revocation_reason" IS NULL)) OR (("status" = 'revoked'::"text") AND ("storage_path" IS NOT NULL) AND ("content_hash" IS NOT NULL) AND ("issued_at" IS NOT NULL) AND ("failure_reason" IS NULL) AND ("revoked_by" IS NOT NULL) AND ("revoked_at" IS NOT NULL) AND ("revocation_reason" IS NOT NULL)))),
    CONSTRAINT "official_documents_content_hash_check" CHECK ((("content_hash" IS NULL) OR ("content_hash" ~ '^[a-f0-9]{64}$'::"text"))),
    CONSTRAINT "official_documents_document_number_check" CHECK ((("char_length"("document_number") >= 6) AND ("char_length"("document_number") <= 80))),
    CONSTRAINT "official_documents_document_type_check" CHECK (("document_type" = ANY (ARRAY['bank_details'::"text", 'account_statement'::"text", 'balance_certificate'::"text", 'transfer_confirmation'::"text", 'loan_disbursement_confirmation'::"text", 'loan_decision'::"text"]))),
    CONSTRAINT "official_documents_failure_reason_check" CHECK ((("failure_reason" IS NULL) OR (("char_length"("failure_reason") >= 3) AND ("char_length"("failure_reason") <= 1000)))),
    CONSTRAINT "official_documents_language_check" CHECK (("language" = ANY (ARRAY['fr'::"text", 'en'::"text", 'de'::"text", 'es'::"text", 'it'::"text", 'nl'::"text"]))),
    CONSTRAINT "official_documents_localization_revision_check" CHECK (("localization_revision" > 0)),
    CONSTRAINT "official_documents_revocation_reason_check" CHECK ((("revocation_reason" IS NULL) OR (("char_length"("revocation_reason") >= 3) AND ("char_length"("revocation_reason") <= 1000)))),
    CONSTRAINT "official_documents_snapshot_check" CHECK (("jsonb_typeof"("snapshot") = 'object'::"text")),
    CONSTRAINT "official_documents_snapshot_hash_check" CHECK (("snapshot_hash" ~ '^[a-f0-9]{64}$'::"text")),
    CONSTRAINT "official_documents_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'issued'::"text", 'failed'::"text", 'revoked'::"text"]))),
    CONSTRAINT "official_documents_storage_path_check" CHECK ((("storage_path" IS NULL) OR ((("char_length"("storage_path") >= 10) AND ("char_length"("storage_path") <= 500)) AND ("storage_path" !~ '(^|/)\.\.(/|$)'::"text")))),
    CONSTRAINT "official_documents_title_check" CHECK ((("char_length"("title") >= 3) AND ("char_length"("title") <= 200))),
    CONSTRAINT "official_documents_version_check" CHECK (("version" > 0))
);


ALTER TABLE "public"."official_documents" OWNER TO "postgres";


COMMENT ON COLUMN "public"."official_documents"."brand_name_snapshot" IS 'Published bank name captured when the immutable document version is created.';



COMMENT ON COLUMN "public"."official_documents"."brand_revision_snapshot" IS 'Published brand revision captured when the immutable document version is created.';



COMMENT ON COLUMN "public"."official_documents"."brand_logo_path_snapshot" IS 'Versioned PDF logo path captured when the immutable document version is created.';



CREATE OR REPLACE FUNCTION "public"."branch_manager_issue_official_document"("p_owner_id" "uuid", "p_account_id" "uuid", "p_transfer_id" "uuid", "p_loan_id" "uuid", "p_document_type" "text", "p_title" "text", "p_language" "text", "p_period_start" "date", "p_period_end" "date", "p_idempotency_key" "uuid") RETURNS "public"."official_documents"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_id uuid := private.ensure_branch_manager();
  existing_document public.official_documents;
  document_row public.official_documents;
  account_row public.financial_positions;
  transfer_row public.transfer_intents;
  loan_row public.loan_applications;
  document_snapshot jsonb;
  document_id uuid := gen_random_uuid();
  generated_number text;
  generated_version integer;
  document_is_demo boolean := false;
  normalized_title text := nullif(trim(coalesce(p_title, '')), '');
  normalized_language text := lower(trim(coalesce(p_language, '')));
begin
  if p_idempotency_key is null
     or normalized_title is null
     or normalized_language not in ('fr', 'en', 'de', 'es', 'it', 'nl')
     or p_document_type not in (
       'bank_details',
       'account_statement',
       'balance_certificate',
       'transfer_confirmation',
       'loan_disbursement_confirmation',
       'loan_decision'
     ) then
    raise exception 'INVALID_OFFICIAL_DOCUMENT_REQUEST'
      using errcode = '22023';
  end if;

  select *
  into existing_document
  from public.official_documents
  where owner_id = p_owner_id
    and idempotency_key = p_idempotency_key;

  if found then
    if existing_document.account_id is distinct from p_account_id
       or existing_document.transfer_id is distinct from p_transfer_id
       or existing_document.loan_id is distinct from p_loan_id
       or existing_document.document_type <> p_document_type
       or existing_document.title <> normalized_title
       or existing_document.language <> normalized_language
       or existing_document.period_start is distinct from p_period_start
       or existing_document.period_end is distinct from p_period_end then
      raise exception 'DOCUMENT_IDEMPOTENCY_PAYLOAD_MISMATCH'
        using errcode = '22023';
    end if;

    return existing_document;
  end if;

  if not exists (
    select 1
    from public.profiles
    where user_id = p_owner_id
      and access_status = 'active'
  ) then
    raise exception 'DOCUMENT_OWNER_NOT_ACTIVE' using errcode = '22023';
  end if;

  if p_account_id is not null then
    select *
    into account_row
    from public.financial_positions
    where id = p_account_id
      and owner_id = p_owner_id;

    if not found then
      raise exception 'DOCUMENT_ACCOUNT_NOT_FOUND' using errcode = 'P0002';
    end if;

    if account_row.account_status <> 'active' then
      raise exception 'DOCUMENT_ACCOUNT_NOT_ACTIVE' using errcode = '55000';
    end if;

    document_is_demo := account_row.is_demo;
  end if;

  if p_transfer_id is not null then
    select *
    into transfer_row
    from public.transfer_intents
    where id = p_transfer_id
      and owner_id = p_owner_id;

    if not found then
      raise exception 'DOCUMENT_TRANSFER_NOT_FOUND' using errcode = 'P0002';
    end if;

    if transfer_row.status <> 'external_settlement_confirmed'
       or transfer_row.source_position_id is distinct from p_account_id then
      raise exception 'DOCUMENT_TRANSFER_NOT_FINAL'
        using errcode = '55000';
    end if;
  end if;

  if p_loan_id is not null then
    select *
    into loan_row
    from public.loan_applications
    where id = p_loan_id
      and owner_id = p_owner_id;

    if not found then
      raise exception 'DOCUMENT_LOAN_NOT_FOUND' using errcode = 'P0002';
    end if;

    if p_document_type = 'loan_disbursement_confirmation'
       and (
         loan_row.status <> 'external_settlement_confirmed'
         or loan_row.credited_position_id is distinct from p_account_id
       ) then
      raise exception 'DOCUMENT_LOAN_NOT_DISBURSED'
        using errcode = '55000';
    end if;

    if p_document_type = 'loan_decision'
       and loan_row.status in ('submitted', 'under_review') then
      raise exception 'DOCUMENT_LOAN_DECISION_NOT_FINAL'
        using errcode = '55000';
    end if;
  end if;

  if p_document_type in (
    'bank_details',
    'account_statement',
    'balance_certificate'
  ) and (
    p_account_id is null
    or p_transfer_id is not null
    or p_loan_id is not null
  ) then
    raise exception 'DOCUMENT_ACCOUNT_SOURCE_REQUIRED'
      using errcode = '22023';
  end if;

  if p_document_type = 'transfer_confirmation'
     and (
       p_account_id is null
       or p_transfer_id is null
       or p_loan_id is not null
     ) then
    raise exception 'DOCUMENT_TRANSFER_SOURCE_REQUIRED'
      using errcode = '22023';
  end if;

  if p_document_type = 'loan_disbursement_confirmation'
     and (
       p_account_id is null
       or p_transfer_id is not null
       or p_loan_id is null
     ) then
    raise exception 'DOCUMENT_LOAN_DISBURSEMENT_SOURCE_REQUIRED'
      using errcode = '22023';
  end if;

  if p_document_type = 'loan_decision'
     and (p_transfer_id is not null or p_loan_id is null) then
    raise exception 'DOCUMENT_LOAN_DECISION_SOURCE_REQUIRED'
      using errcode = '22023';
  end if;

  if p_document_type = 'account_statement' then
    if p_period_start is null
       or p_period_end is null
       or p_period_end < p_period_start
       or p_period_end > p_period_start + 366 then
      raise exception 'INVALID_STATEMENT_PERIOD' using errcode = '22023';
    end if;
  elsif p_period_start is not null or p_period_end is not null then
    raise exception 'DOCUMENT_PERIOD_NOT_ALLOWED' using errcode = '22023';
  end if;

  document_snapshot := jsonb_strip_nulls(
    jsonb_build_object(
      'schemaVersion', 1,
      'documentType', p_document_type,
      'title', normalized_title,
      'language', normalized_language,
      'ownerId', p_owner_id,
      'account',
      case
        when p_account_id is null then null
        else jsonb_build_object(
          'id', account_row.id,
          'label', account_row.label,
          'accountType', account_row.account_type,
          'accountNumber', account_row.account_number,
          'iban', account_row.iban,
          'bic', account_row.bic,
          'holderName', account_row.account_holder_name,
          'institutionName', account_row.institution_name,
          'branchName', account_row.branch_name,
          'branchCode', account_row.branch_code,
          'currency', account_row.currency,
          'balanceMinor', account_row.amount_minor,
          'availableBalanceMinor',
            account_row.amount_minor - account_row.reserved_minor,
          'asOf', account_row.as_of,
          'openedAt', account_row.opened_at,
          'isDemo', account_row.is_demo
        )
      end,
      'transfer',
      case
        when p_transfer_id is null then null
        else jsonb_build_object(
          'id', transfer_row.id,
          'reference', transfer_row.internal_execution_reference,
          'recipientName', transfer_row.recipient_name,
          'recipientAccountMasked', transfer_row.recipient_account_masked,
          'amountMinor', transfer_row.amount_minor,
          'currency', transfer_row.currency,
          'targetAmountMinor', transfer_row.target_amount_minor,
          'targetCurrency', transfer_row.target_currency,
          'settledAt', transfer_row.settled_at
        )
      end,
      'loan',
      case
        when p_loan_id is null then null
        else jsonb_build_object(
          'id', loan_row.id,
          'reference', loan_row.reference,
          'disbursementReference',
            loan_row.internal_disbursement_reference,
          'requestedAmountMinor', loan_row.requested_amount_minor,
          'currency', loan_row.currency,
          'durationMonths', loan_row.duration_months,
          'annualRate', loan_row.indicative_annual_rate,
          'status', loan_row.status,
          'disbursedAt', loan_row.disbursed_at
        )
      end,
      'periodStart', p_period_start,
      'periodEnd', p_period_end,
      'entries',
      case
        when p_document_type <> 'account_statement' then null
        else coalesce(
          (
            select jsonb_agg(
              jsonb_build_object(
                'id', entry.id,
                'entryKind', entry.entry_kind,
                'amountMinor', entry.amount_minor,
                'balanceAfterMinor', entry.balance_after_minor,
                'currency', entry.currency,
                'description', entry.description,
                'internalReference', entry.internal_reference,
                'valueDate', entry.value_date,
                'bookedAt', entry.booked_at
              )
              order by entry.value_date, entry.sequence_no
            )
            from public.financial_ledger_entries as entry
            where entry.account_id = p_account_id
              and entry.value_date >= p_period_start::timestamptz
              and entry.value_date
                < (p_period_end + 1)::timestamptz
          ),
          '[]'::jsonb
        )
      end,
      'demo',
      case
        when document_is_demo then jsonb_build_object(
          'isDemo', true,
          'watermark', 'DÉMONSTRATION — AUCUNE VALEUR'
        )
        else null
      end,
      'issuedBy', caller_id,
      'requestedAt', now()
    )
  );

  select coalesce(max(version), 0) + 1
  into generated_version
  from public.official_documents
  where owner_id = p_owner_id
    and document_type = p_document_type
    and account_id is not distinct from p_account_id
    and transfer_id is not distinct from p_transfer_id
    and loan_id is not distinct from p_loan_id;

  generated_number :=
    'MON-'
    || to_char(now(), 'YYYY')
    || '-'
    || upper(replace(document_id::text, '-', ''));

  insert into public.official_documents (
    id,
    owner_id,
    account_id,
    transfer_id,
    loan_id,
    document_number,
    document_type,
    title,
    language,
    period_start,
    period_end,
    version,
    status,
    snapshot,
    snapshot_hash,
    issued_by,
    is_demo,
    idempotency_key
  )
  values (
    document_id,
    p_owner_id,
    p_account_id,
    p_transfer_id,
    p_loan_id,
    generated_number,
    p_document_type,
    normalized_title,
    normalized_language,
    p_period_start,
    p_period_end,
    generated_version,
    'pending',
    document_snapshot,
    encode(
      extensions.digest(
        convert_to(document_snapshot::text, 'UTF8'),
        'sha256'
      ),
      'hex'
    ),
    caller_id,
    document_is_demo,
    p_idempotency_key
  )
  returning * into document_row;

  insert into public.audit_events (
    actor_id,
    action,
    entity_type,
    entity_id,
    metadata
  )
  values (
    caller_id,
    'branch_manager_issue_official_document',
    'official_document',
    document_row.id,
    jsonb_build_object(
      'document_number', document_row.document_number,
      'document_type', document_row.document_type,
      'version', document_row.version,
      'snapshot_hash', document_row.snapshot_hash,
      'is_demo', document_row.is_demo
    )
  );

  return document_row;
end;
$$;


ALTER FUNCTION "public"."branch_manager_issue_official_document"("p_owner_id" "uuid", "p_account_id" "uuid", "p_transfer_id" "uuid", "p_loan_id" "uuid", "p_document_type" "text", "p_title" "text", "p_language" "text", "p_period_start" "date", "p_period_end" "date", "p_idempotency_key" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."branch_manager_reject_loan"("p_loan_id" "uuid", "p_reason" "text") RETURNS "public"."loan_applications"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_id uuid := private.ensure_branch_manager();
  loan_row public.loan_applications;
  old_status text;
  normalized_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  if normalized_reason is null then
    raise exception 'REJECTION_REASON_REQUIRED' using errcode = '22023';
  end if;

  select *
  into loan_row
  from public.loan_applications
  where id = p_loan_id
  for update;

  if not found then
    raise exception 'LOAN_NOT_FOUND' using errcode = 'P0002';
  end if;

  if loan_row.status not in (
    'submitted',
    'under_review',
    'approved_for_external_funding'
  ) then
    raise exception 'LOAN_CANNOT_BE_REJECTED' using errcode = '55000';
  end if;

  old_status := loan_row.status;

  update public.loan_applications
  set status = 'rejected'
  where id = p_loan_id
  returning * into loan_row;

  insert into public.loan_events (
    loan_id, actor_id, event_type, from_status, to_status, reason
  )
  values (
    p_loan_id,
    caller_id,
    'branch_manager_rejected',
    old_status,
    loan_row.status,
    normalized_reason
  );

  insert into public.audit_events (
    actor_id, action, entity_type, entity_id, metadata
  )
  values (
    caller_id,
    'branch_manager_reject_loan',
    'loan_application',
    p_loan_id,
    jsonb_build_object('from_status', old_status, 'to_status', loan_row.status)
  );

  insert into public.notifications (
    recipient_id, title, message, notification_type
  )
  values (
    loan_row.owner_id,
    'Prêt refusé',
    'Votre demande de prêt a été refusée.',
    'loan'
  );

  return loan_row;
end;
$$;


ALTER FUNCTION "public"."branch_manager_reject_loan"("p_loan_id" "uuid", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."branch_manager_reject_transfer"("p_transfer_id" "uuid", "p_reason" "text") RETURNS "public"."transfer_intents"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_id uuid := private.ensure_branch_manager();
  transfer_row public.transfer_intents;
  old_status text;
  normalized_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  if normalized_reason is null then
    raise exception 'REJECTION_REASON_REQUIRED' using errcode = '22023';
  end if;

  select *
  into transfer_row
  from public.transfer_intents
  where id = p_transfer_id
  for update;

  if not found then
    raise exception 'TRANSFER_NOT_FOUND' using errcode = 'P0002';
  end if;

  if transfer_row.status not in (
    'submitted',
    'under_review',
    'approved_for_external_execution'
  ) then
    raise exception 'TRANSFER_CANNOT_BE_REJECTED' using errcode = '55000';
  end if;

  old_status := transfer_row.status;

  update public.financial_positions
  set reserved_minor = reserved_minor - transfer_row.amount_minor
  where id = transfer_row.source_position_id
    and reserved_minor >= transfer_row.amount_minor;

  if not found then
    raise exception 'TRANSFER_RESERVATION_CONFLICT' using errcode = '55000';
  end if;

  update public.transfer_intents
  set status = 'rejected'
  where id = p_transfer_id
  returning * into transfer_row;

  insert into public.transfer_events (
    transfer_id, actor_id, event_type, from_status, to_status, reason
  )
  values (
    p_transfer_id,
    caller_id,
    'branch_manager_rejected',
    old_status,
    transfer_row.status,
    normalized_reason
  );

  insert into public.audit_events (
    actor_id, action, entity_type, entity_id, metadata
  )
  values (
    caller_id,
    'branch_manager_reject_transfer',
    'transfer_intent',
    p_transfer_id,
    jsonb_build_object('from_status', old_status, 'to_status', transfer_row.status)
  );

  insert into public.notifications (
    recipient_id, title, message, notification_type
  )
  values (
    transfer_row.owner_id,
    'Virement refusé',
    'Votre demande de virement a été refusée.',
    'transfer'
  );

  return transfer_row;
end;
$$;


ALTER FUNCTION "public"."branch_manager_reject_transfer"("p_transfer_id" "uuid", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."branch_manager_review_transfer_check"("p_transfer_id" "uuid", "p_check_kind" "text", "p_note" "text" DEFAULT NULL::"text") RETURNS "public"."transfer_intents"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  transfer_row public.transfer_intents;
  check_row public.transfer_review_checks;
  caller_id uuid := private.ensure_branch_manager();
  normalized_note text := nullif(trim(coalesce(p_note, '')), '');
  expected_kind text;
  old_status text;
begin
  if p_check_kind not in ('dual_review', 'escalation', 'compliance', 'final_authorization') then
    raise exception 'INVALID_REVIEW_CHECK' using errcode = '22023';
  end if;

  select * into transfer_row
  from public.transfer_intents where id = p_transfer_id for update;
  if not found then
    raise exception 'TRANSFER_NOT_FOUND' using errcode = 'P0002';
  end if;
  if transfer_row.status in ('external_settlement_confirmed', 'rejected', 'cancelled', 'external_failed') then
    return transfer_row;
  end if;
  if transfer_row.status not in ('submitted', 'under_review') then
    raise exception 'TRANSFER_NOT_REVIEWABLE' using errcode = '55000';
  end if;

  select * into check_row
  from public.transfer_review_checks
  where transfer_id = p_transfer_id and check_kind = p_check_kind
  for update;
  if not found then
    raise exception 'TRANSFER_REVIEW_CHECK_NOT_FOUND' using errcode = 'P0002';
  end if;
  if check_row.status = 'completed' then
    return transfer_row;
  end if;

  expected_kind := case
    when not exists (select 1 from public.transfer_review_checks where transfer_id = p_transfer_id and check_kind = 'dual_review' and status = 'completed') then 'dual_review'
    when not exists (select 1 from public.transfer_review_checks where transfer_id = p_transfer_id and check_kind = 'escalation' and status = 'completed') then 'escalation'
    when not exists (select 1 from public.transfer_review_checks where transfer_id = p_transfer_id and check_kind = 'compliance' and status = 'completed') then 'compliance'
    else 'final_authorization'
  end;
  if p_check_kind <> expected_kind then
    raise exception 'TRANSFER_REVIEW_CHECK_OUT_OF_ORDER' using errcode = '55000';
  end if;

  old_status := transfer_row.status;

  update public.transfer_review_checks
  set status = 'completed', reviewer_id = caller_id, reviewed_at = now(),
      note = normalized_note
  where id = check_row.id;

  update public.transfer_intents set status = 'under_review'
  where id = p_transfer_id returning * into transfer_row;

  insert into public.transfer_events (
    transfer_id, actor_id, event_type, from_status, to_status, reason, metadata
  ) values (
    p_transfer_id, caller_id, 'review_check_updated', old_status,
    transfer_row.status, normalized_note,
    jsonb_build_object('check_kind', p_check_kind, 'check_status', 'completed')
  );

  if p_check_kind = 'final_authorization' then
    return public.branch_manager_finalize_transfer(p_transfer_id, normalized_note);
  end if;
  return transfer_row;
end;
$$;


ALTER FUNCTION "public"."branch_manager_review_transfer_check"("p_transfer_id" "uuid", "p_check_kind" "text", "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."branch_manager_revoke_official_document"("p_document_id" "uuid", "p_reason" "text") RETURNS "public"."official_documents"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_id uuid := private.ensure_branch_manager();
  document_row public.official_documents;
  normalized_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  if normalized_reason is null then
    raise exception 'DOCUMENT_REVOCATION_REASON_REQUIRED'
      using errcode = '22023';
  end if;

  select *
  into document_row
  from public.official_documents
  where id = p_document_id
  for update;

  if not found then
    raise exception 'OFFICIAL_DOCUMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  if document_row.status <> 'issued' then
    raise exception 'OFFICIAL_DOCUMENT_NOT_REVOCABLE'
      using errcode = '55000';
  end if;

  update public.official_documents
  set
    status = 'revoked',
    revoked_by = caller_id,
    revoked_at = now(),
    revocation_reason = normalized_reason
  where id = p_document_id
  returning * into document_row;

  insert into public.audit_events (
    actor_id,
    action,
    entity_type,
    entity_id,
    metadata
  )
  values (
    caller_id,
    'branch_manager_revoke_official_document',
    'official_document',
    document_row.id,
    jsonb_build_object(
      'document_number', document_row.document_number,
      'reason', normalized_reason
    )
  );

  return document_row;
end;
$$;


ALTER FUNCTION "public"."branch_manager_revoke_official_document"("p_document_id" "uuid", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."claim_support_transcript"("p_transcript_id" "uuid", "p_claim_token" "uuid") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  worker_role text := coalesce((select auth.jwt() ->> 'role'), '');
  claimed_count integer;
begin
  if worker_role <> 'service_role' then
    raise exception 'SUPPORT_WORKER_PERMISSION_REQUIRED' using errcode = '42501';
  end if;

  if p_transcript_id is null or p_claim_token is null then
    raise exception 'INVALID_SUPPORT_TRANSCRIPT_CLAIM' using errcode = '22023';
  end if;

  update public.support_transcripts
  set
    processing_token = p_claim_token,
    processing_started_at = now()
  where id = p_transcript_id
    and completed_at is null
    and (
      processing_token is null
      or processing_started_at < now() - interval '5 minutes'
    );

  get diagnostics claimed_count = row_count;
  return claimed_count = 1;
end;
$$;


ALTER FUNCTION "public"."claim_support_transcript"("p_transcript_id" "uuid", "p_claim_token" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."claim_transactional_emails"("p_limit" integer DEFAULT 10) RETURNS SETOF "public"."transactional_email_outbox"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select *
  from private.claim_transactional_emails_internal(p_limit, null);
$$;


ALTER FUNCTION "public"."claim_transactional_emails"("p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."claim_transactional_emails_for_recipient"("p_recipient_id" "uuid", "p_limit" integer DEFAULT 10) RETURNS SETOF "public"."transactional_email_outbox"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  if p_recipient_id is null then
    raise exception 'EMAIL_RECIPIENT_REQUIRED' using errcode = '22023';
  end if;

  return query
  select *
  from private.claim_transactional_emails_internal(p_limit, p_recipient_id);
end;
$$;


ALTER FUNCTION "public"."claim_transactional_emails_for_recipient"("p_recipient_id" "uuid", "p_limit" integer) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."claim_transactional_emails_for_recipient"("p_recipient_id" "uuid", "p_limit" integer) IS 'Atomically claims due transactional emails for one authenticated workflow owner.';



CREATE OR REPLACE FUNCTION "public"."complete_official_document"("p_document_id" "uuid", "p_storage_path" "text", "p_content_hash" "text", "p_succeeded" boolean, "p_error" "text") RETURNS "public"."official_documents"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  worker_role text := coalesce((select auth.jwt() ->> 'role'), '');
  document_row public.official_documents;
  normalized_path text := nullif(trim(coalesce(p_storage_path, '')), '');
  normalized_hash text := lower(trim(coalesce(p_content_hash, '')));
  normalized_error text := nullif(trim(coalesce(p_error, '')), '');
begin
  if worker_role <> 'service_role' then
    raise exception 'OFFICIAL_DOCUMENT_WORKER_PERMISSION_REQUIRED'
      using errcode = '42501';
  end if;

  select *
  into document_row
  from public.official_documents
  where id = p_document_id
  for update;

  if not found then
    raise exception 'OFFICIAL_DOCUMENT_NOT_FOUND' using errcode = 'P0002';
  end if;

  if document_row.status = 'issued'
     and p_succeeded
     and document_row.storage_path = normalized_path
     and document_row.content_hash = normalized_hash then
    return document_row;
  end if;

  if document_row.status not in ('pending', 'failed') then
    raise exception 'OFFICIAL_DOCUMENT_NOT_COMPLETABLE'
      using errcode = '55000';
  end if;

  if p_succeeded then
    if normalized_path is null
       or normalized_hash !~ '^[a-f0-9]{64}$'
       or normalized_path !~ '\.pdf$'
       or normalized_path not like document_row.owner_id::text || '/%'
       or normalized_path ~ '(^|/)\.\.(/|$)' then
      raise exception 'INVALID_OFFICIAL_DOCUMENT_ARTIFACT'
        using errcode = '22023';
    end if;

    update public.official_documents
    set
      status = 'issued',
      storage_path = normalized_path,
      content_hash = normalized_hash,
      issued_at = now(),
      failure_reason = null
    where id = p_document_id
    returning * into document_row;

    insert into public.notifications (
      recipient_id,
      title,
      message,
      notification_type
    )
    values (
      document_row.owner_id,
      'Document officiel disponible',
      'Votre document officiel Monalyz est disponible dans votre espace.',
      'info'
    );
  else
    if normalized_error is null then
      raise exception 'OFFICIAL_DOCUMENT_ERROR_REQUIRED'
        using errcode = '22023';
    end if;

    update public.official_documents
    set
      status = 'failed',
      storage_path = null,
      content_hash = null,
      issued_at = null,
      failure_reason = left(normalized_error, 1000)
    where id = p_document_id
    returning * into document_row;
  end if;

  insert into public.audit_events (
    actor_id,
    action,
    entity_type,
    entity_id,
    metadata
  )
  values (
    null,
    case
      when p_succeeded then 'complete_official_document'
      else 'fail_official_document'
    end,
    'official_document',
    document_row.id,
    jsonb_build_object(
      'status', document_row.status,
      'content_hash', document_row.content_hash,
      'storage_path', document_row.storage_path
    )
  );

  return document_row;
end;
$_$;


ALTER FUNCTION "public"."complete_official_document"("p_document_id" "uuid", "p_storage_path" "text", "p_content_hash" "text", "p_succeeded" boolean, "p_error" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."complete_transactional_email"("p_email_id" "uuid", "p_claim_token" "uuid", "p_succeeded" boolean, "p_provider_message_id" "text" DEFAULT NULL::"text", "p_error" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  worker_role text := coalesce((select auth.jwt() ->> 'role'), '');
  email_row public.transactional_email_outbox;
begin
  if worker_role <> 'service_role' then
    raise exception 'EMAIL_WORKER_PERMISSION_REQUIRED' using errcode = '42501';
  end if;

  select *
  into email_row
  from public.transactional_email_outbox
  where id = p_email_id
  for update;

  if not found
     or email_row.claim_token is distinct from p_claim_token
     or email_row.status <> 'sending' then
    raise exception 'EMAIL_CLAIM_NOT_FOUND' using errcode = '42501';
  end if;

  if p_succeeded then
    update public.transactional_email_outbox
    set
      status = 'sent',
      provider_message_id = nullif(trim(coalesce(p_provider_message_id, '')), ''),
      last_error = null,
      claim_token = null,
      sent_at = now()
    where id = p_email_id;
  else
    update public.transactional_email_outbox
    set
      status = case when attempts >= 5 then 'failed' else 'pending' end,
      provider_message_id = null,
      last_error = left(coalesce(p_error, 'Échec d’envoi non détaillé.'), 1000),
      claim_token = null,
      sent_at = null
    where id = p_email_id;
  end if;
end;
$$;


ALTER FUNCTION "public"."complete_transactional_email"("p_email_id" "uuid", "p_claim_token" "uuid", "p_succeeded" boolean, "p_provider_message_id" "text", "p_error" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_official_document_localized_reissue"("p_source_document_id" "uuid", "p_idempotency_key" "uuid") RETURNS "public"."official_documents"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  worker_role text := coalesce((select auth.jwt() ->> 'role'), '');
  source_row public.official_documents;
  replacement_row public.official_documents;
  replacement_id uuid := gen_random_uuid();
  replacement_title text;
  replacement_snapshot jsonb;
  replacement_version integer;
begin
  if worker_role <> 'service_role' then
    raise exception 'OFFICIAL_DOCUMENT_WORKER_PERMISSION_REQUIRED' using errcode = '42501';
  end if;

  select * into replacement_row from public.official_documents
  where supersedes_document_id = p_source_document_id;
  if found then return replacement_row; end if;

  select * into source_row from public.official_documents
  where id = p_source_document_id for update;
  if not found then raise exception 'OFFICIAL_DOCUMENT_NOT_FOUND' using errcode = 'P0002'; end if;
  if source_row.status <> 'issued' or source_row.localization_revision >= 2 then
    raise exception 'OFFICIAL_DOCUMENT_NOT_REISSUABLE' using errcode = '55000';
  end if;

  replacement_title := case source_row.language
    when 'en' then case source_row.document_type when 'bank_details' then 'Bank account details' when 'account_statement' then 'Account statement' when 'balance_certificate' then 'Balance certificate' when 'transfer_confirmation' then 'Transfer confirmation' when 'loan_disbursement_confirmation' then 'Loan disbursement confirmation' else 'Loan decision' end
    when 'de' then case source_row.document_type when 'bank_details' then 'Bankverbindung' when 'account_statement' then 'Kontoauszug' when 'balance_certificate' then 'Saldenbestätigung' when 'transfer_confirmation' then 'Überweisungsbestätigung' when 'loan_disbursement_confirmation' then 'Bestätigung der Kreditauszahlung' else 'Kreditentscheidung' end
    when 'es' then case source_row.document_type when 'bank_details' then 'Datos bancarios' when 'account_statement' then 'Estado de cuenta' when 'balance_certificate' then 'Certificado de saldo' when 'transfer_confirmation' then 'Confirmación de transferencia' when 'loan_disbursement_confirmation' then 'Confirmación de desembolso del préstamo' else 'Decisión de préstamo' end
    else case source_row.document_type when 'bank_details' then 'Relevé d’identité bancaire' when 'account_statement' then 'Relevé de compte' when 'balance_certificate' then 'Attestation de solde' when 'transfer_confirmation' then 'Confirmation de virement' when 'loan_disbursement_confirmation' then 'Confirmation de versement du prêt' else 'Décision de prêt' end
  end;
  replacement_snapshot := source_row.snapshot || jsonb_build_object(
    'schemaVersion', 2, 'title', replacement_title, 'language', source_row.language
  );
  select coalesce(max(version), 0) + 1 into replacement_version
  from public.official_documents
  where owner_id = source_row.owner_id
    and document_type = source_row.document_type
    and account_id is not distinct from source_row.account_id
    and transfer_id is not distinct from source_row.transfer_id
    and loan_id is not distinct from source_row.loan_id;

  insert into public.official_documents (
    id, owner_id, account_id, transfer_id, loan_id, document_number,
    document_type, title, language, period_start, period_end, version, status,
    snapshot, snapshot_hash, issued_by, is_demo, idempotency_key,
    localization_revision, supersedes_document_id
  ) values (
    replacement_id, source_row.owner_id, source_row.account_id, source_row.transfer_id,
    source_row.loan_id, 'MON-' || to_char(now(), 'YYYY') || '-' || upper(replace(replacement_id::text, '-', '')),
    source_row.document_type, replacement_title, source_row.language,
    source_row.period_start, source_row.period_end, replacement_version, 'pending',
    replacement_snapshot,
    encode(extensions.digest(convert_to(replacement_snapshot::text, 'UTF8'), 'sha256'), 'hex'),
    source_row.issued_by, source_row.is_demo, p_idempotency_key, 2, source_row.id
  ) returning * into replacement_row;

  insert into public.audit_events (actor_id, action, entity_type, entity_id, metadata)
  values (
    source_row.issued_by, 'official_document_localization_reissue_created', 'official_document', replacement_row.id,
    jsonb_build_object('supersedes_document_id', source_row.id, 'localization_revision', 2)
  );
  return replacement_row;
end;
$$;


ALTER FUNCTION "public"."create_official_document_localized_reissue"("p_source_document_id" "uuid", "p_idempotency_key" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."current_app_role"() RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
  select coalesce(
    (
      select case when active then role else 'user' end
      from public.staff_members
      where user_id = (select auth.uid())
    ),
    'user'
  );
$$;


ALTER FUNCTION "public"."current_app_role"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."decide_kyc_application"("p_kyc_id" "uuid", "p_decision" "text", "p_reason_code" "text", "p_note" "text") RETURNS "public"."kyc_applications"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_id uuid := (select auth.uid());
  kyc_row public.kyc_applications;
  checklist_row public.kyc_review_checklists;
  profile_row public.profiles;
  account_row public.financial_positions;
  internal_number text;
begin
  if caller_id is null
     or not private.is_active_staff(array['reviewer', 'supervisor', 'admin']) then
    raise exception 'STAFF_PERMISSION_REQUIRED' using errcode = '42501';
  end if;
  if p_decision not in ('approved', 'rejected') then
    raise exception 'INVALID_KYC_DECISION' using errcode = '22023';
  end if;

  select * into kyc_row
  from public.kyc_applications
  where id = p_kyc_id
  for update;
  if not found or kyc_row.status <> 'under_review' then
    raise exception 'KYC_NOT_UNDER_REVIEW' using errcode = '55000';
  end if;

  select * into checklist_row
  from public.kyc_review_checklists
  where kyc_id = p_kyc_id;
  if not found then
    raise exception 'KYC_CHECKLIST_INCOMPLETE' using errcode = '22023';
  end if;
  if (
       not (kyc_row.document_object_paths ? 'selfie')
       and checklist_row.selfie_match <> 'not_applicable'
     )
     or (
       kyc_row.document_object_paths ? 'selfie'
       and checklist_row.selfie_match = 'not_applicable'
     ) then
    raise exception 'INVALID_KYC_SELFIE_REVIEW_STATE' using errcode = '23514';
  end if;
  if 'pending' in (
    checklist_row.document_quality,
    checklist_row.data_consistency,
    checklist_row.selfie_match,
    checklist_row.adulthood,
    checklist_row.fatca,
    checklist_row.pep
  ) then
    raise exception 'KYC_CHECKLIST_INCOMPLETE' using errcode = '22023';
  end if;

  if p_reason_code = 'selfie_mismatch' then
    raise exception 'INVALID_KYC_DECISION_REASON' using errcode = '22023';
  end if;
  if p_decision = 'rejected' and not ('non_compliant' in (
    checklist_row.document_quality,
    checklist_row.data_consistency,
    checklist_row.adulthood,
    checklist_row.fatca,
    checklist_row.pep
  )) then
    raise exception 'KYC_REJECTION_REQUIRES_MANDATORY_FAILURE'
      using errcode = '23514';
  end if;

  if p_decision = 'approved' and 'non_compliant' in (
    checklist_row.document_quality,
    checklist_row.data_consistency,
    checklist_row.adulthood,
    checklist_row.fatca,
    checklist_row.pep
  ) then
    raise exception 'KYC_CHECKLIST_NOT_COMPLIANT' using errcode = '23514';
  end if;
  if p_decision = 'rejected'
     and nullif(trim(coalesce(p_note, '')), '') is null then
    raise exception 'KYC_REJECTION_REASON_REQUIRED' using errcode = '22023';
  end if;

  if p_decision = 'approved' then
    select * into profile_row
    from public.profiles
    where user_id = kyc_row.owner_id;

    select * into account_row
    from public.financial_positions
    where source_kyc_id = p_kyc_id;

    if not found then
      internal_number := private.allocate_internal_account_number();
      insert into public.financial_positions (
        owner_id,
        label,
        position_kind,
        currency,
        amount_minor,
        reserved_minor,
        as_of,
        external_identifier_masked,
        account_type,
        account_number,
        account_holder_name,
        account_status,
        opened_at,
        declared_by,
        is_demo,
        declaration_idempotency_key,
        source_kyc_id
      )
      values (
        kyc_row.owner_id,
        'Compte courant',
        'internally_reconciled',
        profile_row.base_currency,
        0,
        0,
        now(),
        '••••' || right(internal_number, 4),
        'current',
        internal_number,
        trim(kyc_row.first_name || ' ' || kyc_row.last_name),
        'active',
        now(),
        caller_id,
        false,
        p_kyc_id,
        p_kyc_id
      )
      returning * into account_row;

      insert into public.financial_ledger_entries (
        account_id,
        owner_id,
        sequence_no,
        entry_key,
        entry_kind,
        amount_minor,
        currency,
        balance_before_minor,
        balance_after_minor,
        value_date,
        internal_reference,
        booked_by,
        description,
        metadata
      )
      values (
        account_row.id,
        account_row.owner_id,
        1,
        'kyc-account-opening:' || p_kyc_id::text,
        'account_opening',
        0,
        account_row.currency,
        0,
        0,
        now(),
        'KYC-ACCOUNT-' || upper(replace(p_kyc_id::text, '-', '')),
        caller_id,
        'Ouverture automatique après approbation KYC',
        jsonb_build_object('kyc_id', p_kyc_id)
      );
    end if;
  end if;

  update public.kyc_applications
  set
    status = p_decision,
    reviewed_by = caller_id,
    reviewed_at = now(),
    review_note = nullif(trim(coalesce(p_note, '')), ''),
    requested_items = case
      when p_decision = 'rejected'
        then array[
          'identity', 'birth', 'address', 'profile', 'document_metadata',
          'id_front', 'id_back', 'proof_of_address'
        ]::text[]
      else '{}'
    end,
    correction_reason_code = case
      when p_decision = 'rejected' then coalesce(p_reason_code, 'other')
      else null
    end,
    correction_due_at = null
  where id = p_kyc_id
  returning * into kyc_row;

  insert into public.kyc_events (
    kyc_id, actor_id, event_type, from_status, to_status, reason
  )
  values (
    p_kyc_id,
    caller_id,
    'decided',
    'under_review',
    p_decision,
    nullif(trim(coalesce(p_note, '')), '')
  );

  insert into public.audit_events (
    actor_id, action, entity_type, entity_id, metadata
  )
  values (
    caller_id,
    'decide_kyc',
    'kyc_application',
    p_kyc_id,
    jsonb_build_object(
      'decision', p_decision,
      'account_id', account_row.id,
      'account_number', account_row.account_number
    )
  );

  return kyc_row;
end;
$$;


ALTER FUNCTION "public"."decide_kyc_application"("p_kyc_id" "uuid", "p_decision" "text", "p_reason_code" "text", "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."finalize_official_document_localized_reissue"("p_replacement_document_id" "uuid") RETURNS "public"."official_documents"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  worker_role text := coalesce((select auth.jwt() ->> 'role'), '');
  replacement_row public.official_documents;
  source_row public.official_documents;
begin
  if worker_role <> 'service_role' then
    raise exception 'OFFICIAL_DOCUMENT_WORKER_PERMISSION_REQUIRED' using errcode = '42501';
  end if;
  select * into replacement_row from public.official_documents
  where id = p_replacement_document_id for update;
  if not found or replacement_row.supersedes_document_id is null or replacement_row.status <> 'issued' then
    raise exception 'OFFICIAL_DOCUMENT_REISSUE_NOT_FINALIZABLE' using errcode = '55000';
  end if;
  select * into source_row from public.official_documents
  where id = replacement_row.supersedes_document_id for update;
  if source_row.status = 'revoked' then return source_row; end if;
  if source_row.status <> 'issued' then
    raise exception 'OFFICIAL_DOCUMENT_SOURCE_NOT_ISSUED' using errcode = '55000';
  end if;
  update public.official_documents set
    status = 'revoked', revoked_by = source_row.issued_by, revoked_at = now(),
    revocation_reason = 'Remplacé par une version localisée vérifiée.'
  where id = source_row.id returning * into source_row;
  insert into public.audit_events (actor_id, action, entity_type, entity_id, metadata)
  values (
    source_row.issued_by, 'official_document_localization_reissue_finalized', 'official_document', source_row.id,
    jsonb_build_object('replacement_document_id', replacement_row.id, 'replacement_content_hash', replacement_row.content_hash)
  );
  return source_row;
end;
$$;


ALTER FUNCTION "public"."finalize_official_document_localized_reissue"("p_replacement_document_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_account_number_configuration"() RETURNS TABLE("prefix" "text", "prefix_length" integer, "capacity" integer, "updated_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
begin
  perform private.ensure_branch_manager();

  return query
  select
    configuration.prefix,
    char_length(configuration.prefix)::integer,
    power(
      10::numeric,
      10 - char_length(configuration.prefix)
    )::integer,
    configuration.updated_at
  from private.account_number_configuration as configuration
  where configuration.singleton;
end;
$$;


ALTER FUNCTION "public"."get_account_number_configuration"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."mark_notification_read"("p_notification_id" "uuid") RETURNS "void"
    LANGUAGE "sql"
    SET "search_path" TO ''
    AS $$
  update public.notifications
  set read_at = coalesce(read_at, now())
  where id = p_notification_id
    and recipient_id = (select auth.uid());
$$;


ALTER FUNCTION "public"."mark_notification_read"("p_notification_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."provision_demo_accounts"("p_admin_user_id" "uuid", "p_client_user_id" "uuid", "p_environment" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  demo_kyc_id constant uuid := uuid 'd3000000-0000-4000-8000-000000000001';
  demo_kyc_idempotency_key constant uuid := uuid 'd3000000-0000-4000-8000-000000000002';
  demo_position_id constant uuid := uuid 'd3000000-0000-4000-8000-000000000003';
  admin_email text;
  client_email text;
  admin_app_metadata jsonb;
  client_app_metadata jsonb;
  demo_user_count integer;
  active_admin_count integer;
  client_staff_count integer;
  approved_kyc_count integer;
  current_position_count integer;
  audit_count integer;
begin
  if (select auth.jwt() ->> 'role') is distinct from 'service_role' then
    raise exception 'SERVICE_ROLE_REQUIRED' using errcode = '42501';
  end if;

  if p_admin_user_id is null
     or p_client_user_id is null
     or p_admin_user_id = p_client_user_id then
    raise exception 'INVALID_DEMO_USER_IDS' using errcode = '22023';
  end if;

  if p_environment not in ('local', 'remote') then
    raise exception 'INVALID_DEMO_ENVIRONMENT' using errcode = '22023';
  end if;

  -- Serialize provisioners so the read-before-insert audit guards remain
  -- deterministic even when two operators start the command concurrently.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('monalyz:provision-demo-accounts', 0)
  );

  select
    lower(coalesce(email, '')),
    coalesce(raw_app_meta_data, '{}'::jsonb)
  into admin_email, admin_app_metadata
  from auth.users
  where id = p_admin_user_id;

  if not found
     or admin_email = ''
     or admin_app_metadata ->> 'monalyz_demo' <> 'true'
     or admin_app_metadata ->> 'demo_role' <> 'admin' then
    raise exception 'INVALID_DEMO_ADMIN_IDENTITY' using errcode = '22023';
  end if;

  select
    lower(coalesce(email, '')),
    coalesce(raw_app_meta_data, '{}'::jsonb)
  into client_email, client_app_metadata
  from auth.users
  where id = p_client_user_id;

  if not found
     or client_email <> 'client.demo@monalyz.com'
     or client_app_metadata ->> 'monalyz_demo' <> 'true'
     or client_app_metadata ->> 'demo_role' <> 'client' then
    raise exception 'INVALID_DEMO_CLIENT_IDENTITY' using errcode = '22023';
  end if;

  if exists (
    select 1
    from public.financial_positions
    where owner_id = p_admin_user_id
  ) or exists (
    select 1
    from public.kyc_applications
    where owner_id = p_admin_user_id
  ) then
    raise exception 'DEMO_ADMIN_MUST_NOT_HAVE_CLIENT_FIXTURES'
      using errcode = '23514';
  end if;

  if exists (
    select 1
    from public.transfer_intents
    where owner_id = p_client_user_id
  ) or exists (
    select 1
    from public.loan_applications
    where owner_id = p_client_user_id
  ) or exists (
    select 1
    from public.external_transfer_executions execution
    join public.transfer_intents transfer
      on transfer.id = execution.transfer_id
    where transfer.owner_id = p_client_user_id
  ) or exists (
    select 1
    from public.external_loan_fundings funding
    join public.loan_applications loan
      on loan.id = funding.loan_id
    where loan.owner_id = p_client_user_id
  ) then
    raise exception 'DEMO_CLIENT_FINANCIAL_WORKFLOW_MUST_BE_EMPTY'
      using errcode = '23514';
  end if;

  if exists (
    select 1
    from public.financial_positions
    where id = demo_position_id
      and (
        owner_id <> p_client_user_id
        or label <> 'Compte courant démo'
        or external_identifier_masked is not null
      )
  ) or exists (
    select 1
    from public.financial_positions
    where owner_id = p_client_user_id
      and id <> demo_position_id
  ) then
    raise exception 'DEMO_POSITION_ID_COLLISION' using errcode = '23505';
  end if;

  if exists (
    select 1
    from public.kyc_applications
    where id = demo_kyc_id
      and (
        owner_id <> p_client_user_id
        or idempotency_key <> demo_kyc_idempotency_key
        or address ->> 'monalyz_demo' is distinct from 'true'
      )
  ) or exists (
    select 1
    from public.kyc_applications
    where owner_id = p_client_user_id
      and id <> demo_kyc_id
  ) then
    raise exception 'DEMO_KYC_ID_COLLISION' using errcode = '23505';
  end if;

  if exists (
    select 1
    from public.kyc_events
    where kyc_id = demo_kyc_id
      and actor_id = p_admin_user_id
      and event_type = 'demo_approved'
      and reason is distinct from
        'Dossier synthétique Monalyz; aucune vérification réelle.'
  ) then
    raise exception 'DEMO_KYC_EVENT_COLLISION' using errcode = '23505';
  end if;

  if exists (
    select 1
    from public.audit_events existing
    where existing.actor_id = p_admin_user_id
      and (
        (
          existing.action = 'demo_admin_account_provisioned'
          and existing.entity_type = 'profile'
          and existing.entity_id = p_admin_user_id
        )
        or (
          existing.action = 'demo_client_account_provisioned'
          and existing.entity_type = 'profile'
          and existing.entity_id = p_client_user_id
        )
        or (
          existing.action = 'demo_kyc_provisioned'
          and existing.entity_type = 'kyc_application'
          and existing.entity_id = demo_kyc_id
        )
        or (
          existing.action = 'demo_financial_position_provisioned'
          and existing.entity_type = 'financial_position'
          and existing.entity_id = demo_position_id
        )
      )
      and (
        existing.metadata ->> 'source' is distinct from 'demo_provisioner'
        or existing.metadata ->> 'demo' is distinct from 'true'
        or existing.metadata ->> 'synthetic' is distinct from 'true'
      )
  ) then
    raise exception 'DEMO_AUDIT_EVENT_COLLISION' using errcode = '23505';
  end if;

  insert into public.profiles (
    user_id,
    email,
    display_name,
    preferred_currency,
    preferred_language,
    access_status,
    access_status_reason
  )
  values
    (
      p_admin_user_id,
      admin_email,
      'Administrateur Démo Monalyz',
      'EUR',
      'fr',
      'active',
      null
    ),
    (
      p_client_user_id,
      'client.demo@monalyz.com',
      'Client Démo Monalyz',
      'EUR',
      'fr',
      'active',
      null
    )
  on conflict (user_id) do update
  set
    email = excluded.email,
    display_name = excluded.display_name,
    preferred_currency = excluded.preferred_currency,
    preferred_language = excluded.preferred_language,
    access_status = excluded.access_status,
    access_status_reason = null;

  insert into public.staff_members (user_id, role, active)
  values (p_admin_user_id, 'admin', true)
  on conflict (user_id) do update
  set role = excluded.role, active = excluded.active;

  delete from public.staff_members
  where user_id = p_client_user_id;

  insert into public.kyc_applications (
    id,
    owner_id,
    idempotency_key,
    first_name,
    last_name,
    date_of_birth,
    place_of_birth,
    nationality,
    address,
    occupation,
    income_range,
    fatca,
    pep,
    document_object_paths,
    status,
    reviewed_at,
    reviewed_by,
    review_note
  )
  values (
    demo_kyc_id,
    p_client_user_id,
    demo_kyc_idempotency_key,
    'Client',
    'Démo Monalyz',
    date '1990-01-01',
    'Donnée synthétique',
    'Donnée synthétique',
    jsonb_build_object(
      'street', 'Adresse synthétique — aucune adresse réelle',
      'postalCode', '00000',
      'city', 'Démonstration',
      'country', 'FR',
      'monalyz_demo', true
    ),
    'Compte de démonstration',
    'Donnée synthétique',
    false,
    false,
    '{}'::jsonb,
    'approved',
    timestamptz '2026-01-01 00:00:00+00',
    p_admin_user_id,
    'DOSSIER SYNTHÉTIQUE MONALYZ — aucune identité ni pièce réelle.'
  )
  on conflict (id) do update
  set
    owner_id = excluded.owner_id,
    idempotency_key = excluded.idempotency_key,
    first_name = excluded.first_name,
    last_name = excluded.last_name,
    date_of_birth = excluded.date_of_birth,
    place_of_birth = excluded.place_of_birth,
    nationality = excluded.nationality,
    address = excluded.address,
    occupation = excluded.occupation,
    income_range = excluded.income_range,
    fatca = excluded.fatca,
    pep = excluded.pep,
    document_object_paths = excluded.document_object_paths,
    status = excluded.status,
    reviewed_at = excluded.reviewed_at,
    reviewed_by = excluded.reviewed_by,
    review_note = excluded.review_note;

  insert into public.kyc_events (
    kyc_id,
    actor_id,
    event_type,
    from_status,
    to_status,
    reason
  )
  select
    demo_kyc_id,
    p_admin_user_id,
    'demo_approved',
    null,
    'approved',
    'Dossier synthétique Monalyz; aucune vérification réelle.'
  where not exists (
    select 1
    from public.kyc_events
    where kyc_id = demo_kyc_id
      and actor_id = p_admin_user_id
      and event_type = 'demo_approved'
  );

  insert into public.financial_positions (
    id,
    owner_id,
    label,
    position_kind,
    account_type,
    currency,
    amount_minor,
    reserved_minor,
    as_of,
    external_identifier_masked
  )
  values (
    demo_position_id,
    p_client_user_id,
    'Compte courant démo',
    'declared',
    'current',
    'EUR',
    2500000,
    0,
    timestamptz '2026-01-01 00:00:00+00',
    null
  )
  on conflict (id) do update
  set
    owner_id = excluded.owner_id,
    label = excluded.label,
    position_kind = excluded.position_kind,
    account_type = excluded.account_type,
    currency = excluded.currency,
    amount_minor = excluded.amount_minor,
    reserved_minor = excluded.reserved_minor,
    as_of = excluded.as_of,
    external_identifier_masked = null;

  insert into public.audit_events (
    actor_id,
    action,
    entity_type,
    entity_id,
    metadata
  )
  select
    event.actor_id,
    event.action,
    event.entity_type,
    event.entity_id,
    jsonb_build_object(
      'demo', true,
      'synthetic', true,
      'source', 'demo_provisioner',
      'environment', p_environment
    )
  from (
    values
      (
        p_admin_user_id,
        'demo_admin_account_provisioned'::text,
        'profile'::text,
        p_admin_user_id
      ),
      (
        p_admin_user_id,
        'demo_client_account_provisioned'::text,
        'profile'::text,
        p_client_user_id
      ),
      (
        p_admin_user_id,
        'demo_kyc_provisioned'::text,
        'kyc_application'::text,
        demo_kyc_id
      ),
      (
        p_admin_user_id,
        'demo_financial_position_provisioned'::text,
        'financial_position'::text,
        demo_position_id
      )
  ) as event(actor_id, action, entity_type, entity_id)
  where not exists (
    select 1
    from public.audit_events existing
    where existing.actor_id = event.actor_id
      and existing.action = event.action
      and existing.entity_type = event.entity_type
      and existing.entity_id = event.entity_id
      and existing.metadata ->> 'source' = 'demo_provisioner'
  );

  select count(*)
  into demo_user_count
  from auth.users
  where lower(coalesce(email, '')) in (
      admin_email,
      'client.demo@monalyz.com'
    )
    and raw_app_meta_data ->> 'monalyz_demo' = 'true';

  select count(*)
  into active_admin_count
  from public.staff_members
  where user_id = p_admin_user_id
    and role = 'admin'
    and active;

  select count(*)
  into client_staff_count
  from public.staff_members
  where user_id = p_client_user_id;

  select count(*)
  into approved_kyc_count
  from public.kyc_applications
  where id = demo_kyc_id
    and owner_id = p_client_user_id
    and status = 'approved'
    and document_object_paths = '{}'::jsonb
    and address ->> 'monalyz_demo' = 'true';

  select count(*)
  into current_position_count
  from public.financial_positions
  where id = demo_position_id
    and owner_id = p_client_user_id
    and label = 'Compte courant démo'
    and position_kind = 'declared'
    and account_type = 'current'
    and currency = 'EUR'
    and amount_minor = 2500000
    and reserved_minor = 0
    and external_identifier_masked is null;

  select count(*)
  into audit_count
  from public.audit_events
  where actor_id = p_admin_user_id
    and metadata ->> 'source' = 'demo_provisioner'
    and metadata ->> 'demo' = 'true'
    and metadata ->> 'synthetic' = 'true'
    and (
      (
        action = 'demo_admin_account_provisioned'
        and entity_type = 'profile'
        and entity_id = p_admin_user_id
      )
      or (
        action = 'demo_client_account_provisioned'
        and entity_type = 'profile'
        and entity_id = p_client_user_id
      )
      or (
        action = 'demo_kyc_provisioned'
        and entity_type = 'kyc_application'
        and entity_id = demo_kyc_id
      )
      or (
        action = 'demo_financial_position_provisioned'
        and entity_type = 'financial_position'
        and entity_id = demo_position_id
      )
    );

  if demo_user_count <> 2
     or active_admin_count <> 1
     or client_staff_count <> 0
     or approved_kyc_count <> 1
     or current_position_count <> 1
     or audit_count <> 4 then
    raise exception 'DEMO_PROVISIONING_VERIFICATION_FAILED'
      using
        errcode = '23514',
        detail = jsonb_build_object(
          'demo_users', demo_user_count,
          'active_admins', active_admin_count,
          'client_staff_memberships', client_staff_count,
          'approved_kyc_applications', approved_kyc_count,
          'current_positions', current_position_count,
          'audit_events', audit_count
        )::text;
  end if;

  return jsonb_build_object(
    'demoUsers', demo_user_count,
    'activeAdmins', active_admin_count,
    'clientStaffMemberships', client_staff_count,
    'approvedKycApplications', approved_kyc_count,
    'currentPositions', current_position_count,
    'auditEvents', audit_count,
    'transfers', 0,
    'loans', 0,
    'externalExecutions', 0,
    'adminClientFixtures', 0
  );
end;
$$;


ALTER FUNCTION "public"."provision_demo_accounts"("p_admin_user_id" "uuid", "p_client_user_id" "uuid", "p_environment" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."brand_settings" (
    "singleton" boolean DEFAULT true NOT NULL,
    "bank_name" "text" NOT NULL,
    "primary_logo_path" "text" NOT NULL,
    "primary_logo_width" integer NOT NULL,
    "primary_logo_height" integer NOT NULL,
    "reversed_logo_path" "text" NOT NULL,
    "reversed_logo_width" integer NOT NULL,
    "reversed_logo_height" integer NOT NULL,
    "email_logo_path" "text" NOT NULL,
    "pdf_logo_path" "text" NOT NULL,
    "favicon_ico_path" "text" NOT NULL,
    "favicon_16_path" "text" NOT NULL,
    "favicon_32_path" "text" NOT NULL,
    "favicon_48_path" "text" NOT NULL,
    "apple_touch_icon_path" "text" NOT NULL,
    "app_icon_192_path" "text" NOT NULL,
    "app_icon_512_path" "text" NOT NULL,
    "maskable_icon_path" "text" NOT NULL,
    "social_card_path" "text" NOT NULL,
    "revision" bigint DEFAULT 1 NOT NULL,
    "updated_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "brand_settings_asset_paths_check" CHECK (((("char_length"("primary_logo_path") >= 3) AND ("char_length"("primary_logo_path") <= 500)) AND (("char_length"("reversed_logo_path") >= 3) AND ("char_length"("reversed_logo_path") <= 500)) AND (("char_length"("email_logo_path") >= 3) AND ("char_length"("email_logo_path") <= 500)) AND (("char_length"("pdf_logo_path") >= 3) AND ("char_length"("pdf_logo_path") <= 500)) AND (("char_length"("favicon_ico_path") >= 3) AND ("char_length"("favicon_ico_path") <= 500)) AND (("char_length"("favicon_16_path") >= 3) AND ("char_length"("favicon_16_path") <= 500)) AND (("char_length"("favicon_32_path") >= 3) AND ("char_length"("favicon_32_path") <= 500)) AND (("char_length"("favicon_48_path") >= 3) AND ("char_length"("favicon_48_path") <= 500)) AND (("char_length"("apple_touch_icon_path") >= 3) AND ("char_length"("apple_touch_icon_path") <= 500)) AND (("char_length"("app_icon_192_path") >= 3) AND ("char_length"("app_icon_192_path") <= 500)) AND (("char_length"("app_icon_512_path") >= 3) AND ("char_length"("app_icon_512_path") <= 500)) AND (("char_length"("maskable_icon_path") >= 3) AND ("char_length"("maskable_icon_path") <= 500)) AND (("char_length"("social_card_path") >= 3) AND ("char_length"("social_card_path") <= 500)))),
    CONSTRAINT "brand_settings_bank_name_check" CHECK (((("char_length"("bank_name") >= 2) AND ("char_length"("bank_name") <= 80)) AND ("bank_name" = "btrim"("bank_name")) AND ("bank_name" !~ '[\x00-\x1F\x7F]'::"text"))),
    CONSTRAINT "brand_settings_primary_dimensions_check" CHECK (((("primary_logo_width" >= 1) AND ("primary_logo_width" <= 4096)) AND (("primary_logo_height" >= 1) AND ("primary_logo_height" <= 4096)) AND ((("primary_logo_width")::bigint * ("primary_logo_height")::bigint) <= 20000000))),
    CONSTRAINT "brand_settings_reversed_dimensions_check" CHECK (((("reversed_logo_width" >= 1) AND ("reversed_logo_width" <= 4096)) AND (("reversed_logo_height" >= 1) AND ("reversed_logo_height" <= 4096)) AND ((("reversed_logo_width")::bigint * ("reversed_logo_height")::bigint) <= 20000000))),
    CONSTRAINT "brand_settings_revision_check" CHECK (("revision" > 0)),
    CONSTRAINT "brand_settings_singleton_check" CHECK ("singleton")
);


ALTER TABLE "public"."brand_settings" OWNER TO "postgres";


COMMENT ON TABLE "public"."brand_settings" IS 'Singleton containing the currently published, public bank identity.';



COMMENT ON COLUMN "public"."brand_settings"."revision" IS 'Monotonic optimistic-lock revision incremented by each atomic publication.';



CREATE OR REPLACE FUNCTION "public"."publish_brand_settings"("p_expected_revision" bigint, "p_bank_name" "text", "p_primary_logo_path" "text", "p_primary_logo_width" integer, "p_primary_logo_height" integer, "p_reversed_logo_path" "text", "p_reversed_logo_width" integer, "p_reversed_logo_height" integer, "p_email_logo_path" "text", "p_pdf_logo_path" "text", "p_favicon_ico_path" "text", "p_favicon_16_path" "text", "p_favicon_32_path" "text", "p_favicon_48_path" "text", "p_apple_touch_icon_path" "text", "p_app_icon_192_path" "text", "p_app_icon_512_path" "text", "p_maskable_icon_path" "text", "p_social_card_path" "text") RETURNS "public"."brand_settings"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_id uuid := private.ensure_branch_manager();
  normalized_name text := btrim(coalesce(p_bank_name, ''));
  previous_settings public.brand_settings;
  published_settings public.brand_settings;
begin
  select *
  into previous_settings
  from public.brand_settings
  where singleton = true
  for update;

  if previous_settings.singleton is null then
    raise exception 'BRAND_SETTINGS_NOT_FOUND' using errcode = 'P0002';
  end if;
  if p_expected_revision is null
     or previous_settings.revision <> p_expected_revision then
    raise exception 'BRAND_REVISION_CONFLICT' using errcode = '40001';
  end if;
  if char_length(normalized_name) not between 2 and 80
     or normalized_name ~ '[\x00-\x1F\x7F]' then
    raise exception 'INVALID_BRAND_NAME' using errcode = '22023';
  end if;
  if p_primary_logo_width is null
     or p_primary_logo_height is null
     or p_primary_logo_width not between 1 and 4096
     or p_primary_logo_height not between 1 and 4096
     or p_primary_logo_width::bigint * p_primary_logo_height::bigint > 20000000
     or p_reversed_logo_width is null
     or p_reversed_logo_height is null
     or p_reversed_logo_width not between 1 and 4096
     or p_reversed_logo_height not between 1 and 4096
     or p_reversed_logo_width::bigint * p_reversed_logo_height::bigint > 20000000 then
    raise exception 'INVALID_BRAND_LOGO_DIMENSIONS' using errcode = '22023';
  end if;
  if exists (
    select 1
    from unnest(array[
      p_primary_logo_path, p_reversed_logo_path, p_email_logo_path,
      p_pdf_logo_path, p_favicon_ico_path, p_favicon_16_path,
      p_favicon_32_path, p_favicon_48_path, p_apple_touch_icon_path,
      p_app_icon_192_path, p_app_icon_512_path, p_maskable_icon_path,
      p_social_card_path
    ]) path
    where path is null or char_length(path) not between 3 and 500
  ) then
    raise exception 'INVALID_BRAND_ASSET_PATH' using errcode = '22023';
  end if;

  update public.brand_settings
  set
    bank_name = normalized_name,
    primary_logo_path = p_primary_logo_path,
    primary_logo_width = p_primary_logo_width,
    primary_logo_height = p_primary_logo_height,
    reversed_logo_path = p_reversed_logo_path,
    reversed_logo_width = p_reversed_logo_width,
    reversed_logo_height = p_reversed_logo_height,
    email_logo_path = p_email_logo_path,
    pdf_logo_path = p_pdf_logo_path,
    favicon_ico_path = p_favicon_ico_path,
    favicon_16_path = p_favicon_16_path,
    favicon_32_path = p_favicon_32_path,
    favicon_48_path = p_favicon_48_path,
    apple_touch_icon_path = p_apple_touch_icon_path,
    app_icon_192_path = p_app_icon_192_path,
    app_icon_512_path = p_app_icon_512_path,
    maskable_icon_path = p_maskable_icon_path,
    social_card_path = p_social_card_path,
    revision = revision + 1,
    updated_by = caller_id
  where singleton = true
  returning * into published_settings;

  insert into public.audit_events (
    actor_id,
    action,
    entity_type,
    entity_id,
    metadata
  ) values (
    caller_id,
    'branch_manager_publish_brand_settings',
    'brand_settings',
    null,
    jsonb_build_object(
      'before', jsonb_build_object(
        'bankName', previous_settings.bank_name,
        'revision', previous_settings.revision,
        'primaryLogoPath', previous_settings.primary_logo_path,
        'reversedLogoPath', previous_settings.reversed_logo_path,
        'faviconPath', previous_settings.favicon_32_path
      ),
      'after', jsonb_build_object(
        'bankName', published_settings.bank_name,
        'revision', published_settings.revision,
        'primaryLogoPath', published_settings.primary_logo_path,
        'reversedLogoPath', published_settings.reversed_logo_path,
        'faviconPath', published_settings.favicon_32_path
      )
    )
  );

  return published_settings;
end;
$$;


ALTER FUNCTION "public"."publish_brand_settings"("p_expected_revision" bigint, "p_bank_name" "text", "p_primary_logo_path" "text", "p_primary_logo_width" integer, "p_primary_logo_height" integer, "p_reversed_logo_path" "text", "p_reversed_logo_width" integer, "p_reversed_logo_height" integer, "p_email_logo_path" "text", "p_pdf_logo_path" "text", "p_favicon_ico_path" "text", "p_favicon_16_path" "text", "p_favicon_32_path" "text", "p_favicon_48_path" "text", "p_apple_touch_icon_path" "text", "p_app_icon_192_path" "text", "p_app_icon_512_path" "text", "p_maskable_icon_path" "text", "p_social_card_path" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_admin_credentials_update"("p_actor_id" "uuid", "p_email_changed" boolean, "p_password_changed" boolean) RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  audit_id bigint;
begin
  if p_actor_id is null
     or p_email_changed is null
     or p_password_changed is null
     or p_email_changed = p_password_changed then
    raise exception 'INVALID_ADMIN_CREDENTIAL_AUDIT'
      using errcode = '22023';
  end if;

  if not exists (
    select 1
    from auth.users as user_record
    join public.staff_members as staff
      on staff.user_id = user_record.id
    where user_record.id = p_actor_id
      and staff.role = 'admin'
      and staff.active
  ) then
    raise exception 'ADMIN_CREDENTIAL_AUDIT_ACTOR_REQUIRED'
      using errcode = '42501';
  end if;

  insert into public.audit_events (
    actor_id,
    action,
    entity_type,
    entity_id,
    metadata
  )
  values (
    p_actor_id,
    'admin_credentials_updated',
    'auth_user',
    p_actor_id,
    jsonb_build_object(
      'emailChanged', p_email_changed,
      'passwordChanged', p_password_changed
    )
  )
  returning id into audit_id;

  return audit_id;
end;
$$;


ALTER FUNCTION "public"."record_admin_credentials_update"("p_actor_id" "uuid", "p_email_changed" boolean, "p_password_changed" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_financial_position"("p_owner_id" "uuid", "p_label" "text", "p_currency" "text", "p_amount_minor" bigint, "p_as_of" timestamp with time zone, "p_external_identifier_masked" "text", "p_reason" "text") RETURNS "public"."financial_positions"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_id uuid := (select auth.uid());
  position_row public.financial_positions;
begin
  if caller_id is null or not private.is_active_staff(array['supervisor', 'admin']) then
    raise exception 'SUPERVISOR_PERMISSION_REQUIRED' using errcode = '42501';
  end if;
  if p_amount_minor < 0 or p_as_of is null then
    raise exception 'INVALID_POSITION_VALUE' using errcode = '22023';
  end if;
  if nullif(trim(coalesce(p_reason, '')), '') is null then
    raise exception 'RECONCILIATION_REASON_REQUIRED' using errcode = '22023';
  end if;

  insert into public.financial_positions (
    owner_id,
    label,
    position_kind,
    currency,
    amount_minor,
    as_of,
    external_identifier_masked
  )
  values (
    p_owner_id,
    trim(p_label),
    'internally_reconciled',
    upper(p_currency),
    p_amount_minor,
    p_as_of,
    nullif(trim(coalesce(p_external_identifier_masked, '')), '')
  )
  returning * into position_row;

  insert into public.audit_events (
    actor_id, action, entity_type, entity_id, metadata
  )
  values (
    caller_id,
    'record_financial_position',
    'financial_position',
    position_row.id,
    jsonb_build_object(
      'amount_minor', p_amount_minor,
      'currency', upper(p_currency),
      'as_of', p_as_of,
      'reason', p_reason
    )
  );

  return position_row;
end;
$$;


ALTER FUNCTION "public"."record_financial_position"("p_owner_id" "uuid", "p_label" "text", "p_currency" "text", "p_amount_minor" bigint, "p_as_of" timestamp with time zone, "p_external_identifier_masked" "text", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."register_push_subscription"("p_expected_user_id" "uuid", "p_endpoint" "text", "p_p256dh" "text", "p_auth_key" "text", "p_expiration_time" bigint DEFAULT NULL::bigint, "p_user_agent" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  caller_id uuid := private.ensure_active_user();
  normalized_endpoint text := btrim(coalesce(p_endpoint, ''));
  normalized_p256dh text := btrim(coalesce(p_p256dh, ''));
  normalized_auth_key text := btrim(coalesce(p_auth_key, ''));
  normalized_user_agent text := nullif(btrim(coalesce(p_user_agent, '')), '');
  calculated_hash text;
  existing_subscription public.push_subscriptions;
  subscription_id uuid;
  subscription_count integer;
begin
  if p_expected_user_id is null or p_expected_user_id <> caller_id then
    raise exception 'PUSH_SUBSCRIPTION_ACCOUNT_CHANGED' using errcode = '42501';
  end if;

  if char_length(normalized_endpoint) not between 20 and 2048
     or (
       lower(normalized_endpoint) !~ '^https://fcm\.googleapis\.com(:443)?/'
       and lower(normalized_endpoint) !~ '^https://updates\.push\.services\.mozilla\.com(:443)?/'
       and lower(normalized_endpoint) !~ '^https://([a-z0-9-]+\.)*push\.apple\.com(:443)?/'
       and lower(normalized_endpoint) !~ '^https://([a-z0-9-]+\.)*notify\.windows\.com(:443)?/'
     )
  then
    raise exception 'INVALID_PUSH_ENDPOINT' using errcode = '22023';
  end if;

  if char_length(normalized_p256dh) not between 40 and 200
     or normalized_p256dh !~ '^[A-Za-z0-9_-]+={0,2}$'
     or char_length(normalized_auth_key) not between 10 and 100
     or normalized_auth_key !~ '^[A-Za-z0-9_-]+={0,2}$'
     or (p_expiration_time is not null and p_expiration_time <= 0)
     or (normalized_user_agent is not null and char_length(normalized_user_agent) > 500)
  then
    raise exception 'INVALID_PUSH_SUBSCRIPTION' using errcode = '22023';
  end if;

  calculated_hash := encode(
    extensions.digest(convert_to(normalized_endpoint, 'UTF8'), 'sha256'),
    'hex'
  );

  -- Serialize registration, rebind and device-limit checks for this user.
  -- Without this row lock two new endpoints could both observe count < 20.
  perform 1
  from public.profiles
  where user_id = caller_id
  for update;

  if not found then
    raise exception 'PROFILE_NOT_FOUND' using errcode = 'P0002';
  end if;

  select subscription.*
  into existing_subscription
  from public.push_subscriptions as subscription
  where subscription.endpoint_hash = calculated_hash
  for update;

  if found then
    if existing_subscription.endpoint is distinct from normalized_endpoint then
      raise exception 'PUSH_ENDPOINT_HASH_COLLISION' using errcode = '23505';
    end if;

    -- Rebinding a browser endpoint between successive authenticated users is
    -- allowed only when both browser-held subscription secrets still match.
    if existing_subscription.user_id <> caller_id
       and (
         existing_subscription.p256dh is distinct from normalized_p256dh
         or existing_subscription.auth_key is distinct from normalized_auth_key
       )
    then
      raise exception 'PUSH_SUBSCRIPTION_OWNERSHIP_MISMATCH' using errcode = '42501';
    end if;

    if existing_subscription.user_id <> caller_id then
      select count(*)
      into subscription_count
      from public.push_subscriptions
      where user_id = caller_id;

      if subscription_count >= 20 then
        raise exception 'PUSH_SUBSCRIPTION_LIMIT_REACHED' using errcode = '54000';
      end if;
    end if;

    update public.push_subscriptions
    set
      user_id = caller_id,
      p256dh = normalized_p256dh,
      auth_key = normalized_auth_key,
      expiration_time = p_expiration_time,
      user_agent = normalized_user_agent,
      last_success_at = case
        when existing_subscription.user_id = caller_id then last_success_at
        else null
      end,
      failure_count = 0,
      last_error = null
    where id = existing_subscription.id
    returning id into subscription_id;

    return subscription_id;
  end if;

  select count(*)
  into subscription_count
  from public.push_subscriptions
  where user_id = caller_id;

  if subscription_count >= 20 then
    raise exception 'PUSH_SUBSCRIPTION_LIMIT_REACHED' using errcode = '54000';
  end if;

  insert into public.push_subscriptions (
    user_id,
    endpoint,
    endpoint_hash,
    p256dh,
    auth_key,
    expiration_time,
    user_agent
  )
  values (
    caller_id,
    normalized_endpoint,
    calculated_hash,
    normalized_p256dh,
    normalized_auth_key,
    p_expiration_time,
    normalized_user_agent
  )
  returning id into subscription_id;

  return subscription_id;
end;
$_$;


ALTER FUNCTION "public"."register_push_subscription"("p_expected_user_id" "uuid", "p_endpoint" "text", "p_p256dh" "text", "p_auth_key" "text", "p_expiration_time" bigint, "p_user_agent" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."release_support_transcript_claim"("p_transcript_id" "uuid", "p_claim_token" "uuid", "p_completed" boolean DEFAULT false) RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  worker_role text := coalesce((select auth.jwt() ->> 'role'), '');
  released_count integer;
begin
  if worker_role <> 'service_role' then
    raise exception 'SUPPORT_WORKER_PERMISSION_REQUIRED' using errcode = '42501';
  end if;

  update public.support_transcripts
  set
    processing_token = null,
    processing_started_at = null,
    completed_at = case
      when coalesce(p_completed, false) then coalesce(completed_at, now())
      else completed_at
    end
  where id = p_transcript_id
    and processing_token = p_claim_token;

  get diagnostics released_count = row_count;
  return released_count = 1;
end;
$$;


ALTER FUNCTION "public"."release_support_transcript_claim"("p_transcript_id" "uuid", "p_claim_token" "uuid", "p_completed" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."request_kyc_information"("p_kyc_id" "uuid", "p_requested_items" "text"[], "p_reason_code" "text", "p_note" "text", "p_due_at" timestamp with time zone) RETURNS "public"."kyc_applications"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_id uuid := (select auth.uid());
  kyc_row public.kyc_applications;
begin
  if caller_id is null
     or not private.is_active_staff(array['reviewer', 'supervisor', 'admin']) then
    raise exception 'STAFF_PERMISSION_REQUIRED' using errcode = '42501';
  end if;
  if cardinality(coalesce(p_requested_items, '{}')) = 0
     or not (
       p_requested_items <@ array[
         'identity', 'birth', 'address', 'profile', 'document_metadata',
         'id_front', 'id_back', 'proof_of_address'
       ]::text[]
     )
     or p_reason_code not in (
       'unreadable_document', 'expired_document',
       'inconsistent_information', 'missing_document',
       'address_not_verified', 'regulatory_information', 'other'
     )
     or nullif(trim(coalesce(p_note, '')), '') is null
     or (p_due_at is not null and p_due_at <= now()) then
    raise exception 'INVALID_KYC_INFORMATION_REQUEST' using errcode = '22023';
  end if;

  update public.kyc_applications
  set
    status = 'needs_information',
    requested_items = p_requested_items,
    correction_reason_code = p_reason_code,
    correction_due_at = p_due_at,
    review_note = trim(p_note),
    reviewed_by = caller_id,
    reviewed_at = null
  where id = p_kyc_id and status = 'under_review'
  returning * into kyc_row;

  if not found then
    raise exception 'INVALID_KYC_TRANSITION' using errcode = '55000';
  end if;

  insert into public.kyc_events (
    kyc_id, actor_id, event_type, from_status, to_status, reason
  )
  values (
    p_kyc_id,
    caller_id,
    'information_requested',
    'under_review',
    'needs_information',
    trim(p_note)
  );
  return kyc_row;
end;
$$;


ALTER FUNCTION "public"."request_kyc_information"("p_kyc_id" "uuid", "p_requested_items" "text"[], "p_reason_code" "text", "p_note" "text", "p_due_at" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."resubmit_kyc_application"("p_kyc_id" "uuid", "p_changes" "jsonb", "p_document_object_paths" "jsonb") RETURNS "public"."kyc_applications"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_id uuid := private.ensure_active_user();
  kyc_row public.kyc_applications;
  item text;
  merged_paths jsonb;
  old_status text;
begin
  select * into kyc_row
  from public.kyc_applications
  where id = p_kyc_id and owner_id = caller_id
  for update;

  if not found then
    raise exception 'KYC_NOT_FOUND' using errcode = 'P0002';
  end if;
  if kyc_row.status not in ('needs_information', 'rejected') then
    raise exception 'INVALID_KYC_TRANSITION' using errcode = '55000';
  end if;
  old_status := kyc_row.status;
  if jsonb_typeof(coalesce(p_changes, '{}'::jsonb)) <> 'object'
     or jsonb_typeof(coalesce(p_document_object_paths, '{}'::jsonb)) <> 'object' then
    raise exception 'INVALID_KYC_CORRECTION' using errcode = '22023';
  end if;

  for item in select jsonb_object_keys(coalesce(p_changes, '{}'::jsonb))
  loop
    if not (item = any(kyc_row.requested_items)) then
      raise exception 'UNREQUESTED_KYC_FIELD' using errcode = '42501';
    end if;
  end loop;
  for item in select jsonb_object_keys(coalesce(p_document_object_paths, '{}'::jsonb))
  loop
    if not (item = any(kyc_row.requested_items)) then
      raise exception 'UNREQUESTED_KYC_DOCUMENT' using errcode = '42501';
    end if;
  end loop;

  merged_paths := kyc_row.document_object_paths
    || coalesce(p_document_object_paths, '{}'::jsonb);

  update public.kyc_applications
  set
    first_name = case when 'identity' = any(requested_items)
      then trim(coalesce(p_changes #>> '{identity,firstName}', first_name))
      else first_name end,
    last_name = case when 'identity' = any(requested_items)
      then trim(coalesce(p_changes #>> '{identity,lastName}', last_name))
      else last_name end,
    place_of_birth = case when 'identity' = any(requested_items)
      then trim(coalesce(p_changes #>> '{identity,placeOfBirth}', place_of_birth))
      else place_of_birth end,
    nationality = case when 'identity' = any(requested_items)
      then trim(coalesce(p_changes #>> '{identity,nationality}', nationality))
      else nationality end,
    date_of_birth = case when 'birth' = any(requested_items)
      then coalesce((p_changes ->> 'birth')::date, date_of_birth)
      else date_of_birth end,
    address = case when 'address' = any(requested_items)
      then coalesce(p_changes -> 'address', address)
      else address end,
    occupation = case when 'profile' = any(requested_items)
      then trim(coalesce(p_changes #>> '{profile,occupation}', occupation))
      else occupation end,
    income_range = case when 'profile' = any(requested_items)
      then trim(coalesce(p_changes #>> '{profile,incomeRange}', income_range))
      else income_range end,
    fatca = case when 'profile' = any(requested_items)
      then coalesce((p_changes #>> '{profile,fatca}')::boolean, fatca)
      else fatca end,
    pep = case when 'profile' = any(requested_items)
      then coalesce((p_changes #>> '{profile,pep}')::boolean, pep)
      else pep end,
    document_type = case when 'document_metadata' = any(requested_items)
      then coalesce(p_changes #>> '{document_metadata,documentType}', document_type)
      else document_type end,
    document_number = case when 'document_metadata' = any(requested_items)
      then trim(coalesce(p_changes #>> '{document_metadata,documentNumber}', document_number))
      else document_number end,
    issuing_country = case when 'document_metadata' = any(requested_items)
      then trim(coalesce(p_changes #>> '{document_metadata,issuingCountry}', issuing_country))
      else issuing_country end,
    document_expires_on = case when 'document_metadata' = any(requested_items)
      then coalesce(
        (p_changes #>> '{document_metadata,documentExpiresOn}')::date,
        document_expires_on
      )
      else document_expires_on end,
    document_object_paths = merged_paths,
    status = 'resubmitted',
    submitted_at = now(),
    reviewed_at = null,
    requested_items = '{}',
    correction_reason_code = null,
    correction_due_at = null
  where id = p_kyc_id
  returning * into kyc_row;

  perform private.validate_kyc_submission(
    kyc_row.first_name,
    kyc_row.last_name,
    kyc_row.date_of_birth,
    kyc_row.place_of_birth,
    kyc_row.nationality,
    kyc_row.address,
    kyc_row.occupation,
    kyc_row.income_range,
    kyc_row.document_type,
    kyc_row.document_number,
    kyc_row.issuing_country,
    kyc_row.document_expires_on,
    kyc_row.document_object_paths
  );

  insert into public.kyc_events (
    kyc_id, actor_id, event_type, from_status, to_status
  )
  values (
    p_kyc_id,
    caller_id,
    'resubmitted',
    old_status,
    'resubmitted'
  );
  return kyc_row;
end;
$$;


ALTER FUNCTION "public"."resubmit_kyc_application"("p_kyc_id" "uuid", "p_changes" "jsonb", "p_document_object_paths" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."review_kyc_application"("p_kyc_id" "uuid", "p_status" "text", "p_note" "text") RETURNS "public"."kyc_applications"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_id uuid := (select auth.uid());
  kyc_row public.kyc_applications;
  old_status text;
begin
  if caller_id is null or not private.is_active_staff(array['reviewer', 'supervisor', 'admin']) then
    raise exception 'STAFF_PERMISSION_REQUIRED' using errcode = '42501';
  end if;

  if p_status not in ('under_review', 'approved', 'rejected', 'needs_information') then
    raise exception 'INVALID_KYC_STATUS' using errcode = '22023';
  end if;

  select *
  into kyc_row
  from public.kyc_applications
  where id = p_kyc_id
  for update;

  if not found then
    raise exception 'KYC_NOT_FOUND' using errcode = 'P0002';
  end if;

  if kyc_row.status in ('approved', 'rejected') then
    raise exception 'KYC_ALREADY_FINAL' using errcode = '55000';
  end if;

  if p_status in ('rejected', 'needs_information')
     and nullif(trim(coalesce(p_note, '')), '') is null then
    raise exception 'REVIEW_NOTE_REQUIRED' using errcode = '22023';
  end if;

  old_status := kyc_row.status;

  update public.kyc_applications
  set
    status = p_status,
    reviewed_by = caller_id,
    reviewed_at = case when p_status in ('approved', 'rejected') then now() else null end,
    review_note = nullif(trim(coalesce(p_note, '')), '')
  where id = p_kyc_id
  returning * into kyc_row;

  insert into public.kyc_events (
    kyc_id, actor_id, event_type, from_status, to_status, reason
  )
  values (
    p_kyc_id,
    caller_id,
    'reviewed',
    old_status,
    p_status,
    nullif(trim(coalesce(p_note, '')), '')
  );

  insert into public.audit_events (
    actor_id, action, entity_type, entity_id, metadata
  )
  values (
    caller_id,
    'review_kyc',
    'kyc_application',
    p_kyc_id,
    jsonb_build_object('from_status', old_status, 'to_status', p_status)
  );

  insert into public.notifications (
    recipient_id, title, message, notification_type
  )
  values (
    kyc_row.owner_id,
    'Dossier d’identité mis à jour',
    case p_status
      when 'approved' then 'Votre identité a été approuvée dans Monalyz. Cette approbation ne crée ni compte bancaire ni IBAN.'
      when 'rejected' then 'Votre dossier d’identité a été rejeté. Consultez le motif pour le corriger.'
      when 'needs_information' then 'Des informations complémentaires sont nécessaires pour poursuivre le contrôle.'
      else 'Votre dossier est en cours de contrôle humain.'
    end,
    'kyc'
  );

  return kyc_row;
end;
$$;


ALTER FUNCTION "public"."review_kyc_application"("p_kyc_id" "uuid", "p_status" "text", "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."review_loan_check"("p_loan_id" "uuid", "p_check_kind" "text", "p_status" "text", "p_note" "text" DEFAULT NULL::"text") RETURNS "public"."loan_applications"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_id uuid := (select auth.uid());
  loan_row public.loan_applications;
  old_status text;
  next_status text;
begin
  if caller_id is null or not private.is_active_staff(array['reviewer', 'operator', 'supervisor', 'admin']) then
    raise exception 'STAFF_PERMISSION_REQUIRED' using errcode = '42501';
  end if;

  if p_check_kind not in ('dual_review', 'escalation', 'compliance', 'final_authorization')
     or p_status not in ('pending', 'in_progress', 'completed', 'failed') then
    raise exception 'INVALID_REVIEW_VALUE' using errcode = '22023';
  end if;

  select *
  into loan_row
  from public.loan_applications
  where id = p_loan_id
  for update;

  if not found then
    raise exception 'LOAN_NOT_FOUND' using errcode = 'P0002';
  end if;

  if loan_row.status not in ('submitted', 'under_review') then
    raise exception 'LOAN_NOT_REVIEWABLE' using errcode = '55000';
  end if;

  old_status := loan_row.status;

  update public.loan_review_checks
  set
    status = p_status,
    reviewer_id = caller_id,
    note = nullif(trim(coalesce(p_note, '')), ''),
    reviewed_at = case when p_status in ('completed', 'failed') then now() else null end
  where loan_id = p_loan_id and check_kind = p_check_kind;

  if p_status = 'failed' then
    next_status := 'under_review';
  elsif not exists (
    select 1
    from public.loan_review_checks
    where loan_id = p_loan_id and status <> 'completed'
  ) then
    if (
      select count(distinct reviewer_id)
      from public.loan_review_checks
      where loan_id = p_loan_id and status = 'completed'
    ) < 2 then
      raise exception 'TWO_DISTINCT_REVIEWERS_REQUIRED' using errcode = '42501';
    end if;
    next_status := 'approved_for_external_funding';
  else
    next_status := 'under_review';
  end if;

  update public.loan_applications
  set status = next_status
  where id = p_loan_id
  returning * into loan_row;

  insert into public.loan_events (
    loan_id, actor_id, event_type, from_status, to_status, reason, metadata
  )
  values (
    p_loan_id,
    caller_id,
    'review_check_updated',
    old_status,
    next_status,
    nullif(trim(coalesce(p_note, '')), ''),
    jsonb_build_object('check_kind', p_check_kind, 'check_status', p_status)
  );

  return loan_row;
end;
$$;


ALTER FUNCTION "public"."review_loan_check"("p_loan_id" "uuid", "p_check_kind" "text", "p_status" "text", "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."review_transfer_check"("p_transfer_id" "uuid", "p_check_kind" "text", "p_status" "text", "p_note" "text" DEFAULT NULL::"text") RETURNS "public"."transfer_intents"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_id uuid := (select auth.uid());
  transfer_row public.transfer_intents;
  old_status text;
  next_status text;
begin
  if caller_id is null or not private.is_active_staff(array['reviewer', 'operator', 'supervisor', 'admin']) then
    raise exception 'STAFF_PERMISSION_REQUIRED' using errcode = '42501';
  end if;

  if p_check_kind not in ('dual_review', 'escalation', 'compliance', 'final_authorization')
     or p_status not in ('pending', 'in_progress', 'completed', 'failed') then
    raise exception 'INVALID_REVIEW_VALUE' using errcode = '22023';
  end if;

  select *
  into transfer_row
  from public.transfer_intents
  where id = p_transfer_id
  for update;

  if not found then
    raise exception 'TRANSFER_NOT_FOUND' using errcode = 'P0002';
  end if;

  if transfer_row.status not in ('submitted', 'under_review') then
    raise exception 'TRANSFER_NOT_REVIEWABLE' using errcode = '55000';
  end if;

  old_status := transfer_row.status;

  update public.transfer_review_checks
  set
    status = p_status,
    reviewer_id = caller_id,
    note = nullif(trim(coalesce(p_note, '')), ''),
    reviewed_at = case when p_status in ('completed', 'failed') then now() else null end
  where transfer_id = p_transfer_id and check_kind = p_check_kind;

  if p_status = 'failed' then
    next_status := 'under_review';
  elsif not exists (
    select 1
    from public.transfer_review_checks
    where transfer_id = p_transfer_id and status <> 'completed'
  ) then
    if (
      select count(distinct reviewer_id)
      from public.transfer_review_checks
      where transfer_id = p_transfer_id and status = 'completed'
    ) < 2 then
      raise exception 'TWO_DISTINCT_REVIEWERS_REQUIRED' using errcode = '42501';
    end if;
    next_status := 'approved_for_external_execution';
  else
    next_status := 'under_review';
  end if;

  update public.transfer_intents
  set status = next_status
  where id = p_transfer_id
  returning * into transfer_row;

  insert into public.transfer_events (
    transfer_id, actor_id, event_type, from_status, to_status, reason, metadata
  )
  values (
    p_transfer_id,
    caller_id,
    'review_check_updated',
    old_status,
    next_status,
    nullif(trim(coalesce(p_note, '')), ''),
    jsonb_build_object('check_kind', p_check_kind, 'check_status', p_status)
  );

  return transfer_row;
end;
$$;


ALTER FUNCTION "public"."review_transfer_check"("p_transfer_id" "uuid", "p_check_kind" "text", "p_status" "text", "p_note" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."kyc_drafts" (
    "owner_id" "uuid" NOT NULL,
    "current_step" integer DEFAULT 0 NOT NULL,
    "payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "document_object_paths" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "preferred_language" "text" DEFAULT 'fr'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "kyc_drafts_current_step_check" CHECK ((("current_step" >= 0) AND ("current_step" <= 8))),
    CONSTRAINT "kyc_drafts_document_object_paths_check" CHECK (("jsonb_typeof"("document_object_paths") = 'object'::"text")),
    CONSTRAINT "kyc_drafts_payload_check" CHECK (("jsonb_typeof"("payload") = 'object'::"text")),
    CONSTRAINT "kyc_drafts_preferred_language_check" CHECK (("preferred_language" = ANY (ARRAY['fr'::"text", 'en'::"text", 'de'::"text", 'es'::"text", 'it'::"text", 'nl'::"text"])))
);


ALTER TABLE "public"."kyc_drafts" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."save_kyc_draft"("p_current_step" integer, "p_payload" "jsonb", "p_document_object_paths" "jsonb", "p_preferred_language" "text") RETURNS "public"."kyc_drafts"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_id uuid := private.ensure_active_user();
  draft_row public.kyc_drafts;
begin
  if p_current_step not between 0 and 8
     or jsonb_typeof(coalesce(p_payload, '{}'::jsonb)) <> 'object'
     or jsonb_typeof(coalesce(p_document_object_paths, '{}'::jsonb)) <> 'object'
     or p_preferred_language not in ('fr', 'en', 'de', 'es', 'it', 'nl') then
    raise exception 'INVALID_KYC_DRAFT' using errcode = '22023';
  end if;

  insert into public.kyc_drafts (
    owner_id,
    current_step,
    payload,
    document_object_paths,
    preferred_language
  )
  values (
    caller_id,
    p_current_step,
    coalesce(p_payload, '{}'::jsonb),
    coalesce(p_document_object_paths, '{}'::jsonb),
    p_preferred_language
  )
  on conflict (owner_id) do update
  set
    current_step = excluded.current_step,
    payload = excluded.payload,
    document_object_paths = excluded.document_object_paths,
    preferred_language = excluded.preferred_language
  returning * into draft_row;

  return draft_row;
end;
$$;


ALTER FUNCTION "public"."save_kyc_draft"("p_current_step" integer, "p_payload" "jsonb", "p_document_object_paths" "jsonb", "p_preferred_language" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_account_number_prefix"("p_prefix" "text") RETURNS TABLE("prefix" "text", "prefix_length" integer, "capacity" integer, "updated_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  caller_id uuid := private.ensure_branch_manager();
  normalized_prefix text := trim(coalesce(p_prefix, ''));
  configuration private.account_number_configuration;
begin
  if normalized_prefix !~ '^[0-9]{5,9}$' then
    raise exception 'INVALID_ACCOUNT_NUMBER_PREFIX'
      using errcode = '22023';
  end if;

  insert into private.account_number_configuration (
    singleton,
    prefix,
    created_by,
    updated_by
  )
  values (
    true,
    normalized_prefix,
    caller_id,
    caller_id
  )
  on conflict (singleton) do update
  set
    prefix = excluded.prefix,
    updated_at = now(),
    updated_by = caller_id
  returning * into configuration;

  insert into public.audit_events (
    actor_id,
    action,
    entity_type,
    entity_id,
    metadata
  )
  values (
    caller_id,
    'set_account_number_prefix',
    'account_number_configuration',
    caller_id,
    jsonb_build_object(
      'prefix', configuration.prefix,
      'prefix_length', char_length(configuration.prefix),
      'capacity',
        power(
          10::numeric,
          10 - char_length(configuration.prefix)
        )::integer
    )
  );

  return query
  select
    configuration.prefix,
    char_length(configuration.prefix)::integer,
    power(
      10::numeric,
      10 - char_length(configuration.prefix)
    )::integer,
    configuration.updated_at;
end;
$_$;


ALTER FUNCTION "public"."set_account_number_prefix"("p_prefix" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "user_id" "uuid" NOT NULL,
    "email" "text" NOT NULL,
    "display_name" "text" DEFAULT ''::"text" NOT NULL,
    "phone" "text",
    "preferred_currency" "text" DEFAULT 'EUR'::"text" NOT NULL,
    "access_status" "text" DEFAULT 'active'::"text" NOT NULL,
    "access_status_reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "preferred_language" "text" DEFAULT 'fr'::"text" NOT NULL,
    "base_currency" "text" DEFAULT 'EUR'::"text" NOT NULL,
    CONSTRAINT "profiles_access_status_check" CHECK (("access_status" = ANY (ARRAY['active'::"text", 'frozen'::"text"]))),
    CONSTRAINT "profiles_base_currency_check" CHECK (("base_currency" = ANY (ARRAY['EUR'::"text", 'USD'::"text", 'CAD'::"text", 'CHF'::"text", 'GBP'::"text"]))),
    CONSTRAINT "profiles_preferred_currency_check" CHECK (("preferred_currency" = ANY (ARRAY['EUR'::"text", 'USD'::"text", 'CAD'::"text", 'CHF'::"text", 'GBP'::"text"]))),
    CONSTRAINT "profiles_preferred_language_allowed" CHECK (("preferred_language" = ANY (ARRAY['fr'::"text", 'en'::"text", 'de'::"text", 'es'::"text", 'it'::"text", 'nl'::"text"])))
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_user_access_status"("p_user_id" "uuid", "p_status" "text", "p_reason" "text") RETURNS "public"."profiles"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_id uuid := (select auth.uid());
  profile_row public.profiles;
begin
  if caller_id is null or not private.is_active_staff(array['admin']) then
    raise exception 'ADMIN_PERMISSION_REQUIRED' using errcode = '42501';
  end if;
  if p_status not in ('active', 'frozen') then
    raise exception 'INVALID_ACCESS_STATUS' using errcode = '22023';
  end if;
  if p_status = 'frozen' and nullif(trim(coalesce(p_reason, '')), '') is null then
    raise exception 'FREEZE_REASON_REQUIRED' using errcode = '22023';
  end if;

  update public.profiles
  set
    access_status = p_status,
    access_status_reason = case
      when p_status = 'frozen' then trim(p_reason)
      else null
    end
  where user_id = p_user_id
  returning * into profile_row;

  if not found then
    raise exception 'PROFILE_NOT_FOUND' using errcode = 'P0002';
  end if;

  insert into public.audit_events (
    actor_id, action, entity_type, entity_id, metadata
  )
  values (
    caller_id,
    'set_access_status',
    'profile',
    p_user_id,
    jsonb_build_object('status', p_status, 'reason', p_reason)
  );

  return profile_row;
end;
$$;


ALTER FUNCTION "public"."set_user_access_status"("p_user_id" "uuid", "p_status" "text", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_kyc_application"("p_first_name" "text", "p_last_name" "text", "p_date_of_birth" "date", "p_place_of_birth" "text", "p_nationality" "text", "p_address" "jsonb", "p_occupation" "text", "p_income_range" "text", "p_fatca" boolean, "p_pep" boolean, "p_document_type" "text", "p_document_number" "text", "p_issuing_country" "text", "p_document_expires_on" "date", "p_document_object_paths" "jsonb", "p_idempotency_key" "uuid") RETURNS "public"."kyc_applications"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_id uuid := private.ensure_active_user();
  kyc_row public.kyc_applications;
begin
  perform private.validate_kyc_submission(
    p_first_name,
    p_last_name,
    p_date_of_birth,
    p_place_of_birth,
    p_nationality,
    p_address,
    p_occupation,
    p_income_range,
    p_document_type,
    p_document_number,
    p_issuing_country,
    p_document_expires_on,
    p_document_object_paths
  );

  if exists (
    select 1
    from public.kyc_applications
    where owner_id = caller_id
  ) then
    raise exception 'KYC_APPLICATION_ALREADY_EXISTS' using errcode = '23505';
  end if;

  insert into public.kyc_applications (
    owner_id,
    idempotency_key,
    first_name,
    last_name,
    date_of_birth,
    place_of_birth,
    nationality,
    address,
    occupation,
    income_range,
    fatca,
    pep,
    document_type,
    document_number,
    issuing_country,
    document_expires_on,
    document_object_paths,
    status
  )
  values (
    caller_id,
    p_idempotency_key,
    trim(p_first_name),
    trim(p_last_name),
    p_date_of_birth,
    trim(p_place_of_birth),
    trim(p_nationality),
    p_address,
    trim(p_occupation),
    trim(p_income_range),
    p_fatca,
    p_pep,
    p_document_type,
    trim(p_document_number),
    trim(p_issuing_country),
    p_document_expires_on,
    p_document_object_paths,
    'submitted'
  )
  on conflict (owner_id, idempotency_key) do nothing
  returning * into kyc_row;

  if kyc_row.id is null then
    select *
    into kyc_row
    from public.kyc_applications
    where owner_id = caller_id and idempotency_key = p_idempotency_key;
    return kyc_row;
  end if;

  insert into public.kyc_events (
    kyc_id, actor_id, event_type, to_status
  )
  values (kyc_row.id, caller_id, 'submitted', 'submitted');

  delete from public.kyc_drafts where owner_id = caller_id;
  return kyc_row;
end;
$$;


ALTER FUNCTION "public"."submit_kyc_application"("p_first_name" "text", "p_last_name" "text", "p_date_of_birth" "date", "p_place_of_birth" "text", "p_nationality" "text", "p_address" "jsonb", "p_occupation" "text", "p_income_range" "text", "p_fatca" boolean, "p_pep" boolean, "p_document_type" "text", "p_document_number" "text", "p_issuing_country" "text", "p_document_expires_on" "date", "p_document_object_paths" "jsonb", "p_idempotency_key" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_loan_application"("p_requested_amount_minor" bigint, "p_currency" "text", "p_duration_months" integer, "p_motive_code" "text", "p_document_object_paths" "jsonb", "p_idempotency_key" "uuid") RETURNS "public"."loan_applications"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_id uuid := private.ensure_active_user();
  caller_base_currency text;
  loan_row public.loan_applications;
  product_settings public.loan_product_settings;
  new_loan_id uuid := gen_random_uuid();
  normalized_currency text := upper(trim(coalesce(p_currency, '')));
  generated_reference text;
  canonical_motive text;
  monthly_rate numeric;
  compound_factor numeric;
  calculated_monthly_payment_minor bigint;
begin
  if p_idempotency_key is null then
    raise exception 'INVALID_IDEMPOTENCY_KEY' using errcode = '22023';
  end if;

  select profile.base_currency
  into caller_base_currency
  from public.profiles as profile
  where profile.user_id = caller_id;

  if normalized_currency is distinct from caller_base_currency then
    raise exception 'LOAN_CURRENCY_MUST_MATCH_BASE' using errcode = '22023';
  end if;

  select *
  into loan_row
  from public.loan_applications
  where owner_id = caller_id
    and idempotency_key = p_idempotency_key;

  if loan_row.id is not null then
    return loan_row;
  end if;

  if p_motive_code is null
    or p_motive_code not in (
      'personal',
      'real_estate',
      'vehicle',
      'renovation',
      'business_cashflow',
      'other'
    )
  then
    raise exception 'INVALID_LOAN_MOTIVE_CODE' using errcode = '22023';
  end if;
  if p_document_object_paths is null
    or jsonb_typeof(p_document_object_paths) <> 'array'
  then
    raise exception 'INVALID_LOAN_DOCUMENTS' using errcode = '22023';
  end if;

  select *
  into product_settings
  from public.loan_product_settings
  where currency = normalized_currency;

  if product_settings.currency is null or not product_settings.is_active then
    raise exception 'LOAN_PRODUCT_UNAVAILABLE' using errcode = '22023';
  end if;
  if p_requested_amount_minor is null
    or p_requested_amount_minor < product_settings.minimum_amount_minor
    or p_requested_amount_minor > product_settings.maximum_amount_minor
  then
    raise exception 'LOAN_AMOUNT_OUT_OF_RANGE' using errcode = '22023';
  end if;
  if p_duration_months is null
    or p_duration_months < product_settings.minimum_duration_months
    or p_duration_months > product_settings.maximum_duration_months
  then
    raise exception 'LOAN_DURATION_OUT_OF_RANGE' using errcode = '22023';
  end if;
  if (
    (p_duration_months - product_settings.minimum_duration_months)
    % product_settings.duration_step_months
  ) <> 0
  then
    raise exception 'LOAN_DURATION_STEP_MISMATCH' using errcode = '22023';
  end if;

  if product_settings.fixed_annual_rate = 0 then
    calculated_monthly_payment_minor :=
      round(p_requested_amount_minor::numeric / p_duration_months)::bigint;
  else
    monthly_rate := product_settings.fixed_annual_rate / 12;
    compound_factor := power(1 + monthly_rate, p_duration_months);
    calculated_monthly_payment_minor := round(
      p_requested_amount_minor::numeric
      * monthly_rate
      * compound_factor
      / (compound_factor - 1)
    )::bigint;
  end if;

  canonical_motive := case p_motive_code
    when 'personal' then 'Projet personnel'
    when 'real_estate' then 'Projet immobilier'
    when 'vehicle' then 'Achat d’un véhicule'
    when 'renovation' then 'Travaux et rénovation'
    when 'business_cashflow' then 'Trésorerie professionnelle'
    else 'Autre'
  end;
  generated_reference := product_settings.reference_prefix
    || to_char(now(), 'YYYYMMDD')
    || '-'
    || upper(replace(new_loan_id::text, '-', ''));

  insert into public.loan_applications (
    id,
    owner_id,
    idempotency_key,
    reference,
    requested_amount_minor,
    currency,
    duration_months,
    indicative_monthly_payment_minor,
    indicative_annual_rate,
    motive,
    motive_code,
    document_object_paths
  ) values (
    new_loan_id,
    caller_id,
    p_idempotency_key,
    generated_reference,
    p_requested_amount_minor,
    normalized_currency,
    p_duration_months,
    calculated_monthly_payment_minor,
    product_settings.fixed_annual_rate,
    canonical_motive,
    p_motive_code,
    p_document_object_paths
  )
  on conflict (owner_id, idempotency_key) do nothing
  returning * into loan_row;

  if loan_row.id is null then
    select *
    into loan_row
    from public.loan_applications
    where owner_id = caller_id
      and idempotency_key = p_idempotency_key;
    return loan_row;
  end if;

  insert into public.loan_review_checks (loan_id, check_kind)
  select loan_row.id, check_kind
  from unnest(
    array['dual_review', 'escalation', 'compliance', 'final_authorization']
  ) as check_kind;

  insert into public.loan_events (loan_id, actor_id, event_type, to_status)
  values (loan_row.id, caller_id, 'submitted', 'submitted');

  insert into public.notifications (
    recipient_id,
    title,
    message,
    notification_type,
    message_key,
    message_params
  ) values (
    caller_id,
    'Demande de prêt enregistrée',
    'La demande de prêt a été transmise pour analyse.',
    'loan',
    'loan_submitted',
    jsonb_build_object('reference', loan_row.reference)
  );

  return loan_row;
end;
$$;


ALTER FUNCTION "public"."submit_loan_application"("p_requested_amount_minor" bigint, "p_currency" "text", "p_duration_months" integer, "p_motive_code" "text", "p_document_object_paths" "jsonb", "p_idempotency_key" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_transfer_intent"("p_source_position_id" "uuid", "p_recipient_name" "text", "p_recipient_account_masked" "text", "p_beneficiary_details" "jsonb", "p_transfer_type" "text", "p_amount_minor" bigint, "p_currency" "text", "p_target_amount_minor" bigint, "p_target_currency" "text", "p_quote_rate" numeric, "p_quote_as_of" timestamp with time zone, "p_motive" "text", "p_idempotency_key" "uuid") RETURNS "public"."transfer_intents"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_id uuid := private.ensure_active_user();
  position_row public.financial_positions;
  transfer_row public.transfer_intents;
begin
  if p_amount_minor <= 0 or p_target_amount_minor <= 0 or p_quote_rate <= 0 then
    raise exception 'INVALID_TRANSFER_AMOUNT' using errcode = '22023';
  end if;

  select *
  into position_row
  from public.financial_positions
  where id = p_source_position_id and owner_id = caller_id
  for update;

  if not found then
    raise exception 'SOURCE_POSITION_NOT_FOUND' using errcode = 'P0002';
  end if;

  if position_row.currency <> upper(p_currency) then
    raise exception 'SOURCE_CURRENCY_MISMATCH' using errcode = '22023';
  end if;

  insert into public.transfer_intents (
    owner_id,
    source_position_id,
    idempotency_key,
    recipient_name,
    recipient_account_masked,
    beneficiary_details,
    transfer_type,
    amount_minor,
    currency,
    target_amount_minor,
    target_currency,
    quote_rate,
    quote_as_of,
    motive
  )
  values (
    caller_id,
    p_source_position_id,
    p_idempotency_key,
    trim(p_recipient_name),
    trim(p_recipient_account_masked),
    coalesce(p_beneficiary_details, '{}'::jsonb),
    p_transfer_type,
    p_amount_minor,
    upper(p_currency),
    p_target_amount_minor,
    upper(p_target_currency),
    p_quote_rate,
    p_quote_as_of,
    nullif(trim(coalesce(p_motive, '')), '')
  )
  on conflict (owner_id, idempotency_key) do nothing
  returning * into transfer_row;

  if transfer_row.id is null then
    select *
    into transfer_row
    from public.transfer_intents
    where owner_id = caller_id and idempotency_key = p_idempotency_key;
    return transfer_row;
  end if;

  if position_row.amount_minor - position_row.reserved_minor < p_amount_minor then
    raise exception 'INSUFFICIENT_INTERNAL_AVAILABLE_AMOUNT' using errcode = '22003';
  end if;

  update public.financial_positions
  set reserved_minor = reserved_minor + p_amount_minor
  where id = p_source_position_id;

  insert into public.transfer_review_checks (transfer_id, check_kind)
  select transfer_row.id, check_kind
  from unnest(array['dual_review', 'escalation', 'compliance', 'final_authorization']) as check_kind;

  insert into public.transfer_events (
    transfer_id, actor_id, event_type, to_status, metadata
  )
  values (
    transfer_row.id,
    caller_id,
    'submitted',
    'submitted',
    jsonb_build_object('idempotency_key', p_idempotency_key)
  );

  insert into public.notifications (
    recipient_id, title, message, notification_type
  )
  values (
    caller_id,
    'Instruction enregistrée',
    'Votre instruction a été enregistrée pour contrôle. Aucun transfert bancaire n’a encore été exécuté.',
    'transfer'
  );

  return transfer_row;
end;
$$;


ALTER FUNCTION "public"."submit_transfer_intent"("p_source_position_id" "uuid", "p_recipient_name" "text", "p_recipient_account_masked" "text", "p_beneficiary_details" "jsonb", "p_transfer_type" "text", "p_amount_minor" bigint, "p_currency" "text", "p_target_amount_minor" bigint, "p_target_currency" "text", "p_quote_rate" numeric, "p_quote_as_of" timestamp with time zone, "p_motive" "text", "p_idempotency_key" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."transition_loan"("p_loan_id" "uuid", "p_action" "text", "p_reason" "text" DEFAULT NULL::"text", "p_external_reference" "text" DEFAULT NULL::"text", "p_evidence_object_path" "text" DEFAULT NULL::"text", "p_executed_at" timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS "public"."loan_applications"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_id uuid := (select auth.uid());
  loan_row public.loan_applications;
  old_status text;
  next_status text;
  executor_id uuid;
begin
  if caller_id is null then
    raise exception 'AUTHENTICATION_REQUIRED' using errcode = '42501';
  end if;

  select *
  into loan_row
  from public.loan_applications
  where id = p_loan_id
  for update;

  if not found then
    raise exception 'LOAN_NOT_FOUND' using errcode = 'P0002';
  end if;

  old_status := loan_row.status;

  if p_action = 'cancel' then
    if caller_id <> loan_row.owner_id
       or old_status not in ('submitted', 'under_review', 'approved_for_external_funding') then
      raise exception 'LOAN_CANNOT_BE_CANCELLED' using errcode = '42501';
    end if;
    next_status := 'cancelled';

  elsif p_action = 'reject' then
    if not private.is_active_staff(array['reviewer', 'supervisor', 'admin']) then
      raise exception 'STAFF_PERMISSION_REQUIRED' using errcode = '42501';
    end if;
    if old_status not in ('submitted', 'under_review', 'approved_for_external_funding') then
      raise exception 'LOAN_CANNOT_BE_REJECTED' using errcode = '55000';
    end if;
    if nullif(trim(coalesce(p_reason, '')), '') is null then
      raise exception 'REJECTION_REASON_REQUIRED' using errcode = '22023';
    end if;
    next_status := 'rejected';

  elsif p_action = 'record_external_funding' then
    if not private.is_active_staff(array['operator', 'supervisor', 'admin']) then
      raise exception 'OPERATOR_PERMISSION_REQUIRED' using errcode = '42501';
    end if;
    if old_status <> 'approved_for_external_funding' then
      raise exception 'LOAN_NOT_APPROVED_FOR_EXTERNAL_FUNDING' using errcode = '55000';
    end if;
    if nullif(trim(coalesce(p_external_reference, '')), '') is null
       or nullif(trim(coalesce(p_evidence_object_path, '')), '') is null
       or p_executed_at is null then
      raise exception 'EXTERNAL_FUNDING_EVIDENCE_REQUIRED' using errcode = '22023';
    end if;
    next_status := 'external_funding_recorded';
    insert into public.external_loan_fundings (
      loan_id,
      external_reference,
      evidence_object_path,
      execution_note,
      executed_by,
      executed_at
    )
    values (
      p_loan_id,
      trim(p_external_reference),
      trim(p_evidence_object_path),
      nullif(trim(coalesce(p_reason, '')), ''),
      caller_id,
      p_executed_at
    );

  elsif p_action = 'confirm_external_settlement' then
    if not private.is_active_staff(array['supervisor', 'admin']) then
      raise exception 'SUPERVISOR_PERMISSION_REQUIRED' using errcode = '42501';
    end if;
    if old_status <> 'external_funding_recorded' then
      raise exception 'EXTERNAL_FUNDING_NOT_RECORDED' using errcode = '55000';
    end if;

    select executed_by
    into executor_id
    from public.external_loan_fundings
    where loan_id = p_loan_id
    for update;

    if executor_id = caller_id then
      raise exception 'SECOND_STAFF_MEMBER_REQUIRED' using errcode = '42501';
    end if;

    next_status := 'external_settlement_confirmed';
    update public.external_loan_fundings
    set
      confirmed_by = caller_id,
      confirmed_at = now(),
      confirmation_note = nullif(trim(coalesce(p_reason, '')), '')
    where loan_id = p_loan_id;

  elsif p_action = 'mark_external_failed' then
    if not private.is_active_staff(array['operator', 'supervisor', 'admin']) then
      raise exception 'OPERATOR_PERMISSION_REQUIRED' using errcode = '42501';
    end if;
    if old_status <> 'external_funding_recorded' then
      raise exception 'EXTERNAL_FUNDING_NOT_RECORDED' using errcode = '55000';
    end if;
    if nullif(trim(coalesce(p_reason, '')), '') is null then
      raise exception 'FAILURE_REASON_REQUIRED' using errcode = '22023';
    end if;
    next_status := 'external_failed';

  else
    raise exception 'INVALID_LOAN_ACTION' using errcode = '22023';
  end if;

  update public.loan_applications
  set status = next_status
  where id = p_loan_id
  returning * into loan_row;

  insert into public.loan_events (
    loan_id, actor_id, event_type, from_status, to_status, reason
  )
  values (
    p_loan_id,
    caller_id,
    p_action,
    old_status,
    next_status,
    nullif(trim(coalesce(p_reason, '')), '')
  );

  insert into public.audit_events (
    actor_id, action, entity_type, entity_id, metadata
  )
  values (
    caller_id,
    p_action,
    'loan_application',
    p_loan_id,
    jsonb_build_object('from_status', old_status, 'to_status', next_status)
  );

  insert into public.notifications (
    recipient_id, title, message, notification_type
  )
  values (
    loan_row.owner_id,
    'Demande mise à jour',
    case next_status
      when 'approved_for_external_funding' then 'Votre dossier est autorisé pour traitement externe. Aucun versement n’est encore confirmé.'
      when 'external_funding_recorded' then 'Un versement externe a été déclaré et reste en attente d’un second contrôle.'
      when 'external_settlement_confirmed' then 'Le versement externe a été confirmé manuellement sur justificatif.'
      when 'rejected' then 'Votre demande a été rejetée. Aucun versement n’a été effectué par Monalyz.'
      when 'cancelled' then 'Votre demande a été annulée avant confirmation externe.'
      else 'Le versement externe a été signalé en échec.'
    end,
    'loan'
  );

  return loan_row;
end;
$$;


ALTER FUNCTION "public"."transition_loan"("p_loan_id" "uuid", "p_action" "text", "p_reason" "text", "p_external_reference" "text", "p_evidence_object_path" "text", "p_executed_at" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."transition_transfer"("p_transfer_id" "uuid", "p_action" "text", "p_reason" "text" DEFAULT NULL::"text", "p_external_reference" "text" DEFAULT NULL::"text", "p_evidence_object_path" "text" DEFAULT NULL::"text", "p_executed_at" timestamp with time zone DEFAULT NULL::timestamp with time zone) RETURNS "public"."transfer_intents"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_id uuid := (select auth.uid());
  transfer_row public.transfer_intents;
  old_status text;
  next_status text;
  executor_id uuid;
begin
  if caller_id is null then
    raise exception 'AUTHENTICATION_REQUIRED' using errcode = '42501';
  end if;

  select *
  into transfer_row
  from public.transfer_intents
  where id = p_transfer_id
  for update;

  if not found then
    raise exception 'TRANSFER_NOT_FOUND' using errcode = 'P0002';
  end if;

  old_status := transfer_row.status;

  if p_action = 'cancel' then
    if caller_id <> transfer_row.owner_id
       or old_status not in ('submitted', 'under_review', 'approved_for_external_execution') then
      raise exception 'TRANSFER_CANNOT_BE_CANCELLED' using errcode = '42501';
    end if;
    next_status := 'cancelled';
    update public.financial_positions
    set reserved_minor = reserved_minor - transfer_row.amount_minor
    where id = transfer_row.source_position_id;

  elsif p_action = 'reject' then
    if not private.is_active_staff(array['reviewer', 'supervisor', 'admin']) then
      raise exception 'STAFF_PERMISSION_REQUIRED' using errcode = '42501';
    end if;
    if old_status not in ('submitted', 'under_review', 'approved_for_external_execution') then
      raise exception 'TRANSFER_CANNOT_BE_REJECTED' using errcode = '55000';
    end if;
    if nullif(trim(coalesce(p_reason, '')), '') is null then
      raise exception 'REJECTION_REASON_REQUIRED' using errcode = '22023';
    end if;
    next_status := 'rejected';
    update public.financial_positions
    set reserved_minor = reserved_minor - transfer_row.amount_minor
    where id = transfer_row.source_position_id;

  elsif p_action = 'record_external_execution' then
    if not private.is_active_staff(array['operator', 'supervisor', 'admin']) then
      raise exception 'OPERATOR_PERMISSION_REQUIRED' using errcode = '42501';
    end if;
    if old_status <> 'approved_for_external_execution' then
      raise exception 'TRANSFER_NOT_APPROVED_FOR_EXTERNAL_EXECUTION' using errcode = '55000';
    end if;
    if nullif(trim(coalesce(p_external_reference, '')), '') is null
       or nullif(trim(coalesce(p_evidence_object_path, '')), '') is null
       or p_executed_at is null then
      raise exception 'EXTERNAL_EXECUTION_EVIDENCE_REQUIRED' using errcode = '22023';
    end if;
    next_status := 'external_execution_recorded';
    insert into public.external_transfer_executions (
      transfer_id,
      external_reference,
      evidence_object_path,
      execution_note,
      executed_by,
      executed_at
    )
    values (
      p_transfer_id,
      trim(p_external_reference),
      trim(p_evidence_object_path),
      nullif(trim(coalesce(p_reason, '')), ''),
      caller_id,
      p_executed_at
    );

  elsif p_action = 'confirm_external_settlement' then
    if not private.is_active_staff(array['supervisor', 'admin']) then
      raise exception 'SUPERVISOR_PERMISSION_REQUIRED' using errcode = '42501';
    end if;
    if old_status <> 'external_execution_recorded' then
      raise exception 'EXTERNAL_EXECUTION_NOT_RECORDED' using errcode = '55000';
    end if;

    select executed_by
    into executor_id
    from public.external_transfer_executions
    where transfer_id = p_transfer_id
    for update;

    if executor_id = caller_id then
      raise exception 'SECOND_STAFF_MEMBER_REQUIRED' using errcode = '42501';
    end if;

    next_status := 'external_settlement_confirmed';

    update public.external_transfer_executions
    set
      confirmed_by = caller_id,
      confirmed_at = now(),
      confirmation_note = nullif(trim(coalesce(p_reason, '')), '')
    where transfer_id = p_transfer_id;

    update public.financial_positions
    set
      amount_minor = amount_minor - transfer_row.amount_minor,
      reserved_minor = reserved_minor - transfer_row.amount_minor,
      position_kind = 'internally_reconciled',
      as_of = now()
    where id = transfer_row.source_position_id;

  elsif p_action = 'mark_external_failed' then
    if not private.is_active_staff(array['operator', 'supervisor', 'admin']) then
      raise exception 'OPERATOR_PERMISSION_REQUIRED' using errcode = '42501';
    end if;
    if old_status <> 'external_execution_recorded' then
      raise exception 'EXTERNAL_EXECUTION_NOT_RECORDED' using errcode = '55000';
    end if;
    if nullif(trim(coalesce(p_reason, '')), '') is null then
      raise exception 'FAILURE_REASON_REQUIRED' using errcode = '22023';
    end if;
    next_status := 'external_failed';
    update public.financial_positions
    set reserved_minor = reserved_minor - transfer_row.amount_minor
    where id = transfer_row.source_position_id;

  else
    raise exception 'INVALID_TRANSFER_ACTION' using errcode = '22023';
  end if;

  update public.transfer_intents
  set status = next_status
  where id = p_transfer_id
  returning * into transfer_row;

  insert into public.transfer_events (
    transfer_id, actor_id, event_type, from_status, to_status, reason
  )
  values (
    p_transfer_id,
    caller_id,
    p_action,
    old_status,
    next_status,
    nullif(trim(coalesce(p_reason, '')), '')
  );

  insert into public.audit_events (
    actor_id, action, entity_type, entity_id, metadata
  )
  values (
    caller_id,
    p_action,
    'transfer_intent',
    p_transfer_id,
    jsonb_build_object('from_status', old_status, 'to_status', next_status)
  );

  insert into public.notifications (
    recipient_id, title, message, notification_type
  )
  values (
    transfer_row.owner_id,
    'Instruction mise à jour',
    case next_status
      when 'approved_for_external_execution' then 'Votre instruction est autorisée pour traitement hors application. Aucun mouvement bancaire n’est encore confirmé.'
      when 'external_execution_recorded' then 'Une exécution externe a été déclarée et reste en attente d’un second contrôle.'
      when 'external_settlement_confirmed' then 'Le règlement externe a été confirmé manuellement sur justificatif.'
      when 'rejected' then 'Votre instruction a été rejetée. Aucun mouvement bancaire n’a été effectué par Monalyz.'
      when 'cancelled' then 'Votre instruction a été annulée avant confirmation externe.'
      else 'L’exécution externe a été signalée en échec.'
    end,
    'transfer'
  );

  return transfer_row;
end;
$$;


ALTER FUNCTION "public"."transition_transfer"("p_transfer_id" "uuid", "p_action" "text", "p_reason" "text", "p_external_reference" "text", "p_evidence_object_path" "text", "p_executed_at" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."unregister_push_subscription"("p_expected_user_id" "uuid", "p_endpoint" "text") RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_id uuid := (select auth.uid());
  normalized_endpoint text := btrim(coalesce(p_endpoint, ''));
  calculated_hash text;
  deleted_count integer;
begin
  if caller_id is null then
    raise exception 'AUTHENTICATION_REQUIRED' using errcode = '42501';
  end if;

  if p_expected_user_id is null or p_expected_user_id <> caller_id then
    raise exception 'PUSH_SUBSCRIPTION_ACCOUNT_CHANGED' using errcode = '42501';
  end if;

  if char_length(normalized_endpoint) not between 20 and 2048
     or normalized_endpoint !~ '^https://'
  then
    raise exception 'INVALID_PUSH_ENDPOINT' using errcode = '22023';
  end if;

  calculated_hash := encode(
    extensions.digest(convert_to(normalized_endpoint, 'UTF8'), 'sha256'),
    'hex'
  );

  delete from public.push_subscriptions
  where user_id = caller_id
    and endpoint_hash = calculated_hash
    and endpoint = normalized_endpoint;

  get diagnostics deleted_count = row_count;
  return deleted_count = 1;
end;
$$;


ALTER FUNCTION "public"."unregister_push_subscription"("p_expected_user_id" "uuid", "p_endpoint" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."kyc_review_checklists" (
    "kyc_id" "uuid" NOT NULL,
    "document_quality" "text" DEFAULT 'pending'::"text" NOT NULL,
    "data_consistency" "text" DEFAULT 'pending'::"text" NOT NULL,
    "selfie_match" "text" DEFAULT 'pending'::"text" NOT NULL,
    "adulthood" "text" DEFAULT 'pending'::"text" NOT NULL,
    "fatca" "text" DEFAULT 'pending'::"text" NOT NULL,
    "pep" "text" DEFAULT 'pending'::"text" NOT NULL,
    "internal_comments" "text",
    "updated_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "kyc_review_checklists_comments_check" CHECK ((("internal_comments" IS NULL) OR ("char_length"("internal_comments") <= 2000))),
    CONSTRAINT "kyc_review_checklists_states_check" CHECK ((("document_quality" = ANY (ARRAY['pending'::"text", 'compliant'::"text", 'non_compliant'::"text"])) AND ("data_consistency" = ANY (ARRAY['pending'::"text", 'compliant'::"text", 'non_compliant'::"text"])) AND ("selfie_match" = ANY (ARRAY['pending'::"text", 'compliant'::"text", 'non_compliant'::"text", 'not_applicable'::"text"])) AND ("adulthood" = ANY (ARRAY['pending'::"text", 'compliant'::"text", 'non_compliant'::"text"])) AND ("fatca" = ANY (ARRAY['pending'::"text", 'compliant'::"text", 'non_compliant'::"text"])) AND ("pep" = ANY (ARRAY['pending'::"text", 'compliant'::"text", 'non_compliant'::"text"]))))
);


ALTER TABLE "public"."kyc_review_checklists" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_kyc_review_checklist"("p_kyc_id" "uuid", "p_document_quality" "text", "p_data_consistency" "text", "p_selfie_match" "text", "p_adulthood" "text", "p_fatca" "text", "p_pep" "text", "p_internal_comments" "text") RETURNS "public"."kyc_review_checklists"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $$
declare
  caller_id uuid := (select auth.uid());
  checklist_row public.kyc_review_checklists;
  has_selfie boolean;
begin
  if caller_id is null
     or not private.is_active_staff(array['reviewer', 'supervisor', 'admin']) then
    raise exception 'STAFF_PERMISSION_REQUIRED' using errcode = '42501';
  end if;

  select application.document_object_paths ? 'selfie'
  into has_selfie
  from public.kyc_applications as application
  where application.id = p_kyc_id
    and application.status = 'under_review'
  for update;

  if not found then
    raise exception 'KYC_NOT_UNDER_REVIEW' using errcode = '55000';
  end if;
  if has_selfie and p_selfie_match = 'not_applicable' then
    raise exception 'INVALID_KYC_SELFIE_REVIEW_STATE' using errcode = '22023';
  end if;

  update public.kyc_review_checklists
  set
    document_quality = p_document_quality,
    data_consistency = p_data_consistency,
    selfie_match = case
      when has_selfie then p_selfie_match
      else 'not_applicable'
    end,
    adulthood = p_adulthood,
    fatca = p_fatca,
    pep = p_pep,
    internal_comments = nullif(trim(coalesce(p_internal_comments, '')), ''),
    updated_by = caller_id
  where kyc_id = p_kyc_id
  returning * into checklist_row;

  if not found then
    raise exception 'KYC_CHECKLIST_NOT_FOUND' using errcode = 'P0002';
  end if;
  return checklist_row;
end;
$$;


ALTER FUNCTION "public"."update_kyc_review_checklist"("p_kyc_id" "uuid", "p_document_quality" "text", "p_data_consistency" "text", "p_selfie_match" "text", "p_adulthood" "text", "p_fatca" "text", "p_pep" "text", "p_internal_comments" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."loan_product_settings" (
    "currency" "text" NOT NULL,
    "minimum_amount_minor" bigint NOT NULL,
    "maximum_amount_minor" bigint NOT NULL,
    "minimum_duration_months" integer NOT NULL,
    "maximum_duration_months" integer NOT NULL,
    "duration_step_months" integer NOT NULL,
    "fixed_annual_rate" numeric(8,5) NOT NULL,
    "reference_prefix" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "updated_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "loan_product_settings_amount_range_check" CHECK ((("minimum_amount_minor" > 0) AND ("minimum_amount_minor" < "maximum_amount_minor") AND ("maximum_amount_minor" <= '1000000000000000'::bigint))),
    CONSTRAINT "loan_product_settings_currency_check" CHECK (("currency" = ANY (ARRAY['EUR'::"text", 'USD'::"text", 'CAD'::"text", 'CHF'::"text", 'GBP'::"text"]))),
    CONSTRAINT "loan_product_settings_duration_range_check" CHECK ((("minimum_duration_months" > 0) AND ("minimum_duration_months" <= "maximum_duration_months") AND ("maximum_duration_months" <= 600) AND ("duration_step_months" > 0) AND ((("maximum_duration_months" - "minimum_duration_months") % "duration_step_months") = 0))),
    CONSTRAINT "loan_product_settings_fixed_annual_rate_check" CHECK ((("fixed_annual_rate" >= (0)::numeric) AND ("fixed_annual_rate" <= (1)::numeric))),
    CONSTRAINT "loan_product_settings_reference_prefix_check" CHECK (("reference_prefix" ~ '^[A-Za-z0-9_-]{1,24}$'::"text"))
);


ALTER TABLE "public"."loan_product_settings" OWNER TO "postgres";


COMMENT ON TABLE "public"."loan_product_settings" IS 'Server-authoritative loan limits, fixed annual rate, and reference prefix by currency.';



COMMENT ON COLUMN "public"."loan_product_settings"."fixed_annual_rate" IS 'Annual rate represented as a decimal; 0.035 means 3.5 percent.';



CREATE OR REPLACE FUNCTION "public"."update_loan_product_settings"("p_currency" "text", "p_minimum_amount_minor" bigint, "p_maximum_amount_minor" bigint, "p_minimum_duration_months" integer, "p_maximum_duration_months" integer, "p_duration_step_months" integer, "p_fixed_annual_rate" numeric, "p_reference_prefix" "text", "p_is_active" boolean) RETURNS "public"."loan_product_settings"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO ''
    AS $_$
declare
  caller_id uuid := private.ensure_branch_manager();
  normalized_currency text := upper(trim(coalesce(p_currency, '')));
  normalized_prefix text := trim(coalesce(p_reference_prefix, ''));
  previous_settings public.loan_product_settings;
  updated_settings public.loan_product_settings;
begin
  if normalized_currency not in ('EUR', 'USD', 'CAD', 'CHF', 'GBP') then
    raise exception 'INVALID_LOAN_PRODUCT_CURRENCY' using errcode = '22023';
  end if;
  if p_minimum_amount_minor is null
    or p_maximum_amount_minor is null
    or p_minimum_amount_minor <= 0
    or p_minimum_amount_minor >= p_maximum_amount_minor
    or p_maximum_amount_minor > 1000000000000000
  then
    raise exception 'INVALID_LOAN_AMOUNT_RANGE' using errcode = '22023';
  end if;
  if p_minimum_duration_months is null
    or p_maximum_duration_months is null
    or p_minimum_duration_months <= 0
    or p_minimum_duration_months > p_maximum_duration_months
    or p_maximum_duration_months > 600
  then
    raise exception 'INVALID_LOAN_DURATION_RANGE' using errcode = '22023';
  end if;
  if p_duration_step_months is null
    or p_duration_step_months <= 0
    or (
      (p_maximum_duration_months - p_minimum_duration_months)
      % p_duration_step_months
    ) <> 0
  then
    raise exception 'INVALID_LOAN_DURATION_STEP' using errcode = '22023';
  end if;
  if p_fixed_annual_rate is null
    or p_fixed_annual_rate < 0
    or p_fixed_annual_rate > 1
  then
    raise exception 'INVALID_LOAN_ANNUAL_RATE' using errcode = '22023';
  end if;
  if normalized_prefix !~ '^[A-Za-z0-9_-]{1,24}$' then
    raise exception 'INVALID_LOAN_REFERENCE_PREFIX' using errcode = '22023';
  end if;
  if p_is_active is null then
    raise exception 'INVALID_LOAN_PRODUCT_STATUS' using errcode = '22023';
  end if;

  select *
  into previous_settings
  from public.loan_product_settings
  where currency = normalized_currency
  for update;

  if previous_settings.currency is null then
    raise exception 'LOAN_PRODUCT_NOT_FOUND' using errcode = 'P0002';
  end if;

  update public.loan_product_settings
  set
    minimum_amount_minor = p_minimum_amount_minor,
    maximum_amount_minor = p_maximum_amount_minor,
    minimum_duration_months = p_minimum_duration_months,
    maximum_duration_months = p_maximum_duration_months,
    duration_step_months = p_duration_step_months,
    fixed_annual_rate = p_fixed_annual_rate,
    reference_prefix = normalized_prefix,
    is_active = p_is_active,
    updated_by = caller_id
  where currency = normalized_currency
  returning * into updated_settings;

  insert into public.audit_events (
    actor_id,
    action,
    entity_type,
    entity_id,
    metadata
  ) values (
    caller_id,
    'branch_manager_update_loan_product_settings',
    'loan_product_settings',
    null,
    jsonb_build_object(
      'currency', normalized_currency,
      'before', to_jsonb(previous_settings),
      'after', to_jsonb(updated_settings)
    )
  );

  return updated_settings;
end;
$_$;


ALTER FUNCTION "public"."update_loan_product_settings"("p_currency" "text", "p_minimum_amount_minor" bigint, "p_maximum_amount_minor" bigint, "p_minimum_duration_months" integer, "p_maximum_duration_months" integer, "p_duration_step_months" integer, "p_fixed_annual_rate" numeric, "p_reference_prefix" "text", "p_is_active" boolean) OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "private"."account_number_configuration" (
    "singleton" boolean DEFAULT true NOT NULL,
    "prefix" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_by" "uuid" NOT NULL,
    CONSTRAINT "account_number_configuration_prefix_check" CHECK (("prefix" ~ '^[0-9]{5,9}$'::"text")),
    CONSTRAINT "account_number_configuration_singleton_check" CHECK ("singleton")
);


ALTER TABLE "private"."account_number_configuration" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "private"."client_purge_entity_manifest" (
    "challenge_id" "uuid" NOT NULL,
    "entity_type" "text" NOT NULL,
    "entity_id" "text" NOT NULL,
    CONSTRAINT "client_purge_entity_manifest_entity_id_check" CHECK ((("char_length"("entity_id") >= 1) AND ("char_length"("entity_id") <= 100)))
);


ALTER TABLE "private"."client_purge_entity_manifest" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "private"."client_purge_operations" (
    "challenge_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "actor_id" "uuid" NOT NULL,
    "target_user_id" "uuid" NOT NULL,
    "challenge_digest" "text" NOT NULL,
    "target_email_digest" "text" NOT NULL,
    "target_email" "text" NOT NULL,
    "idempotency_key" "uuid" NOT NULL,
    "status" "text" DEFAULT 'preview'::"text" NOT NULL,
    "stage" "text" DEFAULT 'preview'::"text" NOT NULL,
    "support_email_manifest" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "scope_digest" "text",
    "storage_cycle_stage" "text",
    "storage_phase" "text" DEFAULT 'idle'::"text" NOT NULL,
    "reference_after_bucket" "text",
    "reference_after_object_path" "text",
    "reference_claim_token" "uuid",
    "reference_claimed_at" timestamp with time zone,
    "verify_prefix_index" integer DEFAULT 0 NOT NULL,
    "prefix_claim_token" "uuid",
    "prefix_claimed_at" timestamp with time zone,
    "ignored_unsafe_storage_references" bigint DEFAULT 0 NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "consumed_at" timestamp with time zone,
    "sweep_not_before" timestamp with time zone,
    "retry_after" timestamp with time zone,
    "last_error_code" "text",
    "created_at" timestamp with time zone DEFAULT "statement_timestamp"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "statement_timestamp"() NOT NULL,
    CONSTRAINT "client_purge_operations_challenge_digest_check" CHECK (("challenge_digest" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "client_purge_operations_check" CHECK (("expires_at" > "created_at")),
    CONSTRAINT "client_purge_operations_check1" CHECK ((("status" = 'preview'::"text") = ("consumed_at" IS NULL))),
    CONSTRAINT "client_purge_operations_check2" CHECK ((("reference_after_bucket" IS NULL) = ("reference_after_object_path" IS NULL))),
    CONSTRAINT "client_purge_operations_check3" CHECK ((("reference_claim_token" IS NULL) = ("reference_claimed_at" IS NULL))),
    CONSTRAINT "client_purge_operations_check4" CHECK ((("prefix_claim_token" IS NULL) = ("prefix_claimed_at" IS NULL))),
    CONSTRAINT "client_purge_operations_check5" CHECK ((("sweep_not_before" IS NULL) OR ("stage" = ANY (ARRAY['waiting_sweep'::"text", 'storage_sweep'::"text", 'auth'::"text", 'verify'::"text"])))),
    CONSTRAINT "client_purge_operations_ignored_unsafe_storage_references_check" CHECK (("ignored_unsafe_storage_references" >= 0)),
    CONSTRAINT "client_purge_operations_last_error_code_check" CHECK ((("last_error_code" IS NULL) OR ("char_length"("last_error_code") <= 100))),
    CONSTRAINT "client_purge_operations_scope_digest_check" CHECK ((("scope_digest" IS NULL) OR ("scope_digest" ~ '^[0-9a-f]{64}$'::"text"))),
    CONSTRAINT "client_purge_operations_stage_check" CHECK (("stage" = ANY (ARRAY['preview'::"text", 'storage'::"text", 'database'::"text", 'waiting_sweep'::"text", 'storage_sweep'::"text", 'auth'::"text", 'verify'::"text"]))),
    CONSTRAINT "client_purge_operations_status_check" CHECK (("status" = ANY (ARRAY['preview'::"text", 'running'::"text", 'failed'::"text", 'waiting_sweep'::"text"]))),
    CONSTRAINT "client_purge_operations_storage_cycle_stage_check" CHECK (("storage_cycle_stage" = ANY (ARRAY['preview'::"text", 'storage'::"text", 'storage_sweep'::"text", 'verify'::"text"]))),
    CONSTRAINT "client_purge_operations_storage_phase_check" CHECK (("storage_phase" = ANY (ARRAY['idle'::"text", 'references'::"text", 'scan'::"text", 'delete'::"text", 'verify_manifest'::"text", 'verify_prefix'::"text", 'complete'::"text"]))),
    CONSTRAINT "client_purge_operations_support_email_manifest_check" CHECK (("jsonb_typeof"("support_email_manifest") = 'array'::"text")),
    CONSTRAINT "client_purge_operations_target_email_check" CHECK (((("char_length"("target_email") >= 3) AND ("char_length"("target_email") <= 254)) AND ("target_email" = "btrim"("target_email")))),
    CONSTRAINT "client_purge_operations_target_email_digest_check" CHECK (("target_email_digest" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "client_purge_operations_verify_prefix_index_check" CHECK ((("verify_prefix_index" >= 0) AND ("verify_prefix_index" <= 4)))
);


ALTER TABLE "private"."client_purge_operations" OWNER TO "postgres";


COMMENT ON TABLE "private"."client_purge_operations" IS 'Ephemeral private state for one-use erasure challenges and resumable failures. Deleted after success.';



CREATE TABLE IF NOT EXISTS "private"."client_purge_storage_manifest" (
    "challenge_id" "uuid" NOT NULL,
    "bucket" "text" NOT NULL,
    "object_path" "text" NOT NULL,
    "ownership_scope" "text" NOT NULL,
    "processing_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "claim_token" "uuid",
    "claimed_at" timestamp with time zone,
    "deleted_at" timestamp with time zone,
    "verified_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "statement_timestamp"() NOT NULL,
    CONSTRAINT "client_purge_storage_manifest_bucket_check" CHECK (("bucket" = ANY (ARRAY['upload-staging'::"text", 'kyc-evidence'::"text", 'loan-evidence'::"text", 'external-execution-evidence'::"text", 'official-documents'::"text"]))),
    CONSTRAINT "client_purge_storage_manifest_check" CHECK ((("ownership_scope" = 'relational'::"text") = ("bucket" = 'external-execution-evidence'::"text"))),
    CONSTRAINT "client_purge_storage_manifest_check1" CHECK ((("processing_status" = ANY (ARRAY['delete_claimed'::"text", 'verify_claimed'::"text"])) = (("claim_token" IS NOT NULL) AND ("claimed_at" IS NOT NULL)))),
    CONSTRAINT "client_purge_storage_manifest_object_path_check" CHECK ((("char_length"("object_path") >= 1) AND ("char_length"("object_path") <= 500))),
    CONSTRAINT "client_purge_storage_manifest_ownership_scope_check" CHECK (("ownership_scope" = ANY (ARRAY['target_prefix'::"text", 'relational'::"text"]))),
    CONSTRAINT "client_purge_storage_manifest_processing_status_check" CHECK (("processing_status" = ANY (ARRAY['pending'::"text", 'delete_claimed'::"text", 'deleted'::"text", 'verify_claimed'::"text", 'verified'::"text"])))
);


ALTER TABLE "private"."client_purge_storage_manifest" OWNER TO "postgres";


COMMENT ON TABLE "private"."client_purge_storage_manifest" IS 'Normalized, page-written Storage inventory retained only until guarded erasure succeeds.';



CREATE TABLE IF NOT EXISTS "private"."client_purge_storage_scan_queue" (
    "id" bigint NOT NULL,
    "challenge_id" "uuid" NOT NULL,
    "cycle_stage" "text" NOT NULL,
    "bucket" "text" NOT NULL,
    "prefix" "text" NOT NULL,
    "next_offset" integer DEFAULT 0 NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "claim_token" "uuid",
    "claimed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "statement_timestamp"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "statement_timestamp"() NOT NULL,
    CONSTRAINT "client_purge_storage_scan_queue_bucket_check" CHECK (("bucket" = ANY (ARRAY['upload-staging'::"text", 'kyc-evidence'::"text", 'loan-evidence'::"text", 'official-documents'::"text"]))),
    CONSTRAINT "client_purge_storage_scan_queue_check" CHECK ((("status" = 'claimed'::"text") = (("claim_token" IS NOT NULL) AND ("claimed_at" IS NOT NULL)))),
    CONSTRAINT "client_purge_storage_scan_queue_cycle_stage_check" CHECK (("cycle_stage" = ANY (ARRAY['preview'::"text", 'storage'::"text", 'storage_sweep'::"text", 'verify'::"text"]))),
    CONSTRAINT "client_purge_storage_scan_queue_next_offset_check" CHECK (("next_offset" >= 0)),
    CONSTRAINT "client_purge_storage_scan_queue_prefix_check" CHECK ((("char_length"("prefix") >= 1) AND ("char_length"("prefix") <= 500))),
    CONSTRAINT "client_purge_storage_scan_queue_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'claimed'::"text", 'done'::"text"])))
);


ALTER TABLE "private"."client_purge_storage_scan_queue" OWNER TO "postgres";


ALTER TABLE "private"."client_purge_storage_scan_queue" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "private"."client_purge_storage_scan_queue_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."audit_events" (
    "id" bigint NOT NULL,
    "actor_id" "uuid",
    "action" "text" NOT NULL,
    "entity_type" "text" NOT NULL,
    "entity_id" "uuid",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "audit_events_metadata_check" CHECK (("jsonb_typeof"("metadata") = 'object'::"text"))
);


ALTER TABLE "public"."audit_events" OWNER TO "postgres";


ALTER TABLE "public"."audit_events" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."audit_events_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."external_loan_fundings" (
    "loan_id" "uuid" NOT NULL,
    "external_reference" "text" NOT NULL,
    "evidence_object_path" "text" NOT NULL,
    "execution_note" "text",
    "executed_by" "uuid" NOT NULL,
    "executed_at" timestamp with time zone NOT NULL,
    "recorded_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "confirmed_by" "uuid",
    "confirmed_at" timestamp with time zone,
    "confirmation_note" "text",
    CONSTRAINT "external_loan_fundings_check" CHECK ((("confirmed_by" IS NULL) OR ("confirmed_by" <> "executed_by"))),
    CONSTRAINT "external_loan_fundings_check1" CHECK (((("confirmed_by" IS NULL) AND ("confirmed_at" IS NULL)) OR (("confirmed_by" IS NOT NULL) AND ("confirmed_at" IS NOT NULL)))),
    CONSTRAINT "external_loan_fundings_confirmation_note_check" CHECK ((("confirmation_note" IS NULL) OR ("char_length"("confirmation_note") <= 1000))),
    CONSTRAINT "external_loan_fundings_evidence_object_path_check" CHECK ((("char_length"("evidence_object_path") >= 3) AND ("char_length"("evidence_object_path") <= 500))),
    CONSTRAINT "external_loan_fundings_execution_note_check" CHECK ((("execution_note" IS NULL) OR ("char_length"("execution_note") <= 1000))),
    CONSTRAINT "external_loan_fundings_external_reference_check" CHECK ((("char_length"("external_reference") >= 3) AND ("char_length"("external_reference") <= 160)))
);


ALTER TABLE "public"."external_loan_fundings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."external_transfer_executions" (
    "transfer_id" "uuid" NOT NULL,
    "external_reference" "text" NOT NULL,
    "evidence_object_path" "text" NOT NULL,
    "execution_note" "text",
    "executed_by" "uuid" NOT NULL,
    "executed_at" timestamp with time zone NOT NULL,
    "recorded_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "confirmed_by" "uuid",
    "confirmed_at" timestamp with time zone,
    "confirmation_note" "text",
    CONSTRAINT "external_transfer_executions_check" CHECK ((("confirmed_by" IS NULL) OR ("confirmed_by" <> "executed_by"))),
    CONSTRAINT "external_transfer_executions_check1" CHECK (((("confirmed_by" IS NULL) AND ("confirmed_at" IS NULL)) OR (("confirmed_by" IS NOT NULL) AND ("confirmed_at" IS NOT NULL)))),
    CONSTRAINT "external_transfer_executions_confirmation_note_check" CHECK ((("confirmation_note" IS NULL) OR ("char_length"("confirmation_note") <= 1000))),
    CONSTRAINT "external_transfer_executions_evidence_object_path_check" CHECK ((("char_length"("evidence_object_path") >= 3) AND ("char_length"("evidence_object_path") <= 500))),
    CONSTRAINT "external_transfer_executions_execution_note_check" CHECK ((("execution_note" IS NULL) OR ("char_length"("execution_note") <= 1000))),
    CONSTRAINT "external_transfer_executions_external_reference_check" CHECK ((("char_length"("external_reference") >= 3) AND ("char_length"("external_reference") <= 160)))
);


ALTER TABLE "public"."external_transfer_executions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."financial_ledger_entries" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "account_id" "uuid" NOT NULL,
    "owner_id" "uuid" NOT NULL,
    "sequence_no" bigint NOT NULL,
    "entry_key" "text" NOT NULL,
    "entry_kind" "text" NOT NULL,
    "amount_minor" bigint NOT NULL,
    "currency" "text" NOT NULL,
    "balance_before_minor" bigint NOT NULL,
    "balance_after_minor" bigint NOT NULL,
    "value_date" timestamp with time zone NOT NULL,
    "booked_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "internal_reference" "text",
    "source_transfer_id" "uuid",
    "source_loan_id" "uuid",
    "booked_by" "uuid",
    "description" "text" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "financial_ledger_entries_balance_after_minor_check" CHECK (("balance_after_minor" >= 0)),
    CONSTRAINT "financial_ledger_entries_balance_before_minor_check" CHECK (("balance_before_minor" >= 0)),
    CONSTRAINT "financial_ledger_entries_check" CHECK (("balance_after_minor" = ("balance_before_minor" + "amount_minor"))),
    CONSTRAINT "financial_ledger_entries_check1" CHECK ((("amount_minor" <> 0) OR ("entry_kind" = ANY (ARRAY['migration_opening_balance'::"text", 'account_opening'::"text"])))),
    CONSTRAINT "financial_ledger_entries_check2" CHECK (((("entry_kind" = 'transfer_debit'::"text") AND ("source_transfer_id" IS NOT NULL) AND ("source_loan_id" IS NULL) AND ("amount_minor" < 0)) OR (("entry_kind" = 'loan_credit'::"text") AND ("source_loan_id" IS NOT NULL) AND ("source_transfer_id" IS NULL) AND ("amount_minor" > 0)) OR (("entry_kind" = ANY (ARRAY['migration_opening_balance'::"text", 'account_opening'::"text", 'manual_adjustment'::"text"])) AND ("source_transfer_id" IS NULL) AND ("source_loan_id" IS NULL)))),
    CONSTRAINT "financial_ledger_entries_currency_check" CHECK (("currency" ~ '^[A-Z]{3}$'::"text")),
    CONSTRAINT "financial_ledger_entries_description_check" CHECK ((("char_length"("description") >= 3) AND ("char_length"("description") <= 1000))),
    CONSTRAINT "financial_ledger_entries_entry_key_check" CHECK ((("char_length"("entry_key") >= 3) AND ("char_length"("entry_key") <= 220))),
    CONSTRAINT "financial_ledger_entries_entry_kind_check" CHECK (("entry_kind" = ANY (ARRAY['migration_opening_balance'::"text", 'account_opening'::"text", 'manual_adjustment'::"text", 'transfer_debit'::"text", 'loan_credit'::"text"]))),
    CONSTRAINT "financial_ledger_entries_internal_reference_check" CHECK ((("internal_reference" IS NULL) OR (("char_length"("internal_reference") >= 3) AND ("char_length"("internal_reference") <= 160)))),
    CONSTRAINT "financial_ledger_entries_metadata_check" CHECK (("jsonb_typeof"("metadata") = 'object'::"text")),
    CONSTRAINT "financial_ledger_entries_sequence_no_check" CHECK (("sequence_no" > 0))
);


ALTER TABLE "public"."financial_ledger_entries" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."kyc_events" (
    "id" bigint NOT NULL,
    "kyc_id" "uuid" NOT NULL,
    "actor_id" "uuid" NOT NULL,
    "event_type" "text" NOT NULL,
    "from_status" "text",
    "to_status" "text",
    "reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "kyc_events_reason_check" CHECK ((("reason" IS NULL) OR ("char_length"("reason") <= 1000)))
);


ALTER TABLE "public"."kyc_events" OWNER TO "postgres";


ALTER TABLE "public"."kyc_events" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."kyc_events_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."loan_events" (
    "id" bigint NOT NULL,
    "loan_id" "uuid" NOT NULL,
    "actor_id" "uuid" NOT NULL,
    "event_type" "text" NOT NULL,
    "from_status" "text",
    "to_status" "text",
    "reason" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "loan_events_metadata_check" CHECK (("jsonb_typeof"("metadata") = 'object'::"text")),
    CONSTRAINT "loan_events_reason_check" CHECK ((("reason" IS NULL) OR ("char_length"("reason") <= 1000)))
);


ALTER TABLE "public"."loan_events" OWNER TO "postgres";


ALTER TABLE "public"."loan_events" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."loan_events_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."loan_review_checks" (
    "id" bigint NOT NULL,
    "loan_id" "uuid" NOT NULL,
    "check_kind" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "reviewer_id" "uuid",
    "note" "text",
    "reviewed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "loan_review_checks_check_kind_check" CHECK (("check_kind" = ANY (ARRAY['dual_review'::"text", 'escalation'::"text", 'compliance'::"text", 'final_authorization'::"text"]))),
    CONSTRAINT "loan_review_checks_note_check" CHECK ((("note" IS NULL) OR ("char_length"("note") <= 1000))),
    CONSTRAINT "loan_review_checks_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'in_progress'::"text", 'completed'::"text", 'failed'::"text"])))
);


ALTER TABLE "public"."loan_review_checks" OWNER TO "postgres";


ALTER TABLE "public"."loan_review_checks" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."loan_review_checks_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "recipient_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "message" "text" NOT NULL,
    "notification_type" "text" NOT NULL,
    "read_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "action_path" "text",
    "message_key" "text" NOT NULL,
    "message_params" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    CONSTRAINT "notifications_action_path_check" CHECK ((("action_path" IS NULL) OR ((("char_length"("action_path") >= 1) AND ("char_length"("action_path") <= 500)) AND ("action_path" ~~ '/%'::"text") AND ("action_path" !~~ '//%'::"text")))),
    CONSTRAINT "notifications_message_check" CHECK ((("char_length"("message") >= 1) AND ("char_length"("message") <= 1000))),
    CONSTRAINT "notifications_message_key_check" CHECK (("message_key" = ANY (ARRAY['generic_info'::"text", 'transfer_submitted'::"text", 'transfer_approved'::"text", 'transfer_completed'::"text", 'transfer_rejected'::"text", 'transfer_failed'::"text", 'loan_submitted'::"text", 'loan_approved'::"text", 'loan_disbursed'::"text", 'loan_rejected'::"text", 'loan_failed'::"text", 'kyc_submitted'::"text", 'kyc_information_requested'::"text", 'kyc_resubmitted'::"text", 'kyc_approved'::"text", 'kyc_rejected'::"text", 'document_available'::"text"]))),
    CONSTRAINT "notifications_message_params_check" CHECK (("jsonb_typeof"("message_params") = 'object'::"text")),
    CONSTRAINT "notifications_notification_type_check" CHECK (("notification_type" = ANY (ARRAY['info'::"text", 'success'::"text", 'alert'::"text", 'transfer'::"text", 'loan'::"text", 'kyc'::"text"]))),
    CONSTRAINT "notifications_title_check" CHECK ((("char_length"("title") >= 1) AND ("char_length"("title") <= 160)))
);


ALTER TABLE "public"."notifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."push_subscriptions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "endpoint" "text" NOT NULL,
    "endpoint_hash" "text" NOT NULL,
    "p256dh" "text" NOT NULL,
    "auth_key" "text" NOT NULL,
    "expiration_time" bigint,
    "user_agent" "text",
    "last_success_at" timestamp with time zone,
    "failure_count" integer DEFAULT 0 NOT NULL,
    "last_error" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "push_subscriptions_auth_key_check" CHECK (((("char_length"("auth_key") >= 10) AND ("char_length"("auth_key") <= 100)) AND ("auth_key" ~ '^[A-Za-z0-9_-]+={0,2}$'::"text"))),
    CONSTRAINT "push_subscriptions_endpoint_check" CHECK (((("char_length"("endpoint") >= 20) AND ("char_length"("endpoint") <= 2048)) AND ("endpoint" ~ '^https://'::"text"))),
    CONSTRAINT "push_subscriptions_endpoint_hash_check" CHECK (("endpoint_hash" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "push_subscriptions_expiration_check" CHECK ((("expiration_time" IS NULL) OR ("expiration_time" > 0))),
    CONSTRAINT "push_subscriptions_failure_count_check" CHECK ((("failure_count" >= 0) AND ("failure_count" <= 1000000))),
    CONSTRAINT "push_subscriptions_last_error_check" CHECK ((("last_error" IS NULL) OR ("char_length"("last_error") <= 1000))),
    CONSTRAINT "push_subscriptions_p256dh_check" CHECK (((("char_length"("p256dh") >= 40) AND ("char_length"("p256dh") <= 200)) AND ("p256dh" ~ '^[A-Za-z0-9_-]+={0,2}$'::"text"))),
    CONSTRAINT "push_subscriptions_user_agent_check" CHECK ((("user_agent" IS NULL) OR ("char_length"("user_agent") <= 500)))
);


ALTER TABLE "public"."push_subscriptions" OWNER TO "postgres";


COMMENT ON TABLE "public"."push_subscriptions" IS 'Server-managed Web Push subscriptions; one endpoint belongs to exactly one current user.';



CREATE TABLE IF NOT EXISTS "public"."staff_members" (
    "user_id" "uuid" NOT NULL,
    "role" "text" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "staff_members_role_check" CHECK (("role" = ANY (ARRAY['reviewer'::"text", 'operator'::"text", 'supervisor'::"text", 'admin'::"text"])))
);


ALTER TABLE "public"."staff_members" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."support_push_deliveries" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "transcript_id" "uuid" NOT NULL,
    "subscription_id" "uuid",
    "endpoint_hash_snapshot" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "attempts" integer DEFAULT 0 NOT NULL,
    "last_http_status" integer,
    "last_error" "text",
    "sent_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "support_push_deliveries_attempts_check" CHECK ((("attempts" >= 0) AND ("attempts" <= 100))),
    CONSTRAINT "support_push_deliveries_endpoint_hash_check" CHECK (("endpoint_hash_snapshot" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "support_push_deliveries_http_status_check" CHECK ((("last_http_status" IS NULL) OR (("last_http_status" >= 100) AND ("last_http_status" <= 599)))),
    CONSTRAINT "support_push_deliveries_last_error_check" CHECK ((("last_error" IS NULL) OR ("char_length"("last_error") <= 1000))),
    CONSTRAINT "support_push_deliveries_sent_check" CHECK ((("status" = 'sent'::"text") = ("sent_at" IS NOT NULL))),
    CONSTRAINT "support_push_deliveries_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'failed'::"text", 'sent'::"text", 'expired'::"text", 'invalid'::"text"])))
);


ALTER TABLE "public"."support_push_deliveries" OWNER TO "postgres";


COMMENT ON TABLE "public"."support_push_deliveries" IS 'Per-device idempotent Web Push delivery state for support transcripts.';



CREATE TABLE IF NOT EXISTS "public"."support_transcripts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "tawk_event_id" "text" NOT NULL,
    "tawk_property_id" "text" NOT NULL,
    "tawk_chat_id" "text" NOT NULL,
    "visitor_email_normalized" "text",
    "identity_status" "text" NOT NULL,
    "identity_error" "text",
    "notification_email" "text",
    "notification_language" "text",
    "notification_display_name" "text",
    "event_at" timestamp with time zone NOT NULL,
    "payload" "jsonb" NOT NULL,
    "raw_body" "text" NOT NULL,
    "raw_body_sha256" "text" NOT NULL,
    "email_request_payload" "jsonb",
    "email_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "email_attempts" integer DEFAULT 0 NOT NULL,
    "email_provider_message_id" "text",
    "email_last_error" "text",
    "email_sent_at" timestamp with time zone,
    "processing_token" "uuid",
    "processing_started_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "support_transcripts_chat_id_check" CHECK ((("char_length"("tawk_chat_id") >= 1) AND ("char_length"("tawk_chat_id") <= 200))),
    CONSTRAINT "support_transcripts_email_attempts_check" CHECK ((("email_attempts" >= 0) AND ("email_attempts" <= 100))),
    CONSTRAINT "support_transcripts_email_identity_check" CHECK ((("email_status" = 'skipped'::"text") = ("identity_status" <> 'resolved'::"text"))),
    CONSTRAINT "support_transcripts_email_last_error_check" CHECK ((("email_last_error" IS NULL) OR ("char_length"("email_last_error") <= 1000))),
    CONSTRAINT "support_transcripts_email_provider_id_check" CHECK ((("email_provider_message_id" IS NULL) OR ("char_length"("email_provider_message_id") <= 500))),
    CONSTRAINT "support_transcripts_email_request_check" CHECK ((("email_request_payload" IS NULL) OR (("identity_status" = 'resolved'::"text") AND ("notification_email" IS NOT NULL) AND ("jsonb_typeof"("email_request_payload") = 'object'::"text")))),
    CONSTRAINT "support_transcripts_email_sent_check" CHECK ((("email_status" = 'sent'::"text") = ("email_sent_at" IS NOT NULL))),
    CONSTRAINT "support_transcripts_email_status_check" CHECK (("email_status" = ANY (ARRAY['pending'::"text", 'failed'::"text", 'permanent_failed'::"text", 'sent'::"text", 'skipped'::"text"]))),
    CONSTRAINT "support_transcripts_event_id_check" CHECK ((("char_length"("tawk_event_id") >= 1) AND ("char_length"("tawk_event_id") <= 200))),
    CONSTRAINT "support_transcripts_identity_consistency_check" CHECK (((("identity_status" = 'resolved'::"text") AND ("user_id" IS NOT NULL)) OR (("identity_status" <> 'resolved'::"text") AND ("user_id" IS NULL)))),
    CONSTRAINT "support_transcripts_identity_error_check" CHECK ((("identity_error" IS NULL) OR ("char_length"("identity_error") <= 1000))),
    CONSTRAINT "support_transcripts_identity_status_check" CHECK (("identity_status" = ANY (ARRAY['resolved'::"text", 'missing_email'::"text", 'not_found'::"text", 'ambiguous'::"text"]))),
    CONSTRAINT "support_transcripts_notification_email_check" CHECK ((("notification_email" IS NULL) OR (("notification_email" = "lower"("btrim"("notification_email"))) AND (("char_length"("notification_email") >= 3) AND ("char_length"("notification_email") <= 254)) AND ("notification_email" ~ '^[^[:space:]@]+@[^[:space:]@]+$'::"text")))),
    CONSTRAINT "support_transcripts_notification_language_check" CHECK ((("notification_language" IS NULL) OR (("notification_language" = "lower"("btrim"("notification_language"))) AND (("char_length"("notification_language") >= 2) AND ("char_length"("notification_language") <= 35))))),
    CONSTRAINT "support_transcripts_notification_name_check" CHECK ((("notification_display_name" IS NULL) OR ("char_length"("notification_display_name") <= 200))),
    CONSTRAINT "support_transcripts_notification_snapshot_check" CHECK (((("notification_email" IS NULL) = ("notification_language" IS NULL)) AND (("notification_email" IS NOT NULL) OR ("notification_display_name" IS NULL)) AND (("identity_status" = 'resolved'::"text") OR ("notification_email" IS NULL)))),
    CONSTRAINT "support_transcripts_payload_check" CHECK (("jsonb_typeof"("payload") = 'object'::"text")),
    CONSTRAINT "support_transcripts_processing_check" CHECK (((("processing_token" IS NULL) = ("processing_started_at" IS NULL)) AND (("identity_status" = 'resolved'::"text") OR ("processing_token" IS NULL)))),
    CONSTRAINT "support_transcripts_property_id_check" CHECK ((("char_length"("tawk_property_id") >= 1) AND ("char_length"("tawk_property_id") <= 200))),
    CONSTRAINT "support_transcripts_raw_body_check" CHECK ((("octet_length"("raw_body") >= 2) AND ("octet_length"("raw_body") <= 5242880))),
    CONSTRAINT "support_transcripts_raw_hash_check" CHECK (("raw_body_sha256" ~ '^[0-9a-f]{64}$'::"text")),
    CONSTRAINT "support_transcripts_visitor_email_check" CHECK ((("visitor_email_normalized" IS NULL) OR (("visitor_email_normalized" = "lower"("btrim"("visitor_email_normalized"))) AND (("char_length"("visitor_email_normalized") >= 3) AND ("char_length"("visitor_email_normalized") <= 254)))))
);


ALTER TABLE "public"."support_transcripts" OWNER TO "postgres";


COMMENT ON TABLE "public"."support_transcripts" IS 'Signed and idempotent tawk.to chat transcript archive.';



CREATE TABLE IF NOT EXISTS "public"."support_user_identities" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "normalized_email" "text" NOT NULL,
    "valid_from" timestamp with time zone DEFAULT "now"() NOT NULL,
    "valid_to" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "support_user_identities_email_check" CHECK ((("normalized_email" = "lower"("btrim"("normalized_email"))) AND (("char_length"("normalized_email") >= 3) AND ("char_length"("normalized_email") <= 254)) AND ("normalized_email" ~ '^[^[:space:]@]+@[^[:space:]@]+$'::"text"))),
    CONSTRAINT "support_user_identities_validity_check" CHECK ((("valid_to" IS NULL) OR ("valid_to" >= "valid_from")))
);


ALTER TABLE "public"."support_user_identities" OWNER TO "postgres";


COMMENT ON TABLE "public"."support_user_identities" IS 'Server-only, versioned auth e-mail mapping for fail-closed tawk.to transcript correlation.';



CREATE TABLE IF NOT EXISTS "public"."transfer_events" (
    "id" bigint NOT NULL,
    "transfer_id" "uuid" NOT NULL,
    "actor_id" "uuid" NOT NULL,
    "event_type" "text" NOT NULL,
    "from_status" "text",
    "to_status" "text",
    "reason" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "transfer_events_metadata_check" CHECK (("jsonb_typeof"("metadata") = 'object'::"text")),
    CONSTRAINT "transfer_events_reason_check" CHECK ((("reason" IS NULL) OR ("char_length"("reason") <= 1000)))
);


ALTER TABLE "public"."transfer_events" OWNER TO "postgres";


ALTER TABLE "public"."transfer_events" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."transfer_events_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."transfer_review_checks" (
    "id" bigint NOT NULL,
    "transfer_id" "uuid" NOT NULL,
    "check_kind" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "reviewer_id" "uuid",
    "note" "text",
    "reviewed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "transfer_review_checks_check_kind_check" CHECK (("check_kind" = ANY (ARRAY['dual_review'::"text", 'escalation'::"text", 'compliance'::"text", 'final_authorization'::"text"]))),
    CONSTRAINT "transfer_review_checks_note_check" CHECK ((("note" IS NULL) OR ("char_length"("note") <= 1000))),
    CONSTRAINT "transfer_review_checks_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'in_progress'::"text", 'completed'::"text", 'failed'::"text"])))
);


ALTER TABLE "public"."transfer_review_checks" OWNER TO "postgres";


ALTER TABLE "public"."transfer_review_checks" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."transfer_review_checks_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE ONLY "private"."account_number_configuration"
    ADD CONSTRAINT "account_number_configuration_pkey" PRIMARY KEY ("singleton");



ALTER TABLE ONLY "private"."client_purge_entity_manifest"
    ADD CONSTRAINT "client_purge_entity_manifest_pkey" PRIMARY KEY ("challenge_id", "entity_type", "entity_id");



ALTER TABLE ONLY "private"."client_purge_operations"
    ADD CONSTRAINT "client_purge_operations_idempotency_key_key" UNIQUE ("idempotency_key");



ALTER TABLE ONLY "private"."client_purge_operations"
    ADD CONSTRAINT "client_purge_operations_pkey" PRIMARY KEY ("challenge_id");



ALTER TABLE ONLY "private"."client_purge_storage_manifest"
    ADD CONSTRAINT "client_purge_storage_manifest_pkey" PRIMARY KEY ("challenge_id", "bucket", "object_path");



ALTER TABLE ONLY "private"."client_purge_storage_scan_queue"
    ADD CONSTRAINT "client_purge_storage_scan_que_challenge_id_cycle_stage_buck_key" UNIQUE ("challenge_id", "cycle_stage", "bucket", "prefix");



ALTER TABLE ONLY "private"."client_purge_storage_scan_queue"
    ADD CONSTRAINT "client_purge_storage_scan_queue_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."audit_events"
    ADD CONSTRAINT "audit_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."brand_settings"
    ADD CONSTRAINT "brand_settings_pkey" PRIMARY KEY ("singleton");



ALTER TABLE ONLY "public"."external_loan_fundings"
    ADD CONSTRAINT "external_loan_fundings_pkey" PRIMARY KEY ("loan_id");



ALTER TABLE ONLY "public"."external_transfer_executions"
    ADD CONSTRAINT "external_transfer_executions_pkey" PRIMARY KEY ("transfer_id");



ALTER TABLE ONLY "public"."financial_ledger_entries"
    ADD CONSTRAINT "financial_ledger_entries_account_id_sequence_no_key" UNIQUE ("account_id", "sequence_no");



ALTER TABLE ONLY "public"."financial_ledger_entries"
    ADD CONSTRAINT "financial_ledger_entries_entry_key_key" UNIQUE ("entry_key");



ALTER TABLE ONLY "public"."financial_ledger_entries"
    ADD CONSTRAINT "financial_ledger_entries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."financial_positions"
    ADD CONSTRAINT "financial_positions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."kyc_applications"
    ADD CONSTRAINT "kyc_applications_owner_id_idempotency_key_key" UNIQUE ("owner_id", "idempotency_key");



ALTER TABLE ONLY "public"."kyc_applications"
    ADD CONSTRAINT "kyc_applications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."kyc_drafts"
    ADD CONSTRAINT "kyc_drafts_pkey" PRIMARY KEY ("owner_id");



ALTER TABLE ONLY "public"."kyc_events"
    ADD CONSTRAINT "kyc_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."kyc_review_checklists"
    ADD CONSTRAINT "kyc_review_checklists_pkey" PRIMARY KEY ("kyc_id");



ALTER TABLE "public"."loan_applications"
    ADD CONSTRAINT "loan_applications_internal_disbursement_metadata_check" CHECK (((("status" = 'external_settlement_confirmed'::"text") AND ("internal_disbursement_reference" IS NOT NULL)) OR ("status" <> 'external_settlement_confirmed'::"text"))) NOT VALID;



ALTER TABLE ONLY "public"."loan_applications"
    ADD CONSTRAINT "loan_applications_owner_id_idempotency_key_key" UNIQUE ("owner_id", "idempotency_key");



ALTER TABLE ONLY "public"."loan_applications"
    ADD CONSTRAINT "loan_applications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."loan_applications"
    ADD CONSTRAINT "loan_applications_reference_key" UNIQUE ("reference");



ALTER TABLE ONLY "public"."loan_events"
    ADD CONSTRAINT "loan_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."loan_product_settings"
    ADD CONSTRAINT "loan_product_settings_pkey" PRIMARY KEY ("currency");



ALTER TABLE ONLY "public"."loan_review_checks"
    ADD CONSTRAINT "loan_review_checks_loan_id_check_kind_key" UNIQUE ("loan_id", "check_kind");



ALTER TABLE ONLY "public"."loan_review_checks"
    ADD CONSTRAINT "loan_review_checks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."official_documents"
    ADD CONSTRAINT "official_documents_document_number_key" UNIQUE ("document_number");



ALTER TABLE ONLY "public"."official_documents"
    ADD CONSTRAINT "official_documents_owner_id_idempotency_key_key" UNIQUE ("owner_id", "idempotency_key");



ALTER TABLE ONLY "public"."official_documents"
    ADD CONSTRAINT "official_documents_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."official_documents"
    ADD CONSTRAINT "official_documents_supersedes_document_id_key" UNIQUE ("supersedes_document_id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."push_subscriptions"
    ADD CONSTRAINT "push_subscriptions_endpoint_hash_key" UNIQUE ("endpoint_hash");



ALTER TABLE ONLY "public"."push_subscriptions"
    ADD CONSTRAINT "push_subscriptions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."staff_members"
    ADD CONSTRAINT "staff_members_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."support_push_deliveries"
    ADD CONSTRAINT "support_push_deliveries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."support_push_deliveries"
    ADD CONSTRAINT "support_push_deliveries_transcript_endpoint_key" UNIQUE ("transcript_id", "endpoint_hash_snapshot");



ALTER TABLE ONLY "public"."support_transcripts"
    ADD CONSTRAINT "support_transcripts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."support_transcripts"
    ADD CONSTRAINT "support_transcripts_raw_hash_key" UNIQUE ("raw_body_sha256");



ALTER TABLE ONLY "public"."support_transcripts"
    ADD CONSTRAINT "support_transcripts_tawk_event_id_key" UNIQUE ("tawk_event_id");



ALTER TABLE ONLY "public"."support_user_identities"
    ADD CONSTRAINT "support_user_identities_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."transactional_email_outbox"
    ADD CONSTRAINT "transactional_email_outbox_event_key_key" UNIQUE ("event_key");



ALTER TABLE ONLY "public"."transactional_email_outbox"
    ADD CONSTRAINT "transactional_email_outbox_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."transfer_events"
    ADD CONSTRAINT "transfer_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."transfer_intents"
    ADD CONSTRAINT "transfer_intents_owner_id_idempotency_key_key" UNIQUE ("owner_id", "idempotency_key");



ALTER TABLE ONLY "public"."transfer_intents"
    ADD CONSTRAINT "transfer_intents_pkey" PRIMARY KEY ("id");



ALTER TABLE "public"."transfer_intents"
    ADD CONSTRAINT "transfer_intents_settlement_metadata_check" CHECK (((("status" = 'external_settlement_confirmed'::"text") AND ("internal_execution_reference" IS NOT NULL) AND ("settled_by" IS NOT NULL) AND ("settled_at" IS NOT NULL)) OR ("status" <> 'external_settlement_confirmed'::"text"))) NOT VALID;



ALTER TABLE ONLY "public"."transfer_review_checks"
    ADD CONSTRAINT "transfer_review_checks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."transfer_review_checks"
    ADD CONSTRAINT "transfer_review_checks_transfer_id_check_kind_key" UNIQUE ("transfer_id", "check_kind");



CREATE INDEX "client_purge_operations_retry_idx" ON "private"."client_purge_operations" USING "btree" ("retry_after", "updated_at") WHERE ("status" = ANY (ARRAY['running'::"text", 'failed'::"text", 'waiting_sweep'::"text"]));



CREATE UNIQUE INDEX "client_purge_operations_target_uidx" ON "private"."client_purge_operations" USING "btree" ("target_user_id");



CREATE INDEX "client_purge_storage_manifest_expired_claim_idx" ON "private"."client_purge_storage_manifest" USING "btree" ("challenge_id", "processing_status", "claimed_at") WHERE ("processing_status" = ANY (ARRAY['delete_claimed'::"text", 'verify_claimed'::"text"]));



CREATE INDEX "client_purge_storage_manifest_relational_path_idx" ON "private"."client_purge_storage_manifest" USING "btree" ("bucket", "object_path", "challenge_id") WHERE ("ownership_scope" = 'relational'::"text");



CREATE INDEX "client_purge_storage_manifest_work_idx" ON "private"."client_purge_storage_manifest" USING "btree" ("challenge_id", "processing_status", "bucket", "object_path");



CREATE INDEX "client_purge_storage_scan_queue_claim_idx" ON "private"."client_purge_storage_scan_queue" USING "btree" ("challenge_id", "cycle_stage", "status", "id");



CREATE INDEX "audit_events_actor_id_idx" ON "public"."audit_events" USING "btree" ("actor_id");



CREATE INDEX "audit_events_entity_created_idx" ON "public"."audit_events" USING "btree" ("entity_type", "entity_id", "created_at" DESC);



CREATE INDEX "external_loan_funding_evidence_path_idx" ON "public"."external_loan_fundings" USING "btree" ("evidence_object_path");



CREATE UNIQUE INDEX "external_loan_funding_reference_idx" ON "public"."external_loan_fundings" USING "btree" ("external_reference");



CREATE INDEX "external_loan_fundings_confirmed_by_idx" ON "public"."external_loan_fundings" USING "btree" ("confirmed_by");



CREATE INDEX "external_loan_fundings_executed_by_idx" ON "public"."external_loan_fundings" USING "btree" ("executed_by");



CREATE INDEX "external_transfer_execution_evidence_path_idx" ON "public"."external_transfer_executions" USING "btree" ("evidence_object_path");



CREATE INDEX "external_transfer_executions_confirmed_by_idx" ON "public"."external_transfer_executions" USING "btree" ("confirmed_by");



CREATE INDEX "external_transfer_executions_executed_by_idx" ON "public"."external_transfer_executions" USING "btree" ("executed_by");



CREATE UNIQUE INDEX "external_transfer_reference_idx" ON "public"."external_transfer_executions" USING "btree" ("external_reference");



CREATE INDEX "financial_ledger_entries_booked_by_idx" ON "public"."financial_ledger_entries" USING "btree" ("booked_by") WHERE ("booked_by" IS NOT NULL);



CREATE UNIQUE INDEX "financial_ledger_entries_loan_uidx" ON "public"."financial_ledger_entries" USING "btree" ("source_loan_id") WHERE (("source_loan_id" IS NOT NULL) AND ("entry_kind" = 'loan_credit'::"text"));



CREATE INDEX "financial_ledger_entries_owner_booked_idx" ON "public"."financial_ledger_entries" USING "btree" ("owner_id", "booked_at" DESC);



CREATE INDEX "financial_ledger_entries_position_booked_idx" ON "public"."financial_ledger_entries" USING "btree" ("account_id", "booked_at" DESC);



CREATE UNIQUE INDEX "financial_ledger_entries_position_reference_uidx" ON "public"."financial_ledger_entries" USING "btree" ("account_id", "internal_reference") WHERE ("internal_reference" IS NOT NULL);



CREATE UNIQUE INDEX "financial_ledger_entries_transfer_uidx" ON "public"."financial_ledger_entries" USING "btree" ("source_transfer_id") WHERE (("source_transfer_id" IS NOT NULL) AND ("entry_kind" = 'transfer_debit'::"text"));



CREATE UNIQUE INDEX "financial_positions_account_number_uidx" ON "public"."financial_positions" USING "btree" ("account_number") WHERE ("account_number" IS NOT NULL);



CREATE UNIQUE INDEX "financial_positions_declaration_idempotency_uidx" ON "public"."financial_positions" USING "btree" ("declaration_idempotency_key") WHERE ("declaration_idempotency_key" IS NOT NULL);



CREATE INDEX "financial_positions_declared_by_idx" ON "public"."financial_positions" USING "btree" ("declared_by") WHERE ("declared_by" IS NOT NULL);



CREATE UNIQUE INDEX "financial_positions_iban_uidx" ON "public"."financial_positions" USING "btree" ("iban") WHERE ("iban" IS NOT NULL);



CREATE INDEX "financial_positions_owner_idx" ON "public"."financial_positions" USING "btree" ("owner_id");



CREATE INDEX "financial_positions_owner_status_idx" ON "public"."financial_positions" USING "btree" ("owner_id", "account_status");



CREATE UNIQUE INDEX "financial_positions_source_kyc_uidx" ON "public"."financial_positions" USING "btree" ("source_kyc_id") WHERE ("source_kyc_id" IS NOT NULL);



CREATE INDEX "kyc_applications_owner_created_idx" ON "public"."kyc_applications" USING "btree" ("owner_id", "submitted_at" DESC);



CREATE INDEX "kyc_applications_review_queue_idx" ON "public"."kyc_applications" USING "btree" ("submitted_at") WHERE ("status" = ANY (ARRAY['submitted'::"text", 'under_review'::"text", 'needs_information'::"text"]));



CREATE INDEX "kyc_applications_reviewed_by_idx" ON "public"."kyc_applications" USING "btree" ("reviewed_by");



CREATE INDEX "kyc_events_actor_id_idx" ON "public"."kyc_events" USING "btree" ("actor_id");



CREATE INDEX "kyc_events_kyc_created_idx" ON "public"."kyc_events" USING "btree" ("kyc_id", "created_at");



CREATE INDEX "loan_applications_active_review_idx" ON "public"."loan_applications" USING "btree" ("submitted_at") WHERE ("status" = ANY (ARRAY['submitted'::"text", 'under_review'::"text", 'approved_for_external_funding'::"text", 'external_funding_recorded'::"text"]));



CREATE INDEX "loan_applications_credited_position_idx" ON "public"."loan_applications" USING "btree" ("credited_position_id") WHERE ("credited_position_id" IS NOT NULL);



CREATE INDEX "loan_applications_disbursed_by_idx" ON "public"."loan_applications" USING "btree" ("disbursed_by") WHERE ("disbursed_by" IS NOT NULL);



CREATE UNIQUE INDEX "loan_applications_internal_disbursement_reference_uidx" ON "public"."loan_applications" USING "btree" ("internal_disbursement_reference") WHERE ("internal_disbursement_reference" IS NOT NULL);



CREATE INDEX "loan_applications_owner_created_idx" ON "public"."loan_applications" USING "btree" ("owner_id", "submitted_at" DESC);



CREATE INDEX "loan_events_actor_id_idx" ON "public"."loan_events" USING "btree" ("actor_id");



CREATE INDEX "loan_events_loan_created_idx" ON "public"."loan_events" USING "btree" ("loan_id", "created_at");



CREATE INDEX "loan_review_checks_loan_idx" ON "public"."loan_review_checks" USING "btree" ("loan_id");



CREATE INDEX "loan_review_checks_reviewer_id_idx" ON "public"."loan_review_checks" USING "btree" ("reviewer_id");



CREATE INDEX "notifications_recipient_unread_idx" ON "public"."notifications" USING "btree" ("recipient_id", "created_at" DESC) WHERE ("read_at" IS NULL);



CREATE INDEX "official_documents_account_created_idx" ON "public"."official_documents" USING "btree" ("account_id", "created_at" DESC) WHERE ("account_id" IS NOT NULL);



CREATE INDEX "official_documents_issued_by_idx" ON "public"."official_documents" USING "btree" ("issued_by");



CREATE INDEX "official_documents_loan_idx" ON "public"."official_documents" USING "btree" ("loan_id") WHERE ("loan_id" IS NOT NULL);



CREATE INDEX "official_documents_owner_created_idx" ON "public"."official_documents" USING "btree" ("owner_id", "created_at" DESC);



CREATE INDEX "official_documents_pending_idx" ON "public"."official_documents" USING "btree" ("requested_at") WHERE ("status" = 'pending'::"text");



CREATE INDEX "official_documents_transfer_idx" ON "public"."official_documents" USING "btree" ("transfer_id") WHERE ("transfer_id" IS NOT NULL);



CREATE UNIQUE INDEX "profiles_email_lower_idx" ON "public"."profiles" USING "btree" ("lower"("email"));



CREATE INDEX "push_subscriptions_user_updated_idx" ON "public"."push_subscriptions" USING "btree" ("user_id", "updated_at" DESC);



CREATE INDEX "support_push_deliveries_subscription_idx" ON "public"."support_push_deliveries" USING "btree" ("subscription_id") WHERE ("subscription_id" IS NOT NULL);



CREATE INDEX "support_push_deliveries_transcript_status_idx" ON "public"."support_push_deliveries" USING "btree" ("transcript_id", "status");



CREATE INDEX "support_transcripts_chat_idx" ON "public"."support_transcripts" USING "btree" ("tawk_property_id", "tawk_chat_id");



CREATE INDEX "support_transcripts_incomplete_idx" ON "public"."support_transcripts" USING "btree" ("updated_at") WHERE ("completed_at" IS NULL);



CREATE INDEX "support_transcripts_user_created_idx" ON "public"."support_transcripts" USING "btree" ("user_id", "created_at" DESC);



CREATE UNIQUE INDEX "support_user_identities_active_email_uidx" ON "public"."support_user_identities" USING "btree" ("normalized_email") WHERE ("valid_to" IS NULL);



CREATE UNIQUE INDEX "support_user_identities_active_user_uidx" ON "public"."support_user_identities" USING "btree" ("user_id") WHERE ("valid_to" IS NULL);



CREATE INDEX "support_user_identities_email_history_idx" ON "public"."support_user_identities" USING "btree" ("normalized_email", "valid_from" DESC);



CREATE INDEX "transactional_email_outbox_claimed_by_idx" ON "public"."transactional_email_outbox" USING "btree" ("claimed_by") WHERE ("claimed_by" IS NOT NULL);



CREATE INDEX "transactional_email_outbox_pending_idx" ON "public"."transactional_email_outbox" USING "btree" ("created_at") WHERE (("status" = ANY (ARRAY['pending'::"text", 'sending'::"text"])) AND ("attempts" < 5));



CREATE INDEX "transactional_email_outbox_recipient_idx" ON "public"."transactional_email_outbox" USING "btree" ("recipient_id", "created_at" DESC);



CREATE INDEX "transactional_email_outbox_retry_idx" ON "public"."transactional_email_outbox" USING "btree" ("status", "claimed_at", "created_at") WHERE (("status" = ANY (ARRAY['pending'::"text", 'sending'::"text"])) AND ("attempts" < 5));



CREATE INDEX "transfer_events_actor_id_idx" ON "public"."transfer_events" USING "btree" ("actor_id");



CREATE INDEX "transfer_events_transfer_created_idx" ON "public"."transfer_events" USING "btree" ("transfer_id", "created_at");



CREATE INDEX "transfer_intents_active_review_idx" ON "public"."transfer_intents" USING "btree" ("submitted_at") WHERE ("status" = ANY (ARRAY['submitted'::"text", 'under_review'::"text", 'approved_for_external_execution'::"text", 'external_execution_recorded'::"text"]));



CREATE UNIQUE INDEX "transfer_intents_internal_execution_reference_uidx" ON "public"."transfer_intents" USING "btree" ("internal_execution_reference") WHERE ("internal_execution_reference" IS NOT NULL);



CREATE INDEX "transfer_intents_owner_created_idx" ON "public"."transfer_intents" USING "btree" ("owner_id", "submitted_at" DESC);



CREATE INDEX "transfer_intents_settled_by_idx" ON "public"."transfer_intents" USING "btree" ("settled_by") WHERE ("settled_by" IS NOT NULL);



CREATE INDEX "transfer_intents_source_position_id_idx" ON "public"."transfer_intents" USING "btree" ("source_position_id");



CREATE INDEX "transfer_review_checks_reviewer_id_idx" ON "public"."transfer_review_checks" USING "btree" ("reviewer_id");



CREATE INDEX "transfer_review_checks_transfer_idx" ON "public"."transfer_review_checks" USING "btree" ("transfer_id");



CREATE OR REPLACE TRIGGER "audit_events_guard_client_purge_mutation" BEFORE INSERT OR DELETE OR UPDATE ON "public"."audit_events" FOR EACH ROW EXECUTE FUNCTION "private"."guard_client_audit_mutation"();



CREATE OR REPLACE TRIGGER "brand_settings_set_updated_at" BEFORE UPDATE ON "public"."brand_settings" FOR EACH ROW EXECUTE FUNCTION "private"."set_updated_at"();



CREATE OR REPLACE TRIGGER "email_outbox_claim_guard_client_purge_mutation" BEFORE INSERT OR DELETE OR UPDATE ON "public"."transactional_email_outbox" FOR EACH ROW EXECUTE FUNCTION "private"."guard_direct_client_mutation"('claimed_by');



CREATE OR REPLACE TRIGGER "email_outbox_guard_client_purge_mutation" BEFORE INSERT OR DELETE OR UPDATE ON "public"."transactional_email_outbox" FOR EACH ROW EXECUTE FUNCTION "private"."guard_direct_client_mutation"('recipient_id');



CREATE OR REPLACE TRIGGER "external_loan_evidence_enforce_path_owner" BEFORE INSERT OR UPDATE OF "executed_by", "evidence_object_path" ON "public"."external_loan_fundings" FOR EACH ROW EXECUTE FUNCTION "private"."enforce_external_evidence_path_ownership"();



CREATE OR REPLACE TRIGGER "external_loan_guard_client_purge_mutation" BEFORE INSERT OR DELETE OR UPDATE ON "public"."external_loan_fundings" FOR EACH ROW EXECUTE FUNCTION "private"."guard_indirect_client_mutation"('loan', 'loan_id');



CREATE OR REPLACE TRIGGER "external_transfer_evidence_enforce_path_owner" BEFORE INSERT OR UPDATE OF "executed_by", "evidence_object_path" ON "public"."external_transfer_executions" FOR EACH ROW EXECUTE FUNCTION "private"."enforce_external_evidence_path_ownership"();



CREATE OR REPLACE TRIGGER "external_transfer_guard_client_purge_mutation" BEFORE INSERT OR DELETE OR UPDATE ON "public"."external_transfer_executions" FOR EACH ROW EXECUTE FUNCTION "private"."guard_indirect_client_mutation"('transfer', 'transfer_id');



CREATE OR REPLACE TRIGGER "financial_ledger_entries_prevent_delete" BEFORE DELETE ON "public"."financial_ledger_entries" FOR EACH ROW EXECUTE FUNCTION "private"."prevent_financial_ledger_mutation"();



CREATE OR REPLACE TRIGGER "financial_ledger_entries_prevent_update" BEFORE UPDATE ON "public"."financial_ledger_entries" FOR EACH ROW EXECUTE FUNCTION "private"."prevent_financial_ledger_mutation"();



CREATE OR REPLACE TRIGGER "financial_ledger_entries_validate" BEFORE INSERT ON "public"."financial_ledger_entries" FOR EACH ROW EXECUTE FUNCTION "private"."validate_financial_ledger_entry"();



CREATE OR REPLACE TRIGGER "financial_ledger_guard_client_purge_mutation" BEFORE INSERT OR DELETE OR UPDATE ON "public"."financial_ledger_entries" FOR EACH ROW EXECUTE FUNCTION "private"."guard_direct_client_mutation"('owner_id');



CREATE OR REPLACE TRIGGER "financial_positions_ensure_demo_banking_artifacts" AFTER INSERT OR UPDATE ON "public"."financial_positions" FOR EACH ROW EXECUTE FUNCTION "private"."ensure_demo_banking_artifacts"();



CREATE OR REPLACE TRIGGER "financial_positions_guard_client_purge_mutation" BEFORE INSERT OR DELETE OR UPDATE ON "public"."financial_positions" FOR EACH ROW EXECUTE FUNCTION "private"."guard_direct_client_mutation"('owner_id');



CREATE OR REPLACE TRIGGER "financial_positions_prepare_demo_account" BEFORE INSERT OR UPDATE ON "public"."financial_positions" FOR EACH ROW EXECUTE FUNCTION "private"."prepare_demo_financial_position"();



CREATE OR REPLACE TRIGGER "financial_positions_set_updated_at" BEFORE UPDATE ON "public"."financial_positions" FOR EACH ROW EXECUTE FUNCTION "private"."set_updated_at"();



CREATE OR REPLACE TRIGGER "kyc_applications_enforce_document_path_owner" BEFORE INSERT OR UPDATE OF "owner_id", "document_object_paths" ON "public"."kyc_applications" FOR EACH ROW EXECUTE FUNCTION "private"."enforce_client_document_path_ownership"();



CREATE OR REPLACE TRIGGER "kyc_applications_guard_client_purge_mutation" BEFORE INSERT OR DELETE OR UPDATE ON "public"."kyc_applications" FOR EACH ROW EXECUTE FUNCTION "private"."guard_direct_client_mutation"('owner_id');



CREATE OR REPLACE TRIGGER "kyc_applications_set_updated_at" BEFORE UPDATE ON "public"."kyc_applications" FOR EACH ROW EXECUTE FUNCTION "private"."set_updated_at"();



CREATE OR REPLACE TRIGGER "kyc_checklists_guard_client_purge_mutation" BEFORE INSERT OR DELETE OR UPDATE ON "public"."kyc_review_checklists" FOR EACH ROW EXECUTE FUNCTION "private"."guard_indirect_client_mutation"('kyc', 'kyc_id');



CREATE OR REPLACE TRIGGER "kyc_drafts_enforce_document_path_owner" BEFORE INSERT OR UPDATE OF "owner_id", "document_object_paths" ON "public"."kyc_drafts" FOR EACH ROW EXECUTE FUNCTION "private"."enforce_client_document_path_ownership"();



CREATE OR REPLACE TRIGGER "kyc_drafts_guard_client_purge_mutation" BEFORE INSERT OR DELETE OR UPDATE ON "public"."kyc_drafts" FOR EACH ROW EXECUTE FUNCTION "private"."guard_direct_client_mutation"('owner_id');



CREATE OR REPLACE TRIGGER "kyc_drafts_set_updated_at" BEFORE UPDATE ON "public"."kyc_drafts" FOR EACH ROW EXECUTE FUNCTION "private"."set_updated_at"();



CREATE OR REPLACE TRIGGER "kyc_enqueue_message" AFTER INSERT OR UPDATE OF "status" ON "public"."kyc_applications" FOR EACH ROW EXECUTE FUNCTION "private"."enqueue_kyc_message"();



CREATE OR REPLACE TRIGGER "kyc_events_guard_client_purge_mutation" BEFORE INSERT OR DELETE OR UPDATE ON "public"."kyc_events" FOR EACH ROW EXECUTE FUNCTION "private"."guard_indirect_client_mutation"('kyc', 'kyc_id');



CREATE OR REPLACE TRIGGER "kyc_review_checklists_set_updated_at" BEFORE UPDATE ON "public"."kyc_review_checklists" FOR EACH ROW EXECUTE FUNCTION "private"."set_updated_at"();



CREATE OR REPLACE TRIGGER "loan_applications_enforce_document_path_owner" BEFORE INSERT OR UPDATE OF "owner_id", "document_object_paths" ON "public"."loan_applications" FOR EACH ROW EXECUTE FUNCTION "private"."enforce_client_document_path_ownership"();



CREATE OR REPLACE TRIGGER "loan_applications_guard_client_purge_mutation" BEFORE INSERT OR DELETE OR UPDATE ON "public"."loan_applications" FOR EACH ROW EXECUTE FUNCTION "private"."guard_direct_client_mutation"('owner_id');



CREATE OR REPLACE TRIGGER "loan_applications_set_updated_at" BEFORE UPDATE ON "public"."loan_applications" FOR EACH ROW EXECUTE FUNCTION "private"."set_updated_at"();



CREATE OR REPLACE TRIGGER "loan_checks_guard_client_purge_mutation" BEFORE INSERT OR DELETE OR UPDATE ON "public"."loan_review_checks" FOR EACH ROW EXECUTE FUNCTION "private"."guard_indirect_client_mutation"('loan', 'loan_id');



CREATE OR REPLACE TRIGGER "loan_enqueue_transactional_email" AFTER INSERT OR UPDATE OF "status" ON "public"."loan_applications" FOR EACH ROW EXECUTE FUNCTION "private"."enqueue_financial_workflow_email"();



CREATE OR REPLACE TRIGGER "loan_events_guard_client_purge_mutation" BEFORE INSERT OR DELETE OR UPDATE ON "public"."loan_events" FOR EACH ROW EXECUTE FUNCTION "private"."guard_indirect_client_mutation"('loan', 'loan_id');



CREATE OR REPLACE TRIGGER "loan_product_settings_set_updated_at" BEFORE UPDATE ON "public"."loan_product_settings" FOR EACH ROW EXECUTE FUNCTION "private"."set_updated_at"();



CREATE OR REPLACE TRIGGER "loan_review_checks_set_updated_at" BEFORE UPDATE ON "public"."loan_review_checks" FOR EACH ROW EXECUTE FUNCTION "private"."set_updated_at"();



CREATE OR REPLACE TRIGGER "loan_validate_disbursement_target" BEFORE INSERT OR UPDATE OF "status", "credited_position_id", "disbursed_by", "disbursed_at" ON "public"."loan_applications" FOR EACH ROW EXECUTE FUNCTION "private"."validate_loan_disbursement_target"();



CREATE OR REPLACE TRIGGER "notifications_guard_client_purge_mutation" BEFORE INSERT OR DELETE OR UPDATE ON "public"."notifications" FOR EACH ROW EXECUTE FUNCTION "private"."guard_direct_client_mutation"('recipient_id');



CREATE OR REPLACE TRIGGER "notifications_normalize_localization" BEFORE INSERT OR UPDATE OF "title", "message", "notification_type", "message_key", "message_params" ON "public"."notifications" FOR EACH ROW EXECUTE FUNCTION "private"."normalize_notification_localization"();



CREATE OR REPLACE TRIGGER "official_documents_brand_snapshot" BEFORE INSERT ON "public"."official_documents" FOR EACH ROW EXECUTE FUNCTION "private"."snapshot_official_document_brand"();



CREATE OR REPLACE TRIGGER "official_documents_enforce_storage_path_owner" BEFORE INSERT OR UPDATE OF "owner_id", "storage_path" ON "public"."official_documents" FOR EACH ROW EXECUTE FUNCTION "private"."enforce_official_document_path_ownership"();



CREATE OR REPLACE TRIGGER "official_documents_guard_client_purge_mutation" BEFORE INSERT OR DELETE OR UPDATE ON "public"."official_documents" FOR EACH ROW EXECUTE FUNCTION "private"."guard_direct_client_mutation"('owner_id');



CREATE OR REPLACE TRIGGER "official_documents_protect_delete" BEFORE DELETE ON "public"."official_documents" FOR EACH ROW EXECUTE FUNCTION "private"."protect_official_document"();



CREATE OR REPLACE TRIGGER "official_documents_protect_update" BEFORE UPDATE ON "public"."official_documents" FOR EACH ROW EXECUTE FUNCTION "private"."protect_official_document"();



CREATE OR REPLACE TRIGGER "official_documents_remove_iban_before_insert" BEFORE INSERT ON "public"."official_documents" FOR EACH ROW EXECUTE FUNCTION "private"."remove_iban_from_new_official_document"();



CREATE OR REPLACE TRIGGER "official_documents_set_updated_at" BEFORE UPDATE ON "public"."official_documents" FOR EACH ROW EXECUTE FUNCTION "private"."set_updated_at"();



CREATE OR REPLACE TRIGGER "profiles_enforce_base_currency_immutability" BEFORE UPDATE OF "base_currency" ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "private"."enforce_profile_base_currency_immutability"();



CREATE OR REPLACE TRIGGER "profiles_freeze_during_client_purge" BEFORE INSERT OR UPDATE OF "access_status" ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "private"."freeze_profile_during_client_purge"();



CREATE OR REPLACE TRIGGER "profiles_guard_client_purge_mutation" BEFORE INSERT OR DELETE OR UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "private"."guard_direct_client_mutation"('user_id');



CREATE OR REPLACE TRIGGER "profiles_set_updated_at" BEFORE UPDATE ON "public"."profiles" FOR EACH ROW EXECUTE FUNCTION "private"."set_updated_at"();



CREATE OR REPLACE TRIGGER "push_subscriptions_guard_client_purge_mutation" BEFORE INSERT OR DELETE OR UPDATE ON "public"."push_subscriptions" FOR EACH ROW EXECUTE FUNCTION "private"."guard_direct_client_mutation"('user_id');



CREATE OR REPLACE TRIGGER "push_subscriptions_set_updated_at" BEFORE UPDATE ON "public"."push_subscriptions" FOR EACH ROW EXECUTE FUNCTION "private"."set_updated_at"();



CREATE OR REPLACE TRIGGER "staff_members_prevent_purge_target_promotion" BEFORE INSERT OR UPDATE OF "user_id", "role", "active" ON "public"."staff_members" FOR EACH ROW EXECUTE FUNCTION "private"."prevent_purge_target_promotion"();



CREATE OR REPLACE TRIGGER "staff_members_set_updated_at" BEFORE UPDATE ON "public"."staff_members" FOR EACH ROW EXECUTE FUNCTION "private"."set_updated_at"();



CREATE OR REPLACE TRIGGER "support_delivery_transcript_guard_client_purge_mutation" BEFORE INSERT OR DELETE OR UPDATE ON "public"."support_push_deliveries" FOR EACH ROW EXECUTE FUNCTION "private"."guard_indirect_client_mutation"('transcript', 'transcript_id');



CREATE OR REPLACE TRIGGER "support_identities_guard_client_purge_mutation" BEFORE INSERT OR DELETE OR UPDATE ON "public"."support_user_identities" FOR EACH ROW EXECUTE FUNCTION "private"."guard_direct_client_mutation"('user_id');



CREATE OR REPLACE TRIGGER "support_push_deliveries_set_updated_at" BEFORE UPDATE ON "public"."support_push_deliveries" FOR EACH ROW EXECUTE FUNCTION "private"."set_updated_at"();



CREATE OR REPLACE TRIGGER "support_transcripts_guard_client_purge_mutation" BEFORE INSERT OR DELETE OR UPDATE ON "public"."support_transcripts" FOR EACH ROW EXECUTE FUNCTION "private"."guard_support_transcript_mutation"();



CREATE OR REPLACE TRIGGER "support_transcripts_set_updated_at" BEFORE UPDATE ON "public"."support_transcripts" FOR EACH ROW EXECUTE FUNCTION "private"."set_updated_at"();



CREATE OR REPLACE TRIGGER "transactional_email_outbox_set_updated_at" BEFORE UPDATE ON "public"."transactional_email_outbox" FOR EACH ROW EXECUTE FUNCTION "private"."set_updated_at"();



CREATE OR REPLACE TRIGGER "transfer_check_enqueue_validation_email" AFTER UPDATE OF "status" ON "public"."transfer_review_checks" FOR EACH ROW WHEN ((("old"."status" IS DISTINCT FROM "new"."status") AND ("new"."status" = 'completed'::"text") AND ("new"."check_kind" <> 'final_authorization'::"text"))) EXECUTE FUNCTION "private"."enqueue_transfer_check_validation_email"();



CREATE OR REPLACE TRIGGER "transfer_checks_guard_client_purge_mutation" BEFORE INSERT OR DELETE OR UPDATE ON "public"."transfer_review_checks" FOR EACH ROW EXECUTE FUNCTION "private"."guard_indirect_client_mutation"('transfer', 'transfer_id');



CREATE OR REPLACE TRIGGER "transfer_enqueue_transactional_email" AFTER INSERT OR UPDATE OF "status" ON "public"."transfer_intents" FOR EACH ROW EXECUTE FUNCTION "private"."enqueue_financial_workflow_email"();



CREATE OR REPLACE TRIGGER "transfer_events_guard_client_purge_mutation" BEFORE INSERT OR DELETE OR UPDATE ON "public"."transfer_events" FOR EACH ROW EXECUTE FUNCTION "private"."guard_indirect_client_mutation"('transfer', 'transfer_id');



CREATE OR REPLACE TRIGGER "transfer_intents_guard_client_purge_mutation" BEFORE INSERT OR DELETE OR UPDATE ON "public"."transfer_intents" FOR EACH ROW EXECUTE FUNCTION "private"."guard_direct_client_mutation"('owner_id');



CREATE OR REPLACE TRIGGER "transfer_intents_set_updated_at" BEFORE UPDATE ON "public"."transfer_intents" FOR EACH ROW EXECUTE FUNCTION "private"."set_updated_at"();



CREATE OR REPLACE TRIGGER "transfer_review_checks_set_updated_at" BEFORE UPDATE ON "public"."transfer_review_checks" FOR EACH ROW EXECUTE FUNCTION "private"."set_updated_at"();



ALTER TABLE ONLY "private"."account_number_configuration"
    ADD CONSTRAINT "account_number_configuration_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "private"."account_number_configuration"
    ADD CONSTRAINT "account_number_configuration_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "private"."client_purge_entity_manifest"
    ADD CONSTRAINT "client_purge_entity_manifest_challenge_id_fkey" FOREIGN KEY ("challenge_id") REFERENCES "private"."client_purge_operations"("challenge_id") ON DELETE CASCADE;



ALTER TABLE ONLY "private"."client_purge_storage_manifest"
    ADD CONSTRAINT "client_purge_storage_manifest_challenge_id_fkey" FOREIGN KEY ("challenge_id") REFERENCES "private"."client_purge_operations"("challenge_id") ON DELETE CASCADE;



ALTER TABLE ONLY "private"."client_purge_storage_scan_queue"
    ADD CONSTRAINT "client_purge_storage_scan_queue_challenge_id_fkey" FOREIGN KEY ("challenge_id") REFERENCES "private"."client_purge_operations"("challenge_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."audit_events"
    ADD CONSTRAINT "audit_events_actor_id_fkey" FOREIGN KEY ("actor_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."brand_settings"
    ADD CONSTRAINT "brand_settings_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "public"."staff_members"("user_id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."external_loan_fundings"
    ADD CONSTRAINT "external_loan_fundings_confirmed_by_fkey" FOREIGN KEY ("confirmed_by") REFERENCES "public"."staff_members"("user_id");



ALTER TABLE ONLY "public"."external_loan_fundings"
    ADD CONSTRAINT "external_loan_fundings_executed_by_fkey" FOREIGN KEY ("executed_by") REFERENCES "public"."staff_members"("user_id");



ALTER TABLE ONLY "public"."external_loan_fundings"
    ADD CONSTRAINT "external_loan_fundings_loan_id_fkey" FOREIGN KEY ("loan_id") REFERENCES "public"."loan_applications"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."external_transfer_executions"
    ADD CONSTRAINT "external_transfer_executions_confirmed_by_fkey" FOREIGN KEY ("confirmed_by") REFERENCES "public"."staff_members"("user_id");



ALTER TABLE ONLY "public"."external_transfer_executions"
    ADD CONSTRAINT "external_transfer_executions_executed_by_fkey" FOREIGN KEY ("executed_by") REFERENCES "public"."staff_members"("user_id");



ALTER TABLE ONLY "public"."external_transfer_executions"
    ADD CONSTRAINT "external_transfer_executions_transfer_id_fkey" FOREIGN KEY ("transfer_id") REFERENCES "public"."transfer_intents"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."financial_ledger_entries"
    ADD CONSTRAINT "financial_ledger_entries_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."financial_positions"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."financial_ledger_entries"
    ADD CONSTRAINT "financial_ledger_entries_booked_by_fkey" FOREIGN KEY ("booked_by") REFERENCES "public"."staff_members"("user_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."financial_ledger_entries"
    ADD CONSTRAINT "financial_ledger_entries_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "public"."profiles"("user_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."financial_ledger_entries"
    ADD CONSTRAINT "financial_ledger_entries_source_loan_id_fkey" FOREIGN KEY ("source_loan_id") REFERENCES "public"."loan_applications"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."financial_ledger_entries"
    ADD CONSTRAINT "financial_ledger_entries_source_transfer_id_fkey" FOREIGN KEY ("source_transfer_id") REFERENCES "public"."transfer_intents"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."financial_positions"
    ADD CONSTRAINT "financial_positions_declared_by_fkey" FOREIGN KEY ("declared_by") REFERENCES "public"."staff_members"("user_id");



ALTER TABLE ONLY "public"."financial_positions"
    ADD CONSTRAINT "financial_positions_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "public"."profiles"("user_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."financial_positions"
    ADD CONSTRAINT "financial_positions_source_kyc_id_fkey" FOREIGN KEY ("source_kyc_id") REFERENCES "public"."kyc_applications"("id");



ALTER TABLE ONLY "public"."kyc_applications"
    ADD CONSTRAINT "kyc_applications_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "public"."profiles"("user_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."kyc_applications"
    ADD CONSTRAINT "kyc_applications_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "public"."staff_members"("user_id");



ALTER TABLE ONLY "public"."kyc_drafts"
    ADD CONSTRAINT "kyc_drafts_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "public"."profiles"("user_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."kyc_events"
    ADD CONSTRAINT "kyc_events_actor_id_fkey" FOREIGN KEY ("actor_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."kyc_events"
    ADD CONSTRAINT "kyc_events_kyc_id_fkey" FOREIGN KEY ("kyc_id") REFERENCES "public"."kyc_applications"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."kyc_review_checklists"
    ADD CONSTRAINT "kyc_review_checklists_kyc_id_fkey" FOREIGN KEY ("kyc_id") REFERENCES "public"."kyc_applications"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."kyc_review_checklists"
    ADD CONSTRAINT "kyc_review_checklists_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "public"."staff_members"("user_id");



ALTER TABLE ONLY "public"."loan_applications"
    ADD CONSTRAINT "loan_applications_credited_position_id_fkey" FOREIGN KEY ("credited_position_id") REFERENCES "public"."financial_positions"("id");



ALTER TABLE ONLY "public"."loan_applications"
    ADD CONSTRAINT "loan_applications_disbursed_by_fkey" FOREIGN KEY ("disbursed_by") REFERENCES "public"."staff_members"("user_id");



ALTER TABLE ONLY "public"."loan_applications"
    ADD CONSTRAINT "loan_applications_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "public"."profiles"("user_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."loan_events"
    ADD CONSTRAINT "loan_events_actor_id_fkey" FOREIGN KEY ("actor_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."loan_events"
    ADD CONSTRAINT "loan_events_loan_id_fkey" FOREIGN KEY ("loan_id") REFERENCES "public"."loan_applications"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."loan_product_settings"
    ADD CONSTRAINT "loan_product_settings_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "public"."staff_members"("user_id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."loan_review_checks"
    ADD CONSTRAINT "loan_review_checks_loan_id_fkey" FOREIGN KEY ("loan_id") REFERENCES "public"."loan_applications"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."loan_review_checks"
    ADD CONSTRAINT "loan_review_checks_reviewer_id_fkey" FOREIGN KEY ("reviewer_id") REFERENCES "public"."staff_members"("user_id");



ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_recipient_id_fkey" FOREIGN KEY ("recipient_id") REFERENCES "public"."profiles"("user_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."official_documents"
    ADD CONSTRAINT "official_documents_account_id_fkey" FOREIGN KEY ("account_id") REFERENCES "public"."financial_positions"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."official_documents"
    ADD CONSTRAINT "official_documents_issued_by_fkey" FOREIGN KEY ("issued_by") REFERENCES "public"."staff_members"("user_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."official_documents"
    ADD CONSTRAINT "official_documents_loan_id_fkey" FOREIGN KEY ("loan_id") REFERENCES "public"."loan_applications"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."official_documents"
    ADD CONSTRAINT "official_documents_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "public"."profiles"("user_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."official_documents"
    ADD CONSTRAINT "official_documents_revoked_by_fkey" FOREIGN KEY ("revoked_by") REFERENCES "public"."staff_members"("user_id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."official_documents"
    ADD CONSTRAINT "official_documents_supersedes_document_id_fkey" FOREIGN KEY ("supersedes_document_id") REFERENCES "public"."official_documents"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."official_documents"
    ADD CONSTRAINT "official_documents_transfer_id_fkey" FOREIGN KEY ("transfer_id") REFERENCES "public"."transfer_intents"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."push_subscriptions"
    ADD CONSTRAINT "push_subscriptions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("user_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."staff_members"
    ADD CONSTRAINT "staff_members_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."support_push_deliveries"
    ADD CONSTRAINT "support_push_deliveries_subscription_id_fkey" FOREIGN KEY ("subscription_id") REFERENCES "public"."push_subscriptions"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."support_push_deliveries"
    ADD CONSTRAINT "support_push_deliveries_transcript_id_fkey" FOREIGN KEY ("transcript_id") REFERENCES "public"."support_transcripts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."support_transcripts"
    ADD CONSTRAINT "support_transcripts_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."profiles"("user_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."transactional_email_outbox"
    ADD CONSTRAINT "transactional_email_outbox_claimed_by_fkey" FOREIGN KEY ("claimed_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."transactional_email_outbox"
    ADD CONSTRAINT "transactional_email_outbox_recipient_id_fkey" FOREIGN KEY ("recipient_id") REFERENCES "public"."profiles"("user_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."transfer_events"
    ADD CONSTRAINT "transfer_events_actor_id_fkey" FOREIGN KEY ("actor_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."transfer_events"
    ADD CONSTRAINT "transfer_events_transfer_id_fkey" FOREIGN KEY ("transfer_id") REFERENCES "public"."transfer_intents"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."transfer_intents"
    ADD CONSTRAINT "transfer_intents_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "public"."profiles"("user_id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."transfer_intents"
    ADD CONSTRAINT "transfer_intents_settled_by_fkey" FOREIGN KEY ("settled_by") REFERENCES "public"."staff_members"("user_id");



ALTER TABLE ONLY "public"."transfer_intents"
    ADD CONSTRAINT "transfer_intents_source_position_id_fkey" FOREIGN KEY ("source_position_id") REFERENCES "public"."financial_positions"("id");



ALTER TABLE ONLY "public"."transfer_review_checks"
    ADD CONSTRAINT "transfer_review_checks_reviewer_id_fkey" FOREIGN KEY ("reviewer_id") REFERENCES "public"."staff_members"("user_id");



ALTER TABLE ONLY "public"."transfer_review_checks"
    ADD CONSTRAINT "transfer_review_checks_transfer_id_fkey" FOREIGN KEY ("transfer_id") REFERENCES "public"."transfer_intents"("id") ON DELETE CASCADE;



ALTER TABLE "public"."audit_events" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "audit_events_staff_select" ON "public"."audit_events" FOR SELECT TO "authenticated" USING (( SELECT "private"."is_active_staff"(ARRAY['supervisor'::"text", 'admin'::"text"]) AS "is_active_staff"));



ALTER TABLE "public"."brand_settings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "brand_settings_public_select" ON "public"."brand_settings" FOR SELECT TO "authenticated", "anon" USING (true);



ALTER TABLE "public"."external_loan_fundings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "external_loan_fundings_select_related" ON "public"."external_loan_fundings" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."loan_applications" "l"
  WHERE (("l"."id" = "external_loan_fundings"."loan_id") AND (("l"."owner_id" = ( SELECT "auth"."uid"() AS "uid")) OR ( SELECT "private"."is_active_staff"(NULL::"text"[]) AS "is_active_staff"))))));



ALTER TABLE "public"."external_transfer_executions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "external_transfer_executions_select_related" ON "public"."external_transfer_executions" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."transfer_intents" "t"
  WHERE (("t"."id" = "external_transfer_executions"."transfer_id") AND (("t"."owner_id" = ( SELECT "auth"."uid"() AS "uid")) OR ( SELECT "private"."is_active_staff"(NULL::"text"[]) AS "is_active_staff"))))));



ALTER TABLE "public"."financial_ledger_entries" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "financial_ledger_entries_select_own_or_admin" ON "public"."financial_ledger_entries" FOR SELECT TO "authenticated" USING ((("owner_id" = ( SELECT "auth"."uid"() AS "uid")) OR ( SELECT "private"."is_active_staff"(ARRAY['admin'::"text"]) AS "is_active_staff")));



ALTER TABLE "public"."financial_positions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "financial_positions_select_own_or_staff" ON "public"."financial_positions" FOR SELECT TO "authenticated" USING ((("owner_id" = ( SELECT "auth"."uid"() AS "uid")) OR ( SELECT "private"."is_active_staff"(NULL::"text"[]) AS "is_active_staff")));



ALTER TABLE "public"."kyc_applications" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "kyc_applications_select_own_or_staff" ON "public"."kyc_applications" FOR SELECT TO "authenticated" USING ((("owner_id" = ( SELECT "auth"."uid"() AS "uid")) OR ( SELECT "private"."is_active_staff"(NULL::"text"[]) AS "is_active_staff")));



ALTER TABLE "public"."kyc_drafts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "kyc_drafts_select_own" ON "public"."kyc_drafts" FOR SELECT TO "authenticated" USING (("owner_id" = ( SELECT "auth"."uid"() AS "uid")));



ALTER TABLE "public"."kyc_events" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "kyc_events_select_related" ON "public"."kyc_events" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."kyc_applications" "k"
  WHERE (("k"."id" = "kyc_events"."kyc_id") AND (("k"."owner_id" = ( SELECT "auth"."uid"() AS "uid")) OR ( SELECT "private"."is_active_staff"(NULL::"text"[]) AS "is_active_staff"))))));



ALTER TABLE "public"."kyc_review_checklists" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "kyc_review_checklists_staff_select" ON "public"."kyc_review_checklists" FOR SELECT TO "authenticated" USING (( SELECT "private"."is_active_staff"(NULL::"text"[]) AS "is_active_staff"));



ALTER TABLE "public"."loan_applications" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "loan_applications_select_own_or_staff" ON "public"."loan_applications" FOR SELECT TO "authenticated" USING ((("owner_id" = ( SELECT "auth"."uid"() AS "uid")) OR ( SELECT "private"."is_active_staff"(NULL::"text"[]) AS "is_active_staff")));



ALTER TABLE "public"."loan_events" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "loan_events_select_related" ON "public"."loan_events" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."loan_applications" "l"
  WHERE (("l"."id" = "loan_events"."loan_id") AND (("l"."owner_id" = ( SELECT "auth"."uid"() AS "uid")) OR ( SELECT "private"."is_active_staff"(NULL::"text"[]) AS "is_active_staff"))))));



ALTER TABLE "public"."loan_product_settings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "loan_product_settings_authenticated_select" ON "public"."loan_product_settings" FOR SELECT TO "authenticated" USING (true);



ALTER TABLE "public"."loan_review_checks" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "loan_review_checks_select_related" ON "public"."loan_review_checks" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."loan_applications" "l"
  WHERE (("l"."id" = "loan_review_checks"."loan_id") AND (("l"."owner_id" = ( SELECT "auth"."uid"() AS "uid")) OR ( SELECT "private"."is_active_staff"(NULL::"text"[]) AS "is_active_staff"))))));



ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "notifications_select_own" ON "public"."notifications" FOR SELECT TO "authenticated" USING (("recipient_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "notifications_update_own" ON "public"."notifications" FOR UPDATE TO "authenticated" USING (("recipient_id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("recipient_id" = ( SELECT "auth"."uid"() AS "uid")));



ALTER TABLE "public"."official_documents" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "official_documents_select_own_or_admin" ON "public"."official_documents" FOR SELECT TO "authenticated" USING ((("owner_id" = ( SELECT "auth"."uid"() AS "uid")) OR ( SELECT "private"."is_active_staff"(ARRAY['admin'::"text"]) AS "is_active_staff")));



ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "profiles_select_own_or_staff" ON "public"."profiles" FOR SELECT TO "authenticated" USING ((("user_id" = ( SELECT "auth"."uid"() AS "uid")) OR ( SELECT "private"."is_active_staff"(NULL::"text"[]) AS "is_active_staff")));



CREATE POLICY "profiles_update_own" ON "public"."profiles" FOR UPDATE TO "authenticated" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



ALTER TABLE "public"."push_subscriptions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."staff_members" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "staff_members_select_self" ON "public"."staff_members" FOR SELECT TO "authenticated" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



ALTER TABLE "public"."support_push_deliveries" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."support_transcripts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."support_user_identities" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."transactional_email_outbox" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."transfer_events" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "transfer_events_select_related" ON "public"."transfer_events" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."transfer_intents" "t"
  WHERE (("t"."id" = "transfer_events"."transfer_id") AND (("t"."owner_id" = ( SELECT "auth"."uid"() AS "uid")) OR ( SELECT "private"."is_active_staff"(NULL::"text"[]) AS "is_active_staff"))))));



ALTER TABLE "public"."transfer_intents" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "transfer_intents_select_own_or_staff" ON "public"."transfer_intents" FOR SELECT TO "authenticated" USING ((("owner_id" = ( SELECT "auth"."uid"() AS "uid")) OR ( SELECT "private"."is_active_staff"(NULL::"text"[]) AS "is_active_staff")));



ALTER TABLE "public"."transfer_review_checks" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "transfer_review_checks_select_related" ON "public"."transfer_review_checks" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."transfer_intents" "t"
  WHERE (("t"."id" = "transfer_review_checks"."transfer_id") AND (("t"."owner_id" = ( SELECT "auth"."uid"() AS "uid")) OR ( SELECT "private"."is_active_staff"(NULL::"text"[]) AS "is_active_staff"))))));



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



REVOKE ALL ON FUNCTION "private"."allocate_internal_account_number"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."allocate_internal_account_number"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."arm_guarded_client_auth_delete"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."audit_event_matches_client"("p_actor_id" "uuid", "p_entity_type" "text", "p_entity_id" "uuid", "p_metadata" "jsonb", "p_target_user_id" "uuid", "p_challenge_id" "uuid") FROM PUBLIC;



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."transactional_email_outbox" TO "service_role";



REVOKE ALL ON FUNCTION "private"."claim_transactional_emails_internal"("p_limit" integer, "p_recipient_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."claim_transactional_emails_internal"("p_limit" integer, "p_recipient_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "private"."client_purge_lock_key"("p_owner_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."client_purge_residuals"("p_challenge_id" "uuid", "p_target_user_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."client_purge_scope_digest"("p_challenge_id" "uuid", "p_target_user_id" "uuid", "p_support_emails" "jsonb") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."client_purge_storage_lock_key"("p_bucket" "text", "p_object_path" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."client_purge_storage_references"("p_target_user_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."enforce_client_document_path_ownership"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."enforce_external_evidence_path_ownership"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."enforce_official_document_path_ownership"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."enforce_profile_base_currency_immutability"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."enforce_profile_base_currency_immutability"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."enqueue_financial_workflow_email"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."enqueue_financial_workflow_email"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."enqueue_kyc_message"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."enqueue_kyc_message"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."enqueue_transfer_check_validation_email"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."ensure_active_user"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."ensure_active_user"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."ensure_branch_manager"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."ensure_branch_manager"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."ensure_demo_banking_artifacts"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."ensure_demo_banking_artifacts"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."freeze_profile_during_client_purge"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."guard_client_audit_mutation"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."guard_direct_client_mutation"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."guard_indirect_client_mutation"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."guard_support_transcript_mutation"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."handle_new_user"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."handle_new_user"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."initialize_client_purge_storage_cycle"("p_challenge_id" "uuid", "p_cycle_stage" "text", "p_target_user_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."is_active_staff"("required_roles" "text"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."is_active_staff"("required_roles" "text"[]) TO "service_role";
GRANT ALL ON FUNCTION "private"."is_active_staff"("required_roles" "text"[]) TO "authenticated";



REVOKE ALL ON FUNCTION "private"."is_client_storage_object_key"("p_path" "text", "p_owner_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."is_client_storage_path"("p_path" "text", "p_owner_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."is_valid_iban"("p_iban" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."is_valid_iban"("p_iban" "text") TO "service_role";



REVOKE ALL ON FUNCTION "private"."lock_client_mutation"("p_owner_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."new_document_paths_are_owned"("p_owner_id" "uuid", "p_new_paths" "jsonb", "p_old_paths" "jsonb") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."normalize_iban"("p_iban" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."normalize_iban"("p_iban" "text") TO "service_role";



REVOKE ALL ON FUNCTION "private"."normalize_notification_localization"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."normalize_notification_localization"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."prepare_demo_financial_position"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."prepare_demo_financial_position"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."prevent_financial_ledger_mutation"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."prevent_financial_ledger_mutation"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."prevent_purge_target_promotion"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."protect_official_document"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."protect_official_document"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."refresh_client_purge_entity_manifest"("p_challenge_id" "uuid", "p_target_user_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."reject_reserved_purge_email"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."remove_iban_from_new_official_document"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."remove_iban_from_new_official_document"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."require_active_purge_admin"("p_actor_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."retire_support_user_identity"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."retire_support_user_identity"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."seed_client_purge_storage_roots"("p_challenge_id" "uuid", "p_cycle_stage" "text", "p_target_user_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."set_updated_at"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."set_updated_at"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."snapshot_official_document_brand"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."snapshot_official_document_brand"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."sync_support_user_identity"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."sync_support_user_identity"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."try_guard_client_mutation"("p_owner_id" "uuid") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."uuid_or_null"("p_value" "text") FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."validate_financial_ledger_entry"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."validate_financial_ledger_entry"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."validate_kyc_submission"("p_first_name" "text", "p_last_name" "text", "p_date_of_birth" "date", "p_place_of_birth" "text", "p_nationality" "text", "p_address" "jsonb", "p_occupation" "text", "p_income_range" "text", "p_document_type" "text", "p_document_number" "text", "p_issuing_country" "text", "p_document_expires_on" "date", "p_document_object_paths" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."validate_kyc_submission"("p_first_name" "text", "p_last_name" "text", "p_date_of_birth" "date", "p_place_of_birth" "text", "p_nationality" "text", "p_address" "jsonb", "p_occupation" "text", "p_income_range" "text", "p_document_type" "text", "p_document_number" "text", "p_issuing_country" "text", "p_document_expires_on" "date", "p_document_object_paths" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "private"."validate_loan_disbursement_target"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."validate_loan_disbursement_target"() TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."financial_positions" TO "service_role";
GRANT SELECT ON TABLE "public"."financial_positions" TO "authenticated";



REVOKE ALL ON FUNCTION "public"."adjust_financial_position"("p_position_id" "uuid", "p_delta_minor" bigint, "p_as_of" timestamp with time zone, "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."adjust_financial_position"("p_position_id" "uuid", "p_delta_minor" bigint, "p_as_of" timestamp with time zone, "p_reason" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_ack_client_purge_storage_work"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_challenge_id" "uuid", "p_claim_token" "uuid", "p_kind" "text", "p_result" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_ack_client_purge_storage_work"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_challenge_id" "uuid", "p_claim_token" "uuid", "p_kind" "text", "p_result" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_assert_client_purge_auth_ready"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_challenge_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_assert_client_purge_auth_ready"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_challenge_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_begin_client_purge"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_challenge_id" "uuid", "p_challenge_digest" "text", "p_target_email_digest" "text", "p_idempotency_key" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_begin_client_purge"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_challenge_id" "uuid", "p_challenge_digest" "text", "p_target_email_digest" "text", "p_idempotency_key" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_claim_client_purge_storage_work"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_challenge_id" "uuid", "p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_claim_client_purge_storage_work"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_challenge_id" "uuid", "p_limit" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_finalize_client_purge"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_challenge_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_finalize_client_purge"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_challenge_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_get_client_purge_preview"("p_actor_id" "uuid", "p_target_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_get_client_purge_preview"("p_actor_id" "uuid", "p_target_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_get_client_purge_status"("p_actor_id" "uuid", "p_target_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_get_client_purge_status"("p_actor_id" "uuid", "p_target_user_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_list_client_purge_candidates"("p_actor_id" "uuid", "p_search" "text", "p_limit" integer, "p_offset" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_list_client_purge_candidates"("p_actor_id" "uuid", "p_search" "text", "p_limit" integer, "p_offset" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_list_pending_client_purges"("p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_list_pending_client_purges"("p_limit" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_mark_client_purge_stage"("p_actor_id" "uuid", "p_challenge_id" "uuid", "p_stage" "text", "p_error_code" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_mark_client_purge_stage"("p_actor_id" "uuid", "p_challenge_id" "uuid", "p_stage" "text", "p_error_code" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_prepare_client_purge"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_challenge_digest" "text", "p_target_email_digest" "text", "p_target_email" "text", "p_idempotency_key" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_prepare_client_purge"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_challenge_digest" "text", "p_target_email_digest" "text", "p_target_email" "text", "p_idempotency_key" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_purge_client_relational_data"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_challenge_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_purge_client_relational_data"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_challenge_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_resume_client_purge"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_target_email_digest" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_resume_client_purge"("p_actor_id" "uuid", "p_target_user_id" "uuid", "p_target_email_digest" "text") TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."kyc_applications" TO "service_role";
GRANT SELECT ON TABLE "public"."kyc_applications" TO "authenticated";



REVOKE ALL ON FUNCTION "public"."begin_kyc_review"("p_kyc_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."begin_kyc_review"("p_kyc_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."begin_kyc_review"("p_kyc_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."branch_manager_adjust_balance"("p_account_id" "uuid", "p_target_amount_minor" bigint, "p_value_date" timestamp with time zone, "p_reason" "text", "p_idempotency_key" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."branch_manager_adjust_balance"("p_account_id" "uuid", "p_target_amount_minor" bigint, "p_value_date" timestamp with time zone, "p_reason" "text", "p_idempotency_key" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."branch_manager_adjust_balance"("p_account_id" "uuid", "p_target_amount_minor" bigint, "p_value_date" timestamp with time zone, "p_reason" "text", "p_idempotency_key" "uuid") TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."loan_applications" TO "service_role";
GRANT SELECT ON TABLE "public"."loan_applications" TO "authenticated";



REVOKE ALL ON FUNCTION "public"."branch_manager_approve_loan"("p_loan_id" "uuid", "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."branch_manager_approve_loan"("p_loan_id" "uuid", "p_note" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."branch_manager_approve_loan"("p_loan_id" "uuid", "p_note" "text") TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."transfer_intents" TO "service_role";
GRANT SELECT ON TABLE "public"."transfer_intents" TO "authenticated";



REVOKE ALL ON FUNCTION "public"."branch_manager_approve_transfer"("p_transfer_id" "uuid", "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."branch_manager_approve_transfer"("p_transfer_id" "uuid", "p_note" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."branch_manager_declare_account"("p_owner_id" "uuid", "p_label" "text", "p_account_type" "text", "p_currency" "text", "p_iban" "text", "p_bic" "text", "p_account_holder_name" "text", "p_institution_name" "text", "p_branch_name" "text", "p_branch_code" "text", "p_opening_balance_minor" bigint, "p_opened_at" timestamp with time zone, "p_is_demo" boolean, "p_reason" "text", "p_idempotency_key" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."branch_manager_declare_account"("p_owner_id" "uuid", "p_label" "text", "p_account_type" "text", "p_currency" "text", "p_iban" "text", "p_bic" "text", "p_account_holder_name" "text", "p_institution_name" "text", "p_branch_name" "text", "p_branch_code" "text", "p_opening_balance_minor" bigint, "p_opened_at" timestamp with time zone, "p_is_demo" boolean, "p_reason" "text", "p_idempotency_key" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."branch_manager_declare_account"("p_owner_id" "uuid", "p_label" "text", "p_account_type" "text", "p_currency" "text", "p_iban" "text", "p_bic" "text", "p_account_holder_name" "text", "p_institution_name" "text", "p_branch_name" "text", "p_branch_code" "text", "p_opening_balance_minor" bigint, "p_opened_at" timestamp with time zone, "p_is_demo" boolean, "p_reason" "text", "p_idempotency_key" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."branch_manager_disburse_loan"("p_loan_id" "uuid", "p_destination_position_id" "uuid", "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."branch_manager_disburse_loan"("p_loan_id" "uuid", "p_destination_position_id" "uuid", "p_note" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."branch_manager_disburse_loan"("p_loan_id" "uuid", "p_destination_position_id" "uuid", "p_note" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."branch_manager_finalize_transfer"("p_transfer_id" "uuid", "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."branch_manager_finalize_transfer"("p_transfer_id" "uuid", "p_note" "text") TO "service_role";



GRANT SELECT ON TABLE "public"."official_documents" TO "authenticated";
GRANT SELECT ON TABLE "public"."official_documents" TO "service_role";



REVOKE ALL ON FUNCTION "public"."branch_manager_issue_official_document"("p_owner_id" "uuid", "p_account_id" "uuid", "p_transfer_id" "uuid", "p_loan_id" "uuid", "p_document_type" "text", "p_title" "text", "p_language" "text", "p_period_start" "date", "p_period_end" "date", "p_idempotency_key" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."branch_manager_issue_official_document"("p_owner_id" "uuid", "p_account_id" "uuid", "p_transfer_id" "uuid", "p_loan_id" "uuid", "p_document_type" "text", "p_title" "text", "p_language" "text", "p_period_start" "date", "p_period_end" "date", "p_idempotency_key" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."branch_manager_issue_official_document"("p_owner_id" "uuid", "p_account_id" "uuid", "p_transfer_id" "uuid", "p_loan_id" "uuid", "p_document_type" "text", "p_title" "text", "p_language" "text", "p_period_start" "date", "p_period_end" "date", "p_idempotency_key" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."branch_manager_reject_loan"("p_loan_id" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."branch_manager_reject_loan"("p_loan_id" "uuid", "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."branch_manager_reject_loan"("p_loan_id" "uuid", "p_reason" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."branch_manager_reject_transfer"("p_transfer_id" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."branch_manager_reject_transfer"("p_transfer_id" "uuid", "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."branch_manager_reject_transfer"("p_transfer_id" "uuid", "p_reason" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."branch_manager_review_transfer_check"("p_transfer_id" "uuid", "p_check_kind" "text", "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."branch_manager_review_transfer_check"("p_transfer_id" "uuid", "p_check_kind" "text", "p_note" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."branch_manager_review_transfer_check"("p_transfer_id" "uuid", "p_check_kind" "text", "p_note" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."branch_manager_revoke_official_document"("p_document_id" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."branch_manager_revoke_official_document"("p_document_id" "uuid", "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."branch_manager_revoke_official_document"("p_document_id" "uuid", "p_reason" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."claim_support_transcript"("p_transcript_id" "uuid", "p_claim_token" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."claim_support_transcript"("p_transcript_id" "uuid", "p_claim_token" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."claim_transactional_emails"("p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."claim_transactional_emails"("p_limit" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."claim_transactional_emails_for_recipient"("p_recipient_id" "uuid", "p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."claim_transactional_emails_for_recipient"("p_recipient_id" "uuid", "p_limit" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."complete_official_document"("p_document_id" "uuid", "p_storage_path" "text", "p_content_hash" "text", "p_succeeded" boolean, "p_error" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."complete_official_document"("p_document_id" "uuid", "p_storage_path" "text", "p_content_hash" "text", "p_succeeded" boolean, "p_error" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."complete_transactional_email"("p_email_id" "uuid", "p_claim_token" "uuid", "p_succeeded" boolean, "p_provider_message_id" "text", "p_error" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."complete_transactional_email"("p_email_id" "uuid", "p_claim_token" "uuid", "p_succeeded" boolean, "p_provider_message_id" "text", "p_error" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."create_official_document_localized_reissue"("p_source_document_id" "uuid", "p_idempotency_key" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_official_document_localized_reissue"("p_source_document_id" "uuid", "p_idempotency_key" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."current_app_role"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."current_app_role"() TO "service_role";
GRANT ALL ON FUNCTION "public"."current_app_role"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."decide_kyc_application"("p_kyc_id" "uuid", "p_decision" "text", "p_reason_code" "text", "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."decide_kyc_application"("p_kyc_id" "uuid", "p_decision" "text", "p_reason_code" "text", "p_note" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."decide_kyc_application"("p_kyc_id" "uuid", "p_decision" "text", "p_reason_code" "text", "p_note" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."finalize_official_document_localized_reissue"("p_replacement_document_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."finalize_official_document_localized_reissue"("p_replacement_document_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_account_number_configuration"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_account_number_configuration"() TO "service_role";
GRANT ALL ON FUNCTION "public"."get_account_number_configuration"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."mark_notification_read"("p_notification_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."mark_notification_read"("p_notification_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."mark_notification_read"("p_notification_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."provision_demo_accounts"("p_admin_user_id" "uuid", "p_client_user_id" "uuid", "p_environment" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."provision_demo_accounts"("p_admin_user_id" "uuid", "p_client_user_id" "uuid", "p_environment" "text") TO "service_role";



GRANT SELECT ON TABLE "public"."brand_settings" TO "anon";
GRANT SELECT ON TABLE "public"."brand_settings" TO "authenticated";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."brand_settings" TO "service_role";



REVOKE ALL ON FUNCTION "public"."publish_brand_settings"("p_expected_revision" bigint, "p_bank_name" "text", "p_primary_logo_path" "text", "p_primary_logo_width" integer, "p_primary_logo_height" integer, "p_reversed_logo_path" "text", "p_reversed_logo_width" integer, "p_reversed_logo_height" integer, "p_email_logo_path" "text", "p_pdf_logo_path" "text", "p_favicon_ico_path" "text", "p_favicon_16_path" "text", "p_favicon_32_path" "text", "p_favicon_48_path" "text", "p_apple_touch_icon_path" "text", "p_app_icon_192_path" "text", "p_app_icon_512_path" "text", "p_maskable_icon_path" "text", "p_social_card_path" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."publish_brand_settings"("p_expected_revision" bigint, "p_bank_name" "text", "p_primary_logo_path" "text", "p_primary_logo_width" integer, "p_primary_logo_height" integer, "p_reversed_logo_path" "text", "p_reversed_logo_width" integer, "p_reversed_logo_height" integer, "p_email_logo_path" "text", "p_pdf_logo_path" "text", "p_favicon_ico_path" "text", "p_favicon_16_path" "text", "p_favicon_32_path" "text", "p_favicon_48_path" "text", "p_apple_touch_icon_path" "text", "p_app_icon_192_path" "text", "p_app_icon_512_path" "text", "p_maskable_icon_path" "text", "p_social_card_path" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."publish_brand_settings"("p_expected_revision" bigint, "p_bank_name" "text", "p_primary_logo_path" "text", "p_primary_logo_width" integer, "p_primary_logo_height" integer, "p_reversed_logo_path" "text", "p_reversed_logo_width" integer, "p_reversed_logo_height" integer, "p_email_logo_path" "text", "p_pdf_logo_path" "text", "p_favicon_ico_path" "text", "p_favicon_16_path" "text", "p_favicon_32_path" "text", "p_favicon_48_path" "text", "p_apple_touch_icon_path" "text", "p_app_icon_192_path" "text", "p_app_icon_512_path" "text", "p_maskable_icon_path" "text", "p_social_card_path" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."record_admin_credentials_update"("p_actor_id" "uuid", "p_email_changed" boolean, "p_password_changed" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."record_admin_credentials_update"("p_actor_id" "uuid", "p_email_changed" boolean, "p_password_changed" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."record_financial_position"("p_owner_id" "uuid", "p_label" "text", "p_currency" "text", "p_amount_minor" bigint, "p_as_of" timestamp with time zone, "p_external_identifier_masked" "text", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."record_financial_position"("p_owner_id" "uuid", "p_label" "text", "p_currency" "text", "p_amount_minor" bigint, "p_as_of" timestamp with time zone, "p_external_identifier_masked" "text", "p_reason" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."register_push_subscription"("p_expected_user_id" "uuid", "p_endpoint" "text", "p_p256dh" "text", "p_auth_key" "text", "p_expiration_time" bigint, "p_user_agent" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."register_push_subscription"("p_expected_user_id" "uuid", "p_endpoint" "text", "p_p256dh" "text", "p_auth_key" "text", "p_expiration_time" bigint, "p_user_agent" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."register_push_subscription"("p_expected_user_id" "uuid", "p_endpoint" "text", "p_p256dh" "text", "p_auth_key" "text", "p_expiration_time" bigint, "p_user_agent" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."release_support_transcript_claim"("p_transcript_id" "uuid", "p_claim_token" "uuid", "p_completed" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."release_support_transcript_claim"("p_transcript_id" "uuid", "p_claim_token" "uuid", "p_completed" boolean) TO "service_role";



REVOKE ALL ON FUNCTION "public"."request_kyc_information"("p_kyc_id" "uuid", "p_requested_items" "text"[], "p_reason_code" "text", "p_note" "text", "p_due_at" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."request_kyc_information"("p_kyc_id" "uuid", "p_requested_items" "text"[], "p_reason_code" "text", "p_note" "text", "p_due_at" timestamp with time zone) TO "service_role";
GRANT ALL ON FUNCTION "public"."request_kyc_information"("p_kyc_id" "uuid", "p_requested_items" "text"[], "p_reason_code" "text", "p_note" "text", "p_due_at" timestamp with time zone) TO "authenticated";



REVOKE ALL ON FUNCTION "public"."resubmit_kyc_application"("p_kyc_id" "uuid", "p_changes" "jsonb", "p_document_object_paths" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."resubmit_kyc_application"("p_kyc_id" "uuid", "p_changes" "jsonb", "p_document_object_paths" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."resubmit_kyc_application"("p_kyc_id" "uuid", "p_changes" "jsonb", "p_document_object_paths" "jsonb") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."review_kyc_application"("p_kyc_id" "uuid", "p_status" "text", "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."review_kyc_application"("p_kyc_id" "uuid", "p_status" "text", "p_note" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."review_loan_check"("p_loan_id" "uuid", "p_check_kind" "text", "p_status" "text", "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."review_loan_check"("p_loan_id" "uuid", "p_check_kind" "text", "p_status" "text", "p_note" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."review_transfer_check"("p_transfer_id" "uuid", "p_check_kind" "text", "p_status" "text", "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."review_transfer_check"("p_transfer_id" "uuid", "p_check_kind" "text", "p_status" "text", "p_note" "text") TO "service_role";



GRANT ALL ON TABLE "public"."kyc_drafts" TO "service_role";
GRANT SELECT ON TABLE "public"."kyc_drafts" TO "authenticated";



REVOKE ALL ON FUNCTION "public"."save_kyc_draft"("p_current_step" integer, "p_payload" "jsonb", "p_document_object_paths" "jsonb", "p_preferred_language" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."save_kyc_draft"("p_current_step" integer, "p_payload" "jsonb", "p_document_object_paths" "jsonb", "p_preferred_language" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."save_kyc_draft"("p_current_step" integer, "p_payload" "jsonb", "p_document_object_paths" "jsonb", "p_preferred_language" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."set_account_number_prefix"("p_prefix" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_account_number_prefix"("p_prefix" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."set_account_number_prefix"("p_prefix" "text") TO "authenticated";



GRANT SELECT ON TABLE "public"."profiles" TO "authenticated";
GRANT SELECT ON TABLE "public"."profiles" TO "service_role";



GRANT UPDATE("display_name") ON TABLE "public"."profiles" TO "authenticated";



GRANT UPDATE("phone") ON TABLE "public"."profiles" TO "authenticated";



GRANT UPDATE("preferred_currency") ON TABLE "public"."profiles" TO "authenticated";



GRANT UPDATE("preferred_language") ON TABLE "public"."profiles" TO "authenticated";



REVOKE ALL ON FUNCTION "public"."set_user_access_status"("p_user_id" "uuid", "p_status" "text", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."set_user_access_status"("p_user_id" "uuid", "p_status" "text", "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."set_user_access_status"("p_user_id" "uuid", "p_status" "text", "p_reason" "text") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."submit_kyc_application"("p_first_name" "text", "p_last_name" "text", "p_date_of_birth" "date", "p_place_of_birth" "text", "p_nationality" "text", "p_address" "jsonb", "p_occupation" "text", "p_income_range" "text", "p_fatca" boolean, "p_pep" boolean, "p_document_type" "text", "p_document_number" "text", "p_issuing_country" "text", "p_document_expires_on" "date", "p_document_object_paths" "jsonb", "p_idempotency_key" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."submit_kyc_application"("p_first_name" "text", "p_last_name" "text", "p_date_of_birth" "date", "p_place_of_birth" "text", "p_nationality" "text", "p_address" "jsonb", "p_occupation" "text", "p_income_range" "text", "p_fatca" boolean, "p_pep" boolean, "p_document_type" "text", "p_document_number" "text", "p_issuing_country" "text", "p_document_expires_on" "date", "p_document_object_paths" "jsonb", "p_idempotency_key" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."submit_kyc_application"("p_first_name" "text", "p_last_name" "text", "p_date_of_birth" "date", "p_place_of_birth" "text", "p_nationality" "text", "p_address" "jsonb", "p_occupation" "text", "p_income_range" "text", "p_fatca" boolean, "p_pep" boolean, "p_document_type" "text", "p_document_number" "text", "p_issuing_country" "text", "p_document_expires_on" "date", "p_document_object_paths" "jsonb", "p_idempotency_key" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."submit_loan_application"("p_requested_amount_minor" bigint, "p_currency" "text", "p_duration_months" integer, "p_motive_code" "text", "p_document_object_paths" "jsonb", "p_idempotency_key" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."submit_loan_application"("p_requested_amount_minor" bigint, "p_currency" "text", "p_duration_months" integer, "p_motive_code" "text", "p_document_object_paths" "jsonb", "p_idempotency_key" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_loan_application"("p_requested_amount_minor" bigint, "p_currency" "text", "p_duration_months" integer, "p_motive_code" "text", "p_document_object_paths" "jsonb", "p_idempotency_key" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."submit_transfer_intent"("p_source_position_id" "uuid", "p_recipient_name" "text", "p_recipient_account_masked" "text", "p_beneficiary_details" "jsonb", "p_transfer_type" "text", "p_amount_minor" bigint, "p_currency" "text", "p_target_amount_minor" bigint, "p_target_currency" "text", "p_quote_rate" numeric, "p_quote_as_of" timestamp with time zone, "p_motive" "text", "p_idempotency_key" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."submit_transfer_intent"("p_source_position_id" "uuid", "p_recipient_name" "text", "p_recipient_account_masked" "text", "p_beneficiary_details" "jsonb", "p_transfer_type" "text", "p_amount_minor" bigint, "p_currency" "text", "p_target_amount_minor" bigint, "p_target_currency" "text", "p_quote_rate" numeric, "p_quote_as_of" timestamp with time zone, "p_motive" "text", "p_idempotency_key" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."submit_transfer_intent"("p_source_position_id" "uuid", "p_recipient_name" "text", "p_recipient_account_masked" "text", "p_beneficiary_details" "jsonb", "p_transfer_type" "text", "p_amount_minor" bigint, "p_currency" "text", "p_target_amount_minor" bigint, "p_target_currency" "text", "p_quote_rate" numeric, "p_quote_as_of" timestamp with time zone, "p_motive" "text", "p_idempotency_key" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "public"."transition_loan"("p_loan_id" "uuid", "p_action" "text", "p_reason" "text", "p_external_reference" "text", "p_evidence_object_path" "text", "p_executed_at" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."transition_loan"("p_loan_id" "uuid", "p_action" "text", "p_reason" "text", "p_external_reference" "text", "p_evidence_object_path" "text", "p_executed_at" timestamp with time zone) TO "service_role";



REVOKE ALL ON FUNCTION "public"."transition_transfer"("p_transfer_id" "uuid", "p_action" "text", "p_reason" "text", "p_external_reference" "text", "p_evidence_object_path" "text", "p_executed_at" timestamp with time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."transition_transfer"("p_transfer_id" "uuid", "p_action" "text", "p_reason" "text", "p_external_reference" "text", "p_evidence_object_path" "text", "p_executed_at" timestamp with time zone) TO "service_role";



REVOKE ALL ON FUNCTION "public"."unregister_push_subscription"("p_expected_user_id" "uuid", "p_endpoint" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."unregister_push_subscription"("p_expected_user_id" "uuid", "p_endpoint" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."unregister_push_subscription"("p_expected_user_id" "uuid", "p_endpoint" "text") TO "authenticated";



GRANT ALL ON TABLE "public"."kyc_review_checklists" TO "service_role";
GRANT SELECT ON TABLE "public"."kyc_review_checklists" TO "authenticated";



REVOKE ALL ON FUNCTION "public"."update_kyc_review_checklist"("p_kyc_id" "uuid", "p_document_quality" "text", "p_data_consistency" "text", "p_selfie_match" "text", "p_adulthood" "text", "p_fatca" "text", "p_pep" "text", "p_internal_comments" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_kyc_review_checklist"("p_kyc_id" "uuid", "p_document_quality" "text", "p_data_consistency" "text", "p_selfie_match" "text", "p_adulthood" "text", "p_fatca" "text", "p_pep" "text", "p_internal_comments" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."update_kyc_review_checklist"("p_kyc_id" "uuid", "p_document_quality" "text", "p_data_consistency" "text", "p_selfie_match" "text", "p_adulthood" "text", "p_fatca" "text", "p_pep" "text", "p_internal_comments" "text") TO "authenticated";



GRANT SELECT ON TABLE "public"."loan_product_settings" TO "authenticated";



REVOKE ALL ON FUNCTION "public"."update_loan_product_settings"("p_currency" "text", "p_minimum_amount_minor" bigint, "p_maximum_amount_minor" bigint, "p_minimum_duration_months" integer, "p_maximum_duration_months" integer, "p_duration_step_months" integer, "p_fixed_annual_rate" numeric, "p_reference_prefix" "text", "p_is_active" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."update_loan_product_settings"("p_currency" "text", "p_minimum_amount_minor" bigint, "p_maximum_amount_minor" bigint, "p_minimum_duration_months" integer, "p_maximum_duration_months" integer, "p_duration_step_months" integer, "p_fixed_annual_rate" numeric, "p_reference_prefix" "text", "p_is_active" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."update_loan_product_settings"("p_currency" "text", "p_minimum_amount_minor" bigint, "p_maximum_amount_minor" bigint, "p_minimum_duration_months" integer, "p_maximum_duration_months" integer, "p_duration_step_months" integer, "p_fixed_annual_rate" numeric, "p_reference_prefix" "text", "p_is_active" boolean) TO "authenticated";



GRANT SELECT,INSERT,UPDATE ON TABLE "private"."account_number_configuration" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."audit_events" TO "service_role";
GRANT SELECT ON TABLE "public"."audit_events" TO "authenticated";



GRANT UPDATE ON SEQUENCE "public"."audit_events_id_seq" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."external_loan_fundings" TO "service_role";
GRANT SELECT ON TABLE "public"."external_loan_fundings" TO "authenticated";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."external_transfer_executions" TO "service_role";
GRANT SELECT ON TABLE "public"."external_transfer_executions" TO "authenticated";



GRANT SELECT ON TABLE "public"."financial_ledger_entries" TO "authenticated";
GRANT SELECT ON TABLE "public"."financial_ledger_entries" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."kyc_events" TO "service_role";
GRANT SELECT ON TABLE "public"."kyc_events" TO "authenticated";



GRANT UPDATE ON SEQUENCE "public"."kyc_events_id_seq" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."loan_events" TO "service_role";
GRANT SELECT ON TABLE "public"."loan_events" TO "authenticated";



GRANT UPDATE ON SEQUENCE "public"."loan_events_id_seq" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."loan_review_checks" TO "service_role";
GRANT SELECT ON TABLE "public"."loan_review_checks" TO "authenticated";



GRANT UPDATE ON SEQUENCE "public"."loan_review_checks_id_seq" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."notifications" TO "service_role";
GRANT SELECT ON TABLE "public"."notifications" TO "authenticated";



GRANT UPDATE("read_at") ON TABLE "public"."notifications" TO "authenticated";



GRANT ALL ON TABLE "public"."push_subscriptions" TO "service_role";



GRANT SELECT ON TABLE "public"."staff_members" TO "authenticated";
GRANT SELECT ON TABLE "public"."staff_members" TO "service_role";



GRANT ALL ON TABLE "public"."support_push_deliveries" TO "service_role";



GRANT ALL ON TABLE "public"."support_transcripts" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."support_user_identities" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."transfer_events" TO "service_role";
GRANT SELECT ON TABLE "public"."transfer_events" TO "authenticated";



GRANT UPDATE ON SEQUENCE "public"."transfer_events_id_seq" TO "service_role";



GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."transfer_review_checks" TO "service_role";
GRANT SELECT ON TABLE "public"."transfer_review_checks" TO "authenticated";



GRANT UPDATE ON SEQUENCE "public"."transfer_review_checks_id_seq" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "private" GRANT ALL ON FUNCTIONS TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT UPDATE ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLES TO "service_role";
