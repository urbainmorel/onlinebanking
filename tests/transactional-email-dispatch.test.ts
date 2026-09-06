import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import test from 'node:test';

import {
  createTransactionalEmailPrivilegedClient,
  claimTransactionalEmailJobs,
  processTransactionalEmailJobs,
  sendTransactionalEmailWithTimeout,
  TRANSACTIONAL_EMAIL_DISPATCH_CONCURRENCY,
  TRANSACTIONAL_EMAIL_PROVIDER_TIMEOUT_MS,
  TRANSACTIONAL_EMAIL_SCHEDULED_BATCH_SIZE,
} from '../lib/server/transactional-email-dispatch';
import type {
  TransactionalEmailConfig,
  TransactionalEmailJob,
} from '../lib/server/transactional-email';

const config: TransactionalEmailConfig = {
  provider: 'resend',
  apiKey: 're_transactional_secret',
  fromEmail: 'support@monalyz.com',
  fromName: 'Monalyz',
  replyTo: 'support@monalyz.com',
  assetBaseUrl: 'https://app.monalyz.test',
};

const branding = {
  bankName: 'Monalyz',
  wordmarkUrl: 'https://app.monalyz.test/brand/monalyz/wordmark.png',
};

function emailJob(id: string): TransactionalEmailJob {
  return {
    id,
    claim_token: `claim-${id}`,
    recipient_id: `recipient-${id}`,
    recipient_email: `${id}@example.com`,
    template_key: 'transfer_completed',
    payload: { amountMinor: 1000, currency: 'EUR' },
  };
}

function clientWithCompletions(
  completions: Array<Record<string, unknown>>,
  accessStatus = 'active',
) {
  const profileQuery = {
    select() {
      return this;
    },
    eq() {
      return this;
    },
    async maybeSingle() {
      return {
        data: { preferred_language: 'fr', access_status: accessStatus },
        error: null,
      };
    },
  };

  return {
    from(table: string) {
      assert.equal(table, 'profiles');
      return profileQuery;
    },
    async rpc(name: string, args: Record<string, unknown>) {
      assert.equal(name, 'complete_transactional_email');
      completions.push(args);
      return { data: null, error: null };
    },
  };
}

test('le worker Netlify est planifié sans route publique et utilise les runtimes figés', async () => {
  const [
    configuration,
    workflow,
    nextConfiguration,
    packageManifest,
    buildVerification,
    worker,
  ] = await Promise.all([
    readFile(path.join(process.cwd(), 'netlify.toml'), 'utf8'),
    readFile(path.join(process.cwd(), '.github/workflows/ci.yml'), 'utf8'),
    readFile(path.join(process.cwd(), 'next.config.ts'), 'utf8'),
    readFile(path.join(process.cwd(), 'package.json'), 'utf8'),
    readFile(
      path.join(process.cwd(), 'scripts/verify-netlify-build.ts'),
      'utf8',
    ),
    readFile(
      path.join(
        process.cwd(),
        'netlify/functions/transactional-email-worker.ts',
      ),
      'utf8',
    ),
  ]);

  assert.match(configuration, /command = "bun run build:netlify"/);
  assert.match(workflow, /run: bun run build:netlify/);
  const scripts = (JSON.parse(packageManifest) as {
    scripts?: Record<string, string>;
  }).scripts;
  assert.match(
    scripts?.['build:netlify'] ?? '',
    /bun install --frozen-lockfile --cpu=x64 --os=linux && next build && tsx scripts\/verify-netlify-build\.ts/,
  );
  assert.match(buildVerification, /@img\/sharp-linux-x64/);
  assert.match(buildVerification, /@img\/sharp-libvips-linux-x64/);
  assert.match(buildVerification, /\\\.node\$/);
  assert.match(buildVerification, /libvips-cpp\\\.so/);
  assert.match(
    nextConfiguration,
    /sharp-linux-x64\/lib\/\*\*\/\*\.node/,
  );
  assert.match(
    nextConfiguration,
    /sharp-libvips-linux-x64\/lib\/\*\*\/\*\.so\*/,
  );
  assert.match(configuration, /publish = "\.next"/);
  assert.match(configuration, /BUN_VERSION = "1\.3\.14"/);
  assert.match(configuration, /NODE_VERSION = "22"/);
  assert.match(configuration, /directory = "netlify\/functions"/);
  assert.match(configuration, /package = "@netlify\/plugin-nextjs"/);
  assert.match(worker, /schedule: '(?:\*|\*\/5) \* \* \* \*'/);
  assert.match(worker, /Netlify\.env\.get\(key\)/);
  assert.doesNotMatch(worker, /Response\.json\(/);
  assert.doesNotMatch(configuration, /(?:SUPABASE|RESEND|BREVO)_.*=/);
  assert.doesNotMatch(configuration, /^\s*path\s*=/m);
  assert.equal(TRANSACTIONAL_EMAIL_SCHEDULED_BATCH_SIZE, 5);
  assert.equal(TRANSACTIONAL_EMAIL_PROVIDER_TIMEOUT_MS, 3_000);
  assert.equal(TRANSACTIONAL_EMAIL_DISPATCH_CONCURRENCY, 2);
});

test('la route de marque diffère sharp après les contrôles de sécurité', async () => {
  const route = await readFile(
    path.join(process.cwd(), 'app/api/admin/branding/route.ts'),
    'utf8',
  );

  assert.doesNotMatch(route, /import\s*\{[^}]*generateBrandRelease[^}]*\}\s*from/);
  const roleCheck = route.indexOf("role !== 'admin'");
  const sharpImport = route.indexOf(
    "await import('@/lib/server/brand-assets')",
  );
  assert.ok(roleCheck >= 0);
  assert.ok(sharpImport > roleCheck);
  assert.match(route, /brand_asset_pipeline_unavailable/);
  assert.match(route, /temporairement indisponible[\s\S]*503/);
});

test('le claim global et le claim propriétaire utilisent des RPC distinctes', async () => {
  const calls: Array<{ name: string; args: Record<string, unknown> }> = [];
  const client = {
    async rpc(name: string, args: Record<string, unknown>) {
      calls.push({ name, args });
      return { data: [], error: null };
    },
  };

  await claimTransactionalEmailJobs(client as never, { limit: 5 });
  await claimTransactionalEmailJobs(client as never, {
    limit: 5,
    recipientId: 'recipient-id',
  });

  assert.deepEqual(calls, [
    { name: 'claim_transactional_emails', args: { p_limit: 5 } },
    {
      name: 'claim_transactional_emails_for_recipient',
      args: { p_recipient_id: 'recipient-id', p_limit: 5 },
    },
  ]);
});

test('le client global refuse une clé absente ou une valeur d’exemple', () => {
  assert.throws(
    () =>
      createTransactionalEmailPrivilegedClient({
        NEXT_PUBLIC_SUPABASE_URL: 'https://project.supabase.co',
      }),
    /SUPABASE_SECRET_KEY/,
  );
  assert.throws(
    () =>
      createTransactionalEmailPrivilegedClient({
        NEXT_PUBLIC_SUPABASE_URL: 'https://project.supabase.co',
        SUPABASE_SECRET_KEY: 'your-service-key',
      }),
    /SUPABASE_SECRET_KEY/,
  );
});

test('le processeur finalise chaque succès et remet chaque échec en attente', async () => {
  const completions: Array<Record<string, unknown>> = [];
  let providerCalls = 0;
  const fetchMock = (async () => {
    providerCalls += 1;
    return providerCalls === 1
      ? Response.json({ id: 'provider-message-id' })
      : new Response('provider unavailable', { status: 503 });
  }) as typeof fetch;

  const result = await processTransactionalEmailJobs({
    client: clientWithCompletions(completions) as never,
    jobs: [emailJob('first'), emailJob('second')],
    config,
    branding,
    providerTimeoutMs: 100,
    fetchImpl: fetchMock,
  });

  assert.deepEqual(result, { sent: 1, failed: 1, completionFailed: 0 });
  assert.equal(completions.length, 2);
  const succeeded = completions.find((entry) => entry.p_succeeded === true);
  const failed = completions.find((entry) => entry.p_succeeded === false);
  assert.equal(succeeded?.p_provider_message_id, 'provider-message-id');
  assert.match(String(failed?.p_error), /503/);
});

test('un e-mail réclamé avant le gel ne franchit jamais la frontière fournisseur', async () => {
  const completions: Array<Record<string, unknown>> = [];
  let providerCalls = 0;
  const result = await processTransactionalEmailJobs({
    client: clientWithCompletions(completions, 'frozen') as never,
    jobs: [emailJob('frozen')],
    config,
    branding,
    fetchImpl: (async () => {
      providerCalls += 1;
      return Response.json({ id: 'must-not-send' });
    }) as typeof fetch,
  });
  assert.equal(providerCalls, 0);
  assert.deepEqual(result, { sent: 0, failed: 1, completionFailed: 0 });
  assert.equal(completions[0]?.p_succeeded, false);
  assert.match(String(completions[0]?.p_error), /RECIPIENT_PROFILE_NOT_ACTIVE/);
});

test('chaque appel fournisseur est interrompu au délai explicite', async () => {
  const job = emailJob('timeout');
  let signalWasAborted = false;
  const hangingFetch = ((
    _input: RequestInfo | URL,
    init?: RequestInit,
  ) =>
    new Promise<Response>((_resolve, reject) => {
      init?.signal?.addEventListener('abort', () => {
        signalWasAborted = true;
        reject(new DOMException('aborted', 'AbortError'));
      });
    })) as typeof fetch;

  await assert.rejects(
    () =>
      sendTransactionalEmailWithTimeout(job, config, 'fr', branding, {
        timeoutMs: 20,
        fetchImpl: hangingFetch,
      }),
    /Délai fournisseur e-mail dépassé \(20 ms\)/,
  );
  assert.equal(signalWasAborted, true);
});
