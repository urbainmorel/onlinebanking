import type { Config } from '@netlify/functions';

export const CLIENT_PURGE_SCHEDULED_FUNCTION_TIMEOUT_MS = 25_000;

function requiredEnvironment(name: string) {
  const value = Netlify.env.get(name)?.trim();
  if (!value) throw new Error(`${name}_MISSING`);
  return value;
}

function applicationOrigin() {
  const raw =
    Netlify.env.get('APP_ORIGIN')?.trim() ||
    Netlify.env.get('NEXT_PUBLIC_APP_ORIGIN')?.trim();
  if (!raw) throw new Error('APP_ORIGIN_MISSING');
  const url = new URL(raw);
  if (
    url.protocol !== 'https:' ||
    url.username ||
    url.password ||
    url.search ||
    url.hash
  ) {
    throw new Error('APP_ORIGIN_INVALID');
  }
  return url.origin;
}

export default async function clientPurgeSweep(_request: Request) {
  const startedAt = Date.now();
  try {
    const secret = requiredEnvironment('CLIENT_PURGE_SWEEP_SECRET');
    if (Buffer.byteLength(secret) < 32) {
      throw new Error('CLIENT_PURGE_SWEEP_SECRET_TOO_SHORT');
    }
    const response = await fetch(
      `${applicationOrigin()}/api/internal/client-purge-sweep`,
      {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-client-purge-sweep-secret': secret,
        },
        body: '{}',
        signal: AbortSignal.timeout(CLIENT_PURGE_SCHEDULED_FUNCTION_TIMEOUT_MS),
      },
    );
    if (!response.ok) {
      throw new Error(`CLIENT_PURGE_SWEEP_HTTP_${response.status}`);
    }
    console.info(
      JSON.stringify({
        event: 'client_purge_sweep_completed',
        status: response.status,
        durationMs: Date.now() - startedAt,
      }),
    );
  } catch (error) {
    console.error(
      JSON.stringify({
        event: 'client_purge_sweep_failed',
        error: error instanceof Error ? error.message : 'UNKNOWN_ERROR',
        durationMs: Date.now() - startedAt,
      }),
    );
    throw error;
  }
}

export const config: Config = {
  schedule: '*/15 * * * *',
};
