import type { Config } from '@netlify/functions';
import { getTransactionalEmailConfig } from '../../lib/server/transactional-email';
import {
  createTransactionalEmailPrivilegedClient,
  dispatchTransactionalEmailBatch,
  TRANSACTIONAL_EMAIL_DISPATCH_CONCURRENCY,
  TRANSACTIONAL_EMAIL_PROVIDER_TIMEOUT_MS,
  TRANSACTIONAL_EMAIL_SCHEDULED_BATCH_SIZE,
} from '../../lib/server/transactional-email-dispatch';

const ENVIRONMENT_KEYS = [
  'NEXT_PUBLIC_SUPABASE_URL',
  'SUPABASE_SECRET_KEY',
  'SUPABASE_SERVICE_ROLE_KEY',
  'TRANSACTIONAL_EMAIL_PROVIDER',
  'TRANSACTIONAL_EMAIL_FROM_EMAIL',
  'TRANSACTIONAL_EMAIL_FROM_NAME',
  'TRANSACTIONAL_EMAIL_REPLY_TO',
  'TRANSACTIONAL_EMAIL_ASSET_BASE_URL',
  'APP_ORIGIN',
  'NEXT_PUBLIC_APP_ORIGIN',
  'RESEND_API_KEY',
  'BREVO_API_KEY',
] as const;

function netlifyEnvironment(): NodeJS.ProcessEnv {
  const configuredNodeEnvironment = Netlify.env.get('NODE_ENV');
  const nodeEnvironment =
    configuredNodeEnvironment === 'development' ||
    configuredNodeEnvironment === 'test'
      ? configuredNodeEnvironment
      : 'production';
  return {
    NODE_ENV: nodeEnvironment,
    ...Object.fromEntries(
      ENVIRONMENT_KEYS.map((key) => [key, Netlify.env.get(key)]),
    ),
  };
}

export default async function transactionalEmailWorker(_request: Request) {
  const startedAt = Date.now();
  const environment = netlifyEnvironment();

  try {
    const result = await dispatchTransactionalEmailBatch({
      client: createTransactionalEmailPrivilegedClient(environment),
      config: getTransactionalEmailConfig(environment),
      supabaseUrl: environment.NEXT_PUBLIC_SUPABASE_URL,
      limit: TRANSACTIONAL_EMAIL_SCHEDULED_BATCH_SIZE,
      providerTimeoutMs: TRANSACTIONAL_EMAIL_PROVIDER_TIMEOUT_MS,
      concurrency: TRANSACTIONAL_EMAIL_DISPATCH_CONCURRENCY,
    });
    const summary = {
      event:
        result.completionFailed === 0
          ? 'transactional_email_worker_completed'
          : 'transactional_email_worker_incomplete',
      ...result,
      durationMs: Date.now() - startedAt,
    };
    if (result.completionFailed > 0) {
      throw new Error(
        `Finalisation incomplète du lot e-mail (${result.completionFailed}/${result.claimed}).`,
      );
    }
    console.info(JSON.stringify(summary));
  } catch (error) {
    const summary = {
      event: 'transactional_email_worker_failed',
      error:
        error instanceof Error ? error.message : 'Erreur worker non détaillée.',
      durationMs: Date.now() - startedAt,
    };
    console.error(JSON.stringify(summary));
    throw error;
  }
}

export const config: Config = {
  schedule: '*/5 * * * *',
};
