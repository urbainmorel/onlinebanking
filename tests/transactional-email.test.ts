import assert from 'node:assert/strict';
import test from 'node:test';

import {
  getTransactionalEmailConfig,
  parseTransactionalEmailLanguage,
  renderTransactionalEmail,
  resolveTransactionalEmailLanguage,
  sendTransactionalEmail,
  type TransactionalEmailJob,
  type TransactionalEmailLanguage,
  type TransactionalEmailTemplate,
} from '../lib/server/transactional-email';

const baseEnvironment: NodeJS.ProcessEnv = {
  NODE_ENV: 'test',
  APP_ORIGIN: 'http://127.0.0.1:3000',
  TRANSACTIONAL_EMAIL_FROM_EMAIL: 'support@monalyz.com',
  TRANSACTIONAL_EMAIL_FROM_NAME: 'Monalyz',
  TRANSACTIONAL_EMAIL_REPLY_TO: 'support@monalyz.com',
};

const branding = {
  wordmarkUrl:
    'https://assets.monalyz.test/brand/monalyz/monalyz-wordmark-email-360.png',
};

const job: TransactionalEmailJob = {
  id: '11111111-2222-4333-8444-555555555555',
  claim_token: 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee',
  recipient_id: '99999999-8888-4777-8666-555555555555',
  recipient_email: 'client@example.com',
  template_key: 'transfer_completed',
  payload: {
    amountMinor: 125050,
    currency: 'EUR',
    recipientName: 'Marie Dupont',
  },
};

test('la configuration métier Resend exige RESEND_API_KEY', () => {
  const config = getTransactionalEmailConfig({
    ...baseEnvironment,
    TRANSACTIONAL_EMAIL_PROVIDER: 'resend',
    RESEND_API_KEY: 're_transactional_secret',
  });

  assert.deepEqual(config, {
    provider: 'resend',
    apiKey: 're_transactional_secret',
    fromEmail: 'support@monalyz.com',
    fromName: 'Monalyz',
    replyTo: 'support@monalyz.com',
    assetBaseUrl: 'http://127.0.0.1:3000',
  });
  assert.throws(
    () =>
      getTransactionalEmailConfig({
        ...baseEnvironment,
        TRANSACTIONAL_EMAIL_PROVIDER: 'resend',
        BREVO_API_KEY: 'xkeysib-not-a-resend-key',
      }),
    /RESEND_API_KEY/,
  );
});

test('la base des assets suit la priorité documentée et exige HTTPS en production', () => {
  const config = getTransactionalEmailConfig({
    ...baseEnvironment,
    NODE_ENV: 'production',
    TRANSACTIONAL_EMAIL_PROVIDER: 'resend',
    RESEND_API_KEY: 're_transactional_secret',
    NEXT_PUBLIC_APP_ORIGIN: 'https://public.monalyz.test',
    APP_ORIGIN: 'https://app.monalyz.test',
    TRANSACTIONAL_EMAIL_ASSET_BASE_URL: 'https://cdn.monalyz.test/emails/',
  });

  assert.equal(config.assetBaseUrl, 'https://cdn.monalyz.test/emails');

  assert.throws(
    () =>
      getTransactionalEmailConfig({
        ...baseEnvironment,
        NODE_ENV: 'production',
        TRANSACTIONAL_EMAIL_PROVIDER: 'resend',
        RESEND_API_KEY: 're_transactional_secret',
      }),
    /doit utiliser HTTPS/,
  );
});

test('la base des assets se replie sur APP_ORIGIN puis NEXT_PUBLIC_APP_ORIGIN', () => {
  const common = {
    ...baseEnvironment,
    TRANSACTIONAL_EMAIL_PROVIDER: 'resend',
    RESEND_API_KEY: 're_transactional_secret',
  };
  const fromAppOrigin = getTransactionalEmailConfig({
    ...common,
    APP_ORIGIN: 'https://app.monalyz.test/',
    NEXT_PUBLIC_APP_ORIGIN: 'https://public.monalyz.test',
  });
  const fromPublicOrigin = getTransactionalEmailConfig({
    ...common,
    APP_ORIGIN: '',
    NEXT_PUBLIC_APP_ORIGIN: 'https://public.monalyz.test/',
  });

  assert.equal(fromAppOrigin.assetBaseUrl, 'https://app.monalyz.test');
  assert.equal(fromPublicOrigin.assetBaseUrl, 'https://public.monalyz.test');
});

test('la configuration métier Brevo utilise BREVO_API_KEY, pas le secret SMTP', () => {
  const config = getTransactionalEmailConfig({
    ...baseEnvironment,
    TRANSACTIONAL_EMAIL_PROVIDER: 'brevo',
    BREVO_API_KEY: 'xkeysib-transactional-secret',
    BREVO_SMTP_LOGIN: 'smtp-user@example.com',
    BREVO_SMTP_KEY: 'xsmtpsib-auth-only',
  });

  assert.equal(config.provider, 'brevo');
  assert.equal(config.apiKey, 'xkeysib-transactional-secret');
  assert.throws(
    () =>
      getTransactionalEmailConfig({
        ...baseEnvironment,
        TRANSACTIONAL_EMAIL_PROVIDER: 'brevo',
        BREVO_SMTP_LOGIN: 'smtp-user@example.com',
        BREVO_SMTP_KEY: 'xsmtpsib-auth-only',
      }),
    /BREVO_API_KEY/,
  );
});

test('les valeurs de secret d’exemple sont refusées', () => {
  assert.throws(
    () =>
      getTransactionalEmailConfig({
        ...baseEnvironment,
        TRANSACTIONAL_EMAIL_PROVIDER: 'resend',
        RESEND_API_KEY: 're_replace_me',
      }),
    /Secret e-mail non configuré : RESEND_API_KEY/,
  );
  assert.throws(
    () =>
      getTransactionalEmailConfig({
        ...baseEnvironment,
        TRANSACTIONAL_EMAIL_PROVIDER: 'brevo',
        BREVO_API_KEY: 'your-brevo-api-key',
      }),
    /Secret e-mail non configuré : BREVO_API_KEY/,
  );
});

const expectedCopy: Record<
  TransactionalEmailTemplate,
  { subject: RegExp; body: RegExp }
> = {
  transfer_submitted: {
    subject: /demande de virement.*reçue/i,
    body: /double validation interne sont nécessaires/i,
  },
  transfer_check_validated: {
    subject: /contrôle de virement.*validé/i,
    body: /contrôle de conformité.*validé.*autorisation finale sont nécessaires.*support@monalyz\.com/i,
  },
  transfer_approved: {
    subject: /demande de virement.*validée/i,
    body: /autorisation finale et a été validé.*service des règlements/i,
  },
  transfer_completed: {
    subject: /virement.*effectué/i,
    body: /exécuté avec succès.*Confirmation de virement/i,
  },
  transfer_rejected: {
    subject: /demande de virement.*refusée/i,
    body: /aucun montant n’a été débité.*frais appliqués aux étapes préalablement engagées/i,
  },
  transfer_failed: {
    subject: /échec.*virement/i,
    body: /montant mis de côté.*de nouveau disponible/i,
  },
  loan_submitted: {
    subject: /demande de prêt.*reçue/i,
    body: /examinons maintenant/i,
  },
  loan_approved: {
    subject: /demande de prêt.*validée/i,
    body: /préparons maintenant le versement des fonds/i,
  },
  loan_disbursed: {
    subject: /prêt.*versé/i,
    body: /versé sur votre compte Monalyz/i,
  },
  loan_rejected: {
    subject: /demande de prêt.*refusée/i,
    body: /aucun fonds.*versé/i,
  },
  loan_failed: {
    subject: /versement.*n’a pas abouti/i,
    body: /fonds liés.*n’ont pas pu être versés/i,
  },
  kyc_submitted: {
    subject: /dossier d’identité.*reçu/i,
    body: /contrôle humain/i,
  },
  kyc_information_requested: {
    subject: /action requise/i,
    body: /uniquement les éléments demandés/i,
  },
  kyc_resubmitted: {
    subject: /dossier d’identité.*resoumis/i,
    body: /corrections.*reçues/i,
  },
  kyc_approved: {
    subject: /identité.*approuvée/i,
    body: /compte interne Monalyz.*créé/i,
  },
  kyc_rejected: {
    subject: /dossier d’identité.*rejeté/i,
    body: /même dossier/i,
  },
};

for (const [template, expected] of Object.entries(expectedCopy) as Array<
  [TransactionalEmailTemplate, (typeof expectedCopy)[TransactionalEmailTemplate]]
>) {
  test(`le modèle ${template} rend un objet complet et cohérent`, () => {
    const rendered = renderTransactionalEmail(
      template,
      {
        amountMinor: 125050,
        currency: 'EUR',
        recipientName: 'Marie Dupont',
        reference: 'MONALYZ-LOAN-123',
        checkKind: 'compliance',
      },
      branding,
    );

    assert.match(rendered.subject, expected.subject);
    assert.match(rendered.text, expected.body);
    assert.match(rendered.html, expected.body);
    assert.match(rendered.text, /support@monalyz\.com/);
    assert.match(rendered.html, /support@monalyz\.com/);
    assert.match(rendered.html, /width="180"/);
    assert.match(rendered.html, /alt="Monalyz"/);
    assert.match(rendered.html, new RegExp(escapeRegExp(branding.wordmarkUrl)));
  });
}

const languages: TransactionalEmailLanguage[] = ['fr', 'en', 'de', 'es', 'it', 'nl'];
const localizedMarkers: Record<
  TransactionalEmailLanguage,
  { subject: RegExp; footer: RegExp }
> = {
  fr: { subject: /votre|échec|le décaissement/i, footer: /Besoin d’aide/i },
  en: { subject: /your/i, footer: /Need help/i },
  de: { subject: /Ihr|Ihre|Die Auszahlung/i, footer: /Brauchen Sie Hilfe/i },
  es: { subject: /su|hemos|el desembolso/i, footer: /Necesita ayuda/i },
  it: { subject: /Sua|Suo|prestito|bonifico|identità/i, footer: /Ha bisogno di assistenza/i },
  nl: { subject: /Uw|lening|identiteit|overboeking/i, footer: /Heeft u hulp nodig/i },
};

for (const language of languages) {
  for (const template of Object.keys(expectedCopy) as TransactionalEmailTemplate[]) {
    test(`le modèle ${template} est intégralement rendu en ${language}`, () => {
      const rendered = renderTransactionalEmail(
        template,
        {
          amountMinor: 125050,
          currency: 'EUR',
          recipientName: 'Marie Dupont',
          reference: 'MONALYZ-LOAN-123',
          checkKind: 'compliance',
        },
        branding,
        language,
      );

      assert.match(rendered.subject, localizedMarkers[language].subject);
      assert.match(rendered.html, new RegExp(`<html lang="${language}">`));
      assert.match(rendered.html, localizedMarkers[language].footer);
      assert.match(rendered.text, /support@monalyz\.com/);
    });
  }
}

const internalWording =
  /chef d’agence|hors de Monalyz|réservation interne|position courante|décaissement en interne|branch manager|outside Monalyz|internal hold|current position|internally|Filialleitung|außerhalb von Monalyz|interne Reservierung|Monalyz-Position|jefe de sucursal|fuera de Monalyz|retención interna|posición corriente/i;

for (const language of languages) {
  test(`les modèles ${language} restent compréhensibles sans vocabulaire interne`, () => {
    for (const template of Object.keys(expectedCopy) as TransactionalEmailTemplate[]) {
      const rendered = renderTransactionalEmail(
        template,
        {
          amountMinor: 125050,
          currency: 'EUR',
          recipientName: 'Marie Dupont',
          reference: 'MONALYZ-LOAN-123',
          checkKind: 'compliance',
        },
        branding,
        language,
      );

      assert.doesNotMatch(rendered.subject, internalWording);
      assert.doesNotMatch(rendered.text, internalWording);
    }
  });
}

for (const language of languages) {
  test(`les montants sont formatés avec la locale ${language}`, () => {
    const rendered = renderTransactionalEmail(
      'transfer_submitted',
      {
        amountMinor: 123456789,
        currency: 'EUR',
        recipientName: 'Client',
      },
      branding,
      language,
    );
    const expectedAmount = new Intl.NumberFormat(
      { fr: 'fr-FR', en: 'en-US', de: 'de-DE', es: 'es-ES', it: 'it-IT', nl: 'nl-NL' }[language],
      { style: 'currency', currency: 'EUR' },
    ).format(1234567.89);

    assert.match(rendered.text, new RegExp(escapeRegExp(expectedAmount)));
  });
}

test('le rendu HTML neutralise les valeurs non fiables du payload', () => {
  const rendered = renderTransactionalEmail(
    'transfer_submitted',
    {
      amountMinor: 1000,
      currency: 'EUR',
      recipientName: '<script>alert("xss")</script>',
    },
    branding,
  );

  assert.doesNotMatch(rendered.html, /<script>/);
  assert.match(
    rendered.html,
    /&lt;script&gt;alert\(&quot;xss&quot;\)&lt;\/script&gt;/,
  );
});

test('le rendu exige une URL absolue HTTP(S) pour le wordmark', () => {
  assert.throws(
    () =>
      renderTransactionalEmail(
        'transfer_submitted',
        {},
        { wordmarkUrl: '/brand/monalyz/logo.png' },
      ),
    /URL du wordmark e-mail invalide/,
  );
  assert.throws(
    () =>
      renderTransactionalEmail(
        'transfer_submitted',
        {},
        { wordmarkUrl: 'data:image/png;base64,unsafe' },
      ),
    /URL du wordmark e-mail invalide/,
  );
});

test('Resend reçoit le bon endpoint, le bon payload et une clé d’idempotence', async () => {
  let capturedUrl = '';
  let capturedInit: RequestInit | undefined;
  const fetchMock = (async (
    input: RequestInfo | URL,
    init?: RequestInit,
  ) => {
    capturedUrl = String(input);
    capturedInit = init;
    return Response.json({ id: 'resend-message-id' });
  }) as typeof fetch;

  const providerMessageId = await sendTransactionalEmail(
    job,
    {
      provider: 'resend',
      apiKey: 're_transactional_secret',
      fromEmail: 'support@monalyz.com',
      fromName: 'Monalyz',
      replyTo: 'support@monalyz.com',
      assetBaseUrl: 'https://assets.monalyz.test/email-assets?version=2',
    },
    'fr',
    fetchMock,
  );

  assert.equal(providerMessageId, 'resend-message-id');
  assert.equal(capturedUrl, 'https://api.resend.com/emails');
  assert.equal(capturedInit?.method, 'POST');
  assert.equal(
    new Headers(capturedInit?.headers).get('Authorization'),
    'Bearer re_transactional_secret',
  );
  assert.equal(
    new Headers(capturedInit?.headers).get('Idempotency-Key'),
    `monalyz-${job.id}`,
  );

  const payload = JSON.parse(String(capturedInit?.body)) as Record<
    string,
    unknown
  >;
  assert.equal(payload.from, 'Monalyz <support@monalyz.com>');
  assert.deepEqual(payload.to, ['client@example.com']);
  assert.equal(payload.reply_to, 'support@monalyz.com');
  assert.match(String(payload.subject), /virement.*effectué/i);
  assert.match(
    String(payload.html),
    /https:\/\/assets\.monalyz\.test\/email-assets\/brand\/monalyz\/monalyz-wordmark-email-360\.png\?version=2/,
  );
});

test('Brevo reçoit le bon endpoint, le bon payload et l’en-tête d’idempotence', async () => {
  let capturedUrl = '';
  let capturedInit: RequestInit | undefined;
  const fetchMock = (async (
    input: RequestInfo | URL,
    init?: RequestInit,
  ) => {
    capturedUrl = String(input);
    capturedInit = init;
    return Response.json({ messageId: 'brevo-message-id' });
  }) as typeof fetch;

  const providerMessageId = await sendTransactionalEmail(
    {
      ...job,
      template_key: 'loan_disbursed',
      payload: {
        amountMinor: 500000,
        currency: 'EUR',
        reference: 'MONALYZ-LOAN-123',
      },
    },
    {
      provider: 'brevo',
      apiKey: 'xkeysib-transactional-secret',
      fromEmail: 'support@monalyz.com',
      fromName: 'Monalyz',
      replyTo: 'support@monalyz.com',
      assetBaseUrl: 'https://assets.monalyz.test',
    },
    'fr',
    fetchMock,
  );

  assert.equal(providerMessageId, 'brevo-message-id');
  assert.equal(capturedUrl, 'https://api.brevo.com/v3/smtp/email');
  assert.equal(capturedInit?.method, 'POST');
  assert.equal(
    new Headers(capturedInit?.headers).get('api-key'),
    'xkeysib-transactional-secret',
  );

  const payload = JSON.parse(String(capturedInit?.body)) as {
    sender: { name: string; email: string };
    to: Array<{ email: string }>;
    replyTo: { email: string };
    subject: string;
    headers: Record<string, string>;
  };
  assert.deepEqual(payload.sender, {
    name: 'Monalyz',
    email: 'support@monalyz.com',
  });
  assert.deepEqual(payload.to, [{ email: 'client@example.com' }]);
  assert.equal(payload.replyTo.email, 'support@monalyz.com');
  assert.equal(payload.headers['Idempotency-Key'], `monalyz-${job.id}`);
  assert.match(payload.subject, /prêt.*versé/i);
  assert.match(
    String((payload as Record<string, unknown>).htmlContent),
    /https:\/\/assets\.monalyz\.test\/brand\/monalyz\/monalyz-wordmark-email-360\.png/,
  );
});

test('la préférence linguistique absente utilise le français, et IT/NL sont acceptés', async () => {
  assert.equal(parseTransactionalEmailLanguage(undefined), 'fr');
  assert.equal(parseTransactionalEmailLanguage('it'), 'it');
  assert.equal(parseTransactionalEmailLanguage('nl'), 'nl');
  assert.equal(
    await resolveTransactionalEmailLanguage(async () => ({
      data: null,
      error: null,
    })),
    'fr',
  );
  await assert.rejects(
    () =>
      resolveTransactionalEmailLanguage(async () => ({
        data: { preferred_language: 'pt' },
        error: null,
      })),
    /Préférence linguistique invalide/,
  );
});

test('une panne de lecture du profil est réessayable et bloque l’envoi', async () => {
  let providerCalls = 0;
  const fetchMock = (async () => {
    providerCalls += 1;
    return Response.json({ id: 'unexpected' });
  }) as typeof fetch;

  await assert.rejects(async () => {
    const language = await resolveTransactionalEmailLanguage(async () => ({
      data: null,
      error: { message: 'database temporarily unavailable' },
    }));
    await sendTransactionalEmail(
      job,
      {
        provider: 'resend',
        apiKey: 're_transactional_secret',
        fromEmail: 'support@monalyz.com',
        fromName: 'Monalyz',
        replyTo: 'support@monalyz.com',
        assetBaseUrl: 'https://assets.monalyz.test',
      },
      language,
      fetchMock,
    );
  }, /Lecture de la préférence linguistique impossible/);

  assert.equal(providerCalls, 0);
});

test('la langue du profil est relue juste avant le dispatch', async () => {
  let currentProfileLanguage: TransactionalEmailLanguage = 'fr';
  currentProfileLanguage = 'de';
  const language = await resolveTransactionalEmailLanguage(async () => ({
    data: { preferred_language: currentProfileLanguage },
    error: null,
  }));
  let capturedBody = '';
  const fetchMock = (async (
    _input: RequestInfo | URL,
    init?: RequestInit,
  ) => {
    capturedBody = String(init?.body);
    return Response.json({ id: 'resend-message-id-de' });
  }) as typeof fetch;

  await sendTransactionalEmail(
    { ...job, template_key: 'transfer_completed' },
    {
      provider: 'resend',
      apiKey: 're_transactional_secret',
      fromEmail: 'support@monalyz.com',
      fromName: 'Monalyz',
      replyTo: 'support@monalyz.com',
      assetBaseUrl: 'https://assets.monalyz.test',
    },
    language,
    fetchMock,
  );

  const providerPayload = JSON.parse(capturedBody) as {
    subject: string;
    html: string;
  };
  assert.equal(language, 'de');
  assert.match(providerPayload.subject, /Ihre Überweisung wurde ausgeführt/);
  assert.match(providerPayload.html, /<html lang="de">/);
});

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}
