import { applyBrand } from '@/lib/branding';
import type { Json } from '@/lib/supabase/database.types';
import { jsonObject } from '@/lib/supabase/json';

export type TransactionalEmailProvider = 'resend' | 'brevo';
export type TransactionalEmailLanguage = 'fr' | 'en' | 'de' | 'es' | 'it' | 'nl';

export type TransactionalEmailTemplate =
  | 'transfer_submitted'
  | 'transfer_check_validated'
  | 'transfer_approved'
  | 'transfer_completed'
  | 'transfer_rejected'
  | 'transfer_failed'
  | 'loan_submitted'
  | 'loan_approved'
  | 'loan_disbursed'
  | 'loan_rejected'
  | 'loan_failed'
  | 'kyc_submitted'
  | 'kyc_information_requested'
  | 'kyc_resubmitted'
  | 'kyc_approved'
  | 'kyc_rejected';

export interface TransactionalEmailJob {
  id: string;
  claim_token: string;
  recipient_id: string;
  recipient_email: string;
  template_key: TransactionalEmailTemplate;
  payload: Record<string, unknown>;
}

const TRANSACTIONAL_EMAIL_TEMPLATES = new Set<TransactionalEmailTemplate>([
  'transfer_submitted',
  'transfer_check_validated',
  'transfer_approved',
  'transfer_completed',
  'transfer_rejected',
  'transfer_failed',
  'loan_submitted',
  'loan_approved',
  'loan_disbursed',
  'loan_rejected',
  'loan_failed',
  'kyc_submitted',
  'kyc_information_requested',
  'kyc_resubmitted',
  'kyc_approved',
  'kyc_rejected',
]);

export function parseTransactionalEmailJob(value: {
  id: string;
  claim_token: string | null;
  recipient_id: string;
  recipient_email: string;
  template_key: string;
  payload: Json;
}): TransactionalEmailJob {
  if (!value.claim_token) {
    throw new Error('Le job e-mail réclamé ne contient aucun jeton.');
  }
  if (
    !TRANSACTIONAL_EMAIL_TEMPLATES.has(
      value.template_key as TransactionalEmailTemplate,
    )
  ) {
    throw new Error(`Modèle e-mail inconnu : ${value.template_key}.`);
  }

  return {
    id: value.id,
    claim_token: value.claim_token,
    recipient_id: value.recipient_id,
    recipient_email: value.recipient_email,
    template_key: value.template_key as TransactionalEmailTemplate,
    payload: jsonObject(value.payload),
  };
}

export interface TransactionalEmailConfig {
  provider: TransactionalEmailProvider;
  apiKey: string;
  fromEmail: string;
  fromName: string;
  replyTo: string;
  assetBaseUrl: string;
}

export interface TransactionalEmailBranding {
  bankName?: string;
  wordmarkUrl: string;
}

export interface RenderedEmail {
  subject: string;
  text: string;
  html: string;
}

export interface BrandedEmailDelivery {
  recipientEmail: string;
  idempotencyKey: string;
  email: RenderedEmail;
  bankName: string;
  tags?: string[];
}

type FetchLike = typeof fetch;

const LANGUAGE_LOCALES: Record<TransactionalEmailLanguage, string> = {
  fr: 'fr-FR',
  en: 'en-US',
  de: 'de-DE',
  es: 'es-ES',
  it: 'it-IT',
  nl: 'nl-NL',
};

const SUPPORT_COPY: Record<
  TransactionalEmailLanguage,
  { text: string; html: string }
> = {
  fr: {
    text: 'Support : support@monalyz.com',
    html: 'Besoin d’aide ? Écrivez à support@monalyz.com.',
  },
  en: {
    text: 'Support: support@monalyz.com',
    html: 'Need help? Contact us at support@monalyz.com.',
  },
  de: {
    text: 'Support: support@monalyz.com',
    html: 'Brauchen Sie Hilfe? Schreiben Sie an support@monalyz.com.',
  },
  es: {
    text: 'Soporte: support@monalyz.com',
    html: '¿Necesita ayuda? Escriba a support@monalyz.com.',
  },
  it: {
    text: 'Assistenza: support@monalyz.com',
    html: 'Ha bisogno di assistenza? Scriva a support@monalyz.com.',
  },
  nl: {
    text: 'Ondersteuning: support@monalyz.com',
    html: 'Heeft u hulp nodig? Schrijf naar support@monalyz.com.',
  },
};

export function parseTransactionalEmailLanguage(
  value: unknown,
): TransactionalEmailLanguage {
  if (value === null || value === undefined || value === '') return 'fr';
  if (value === 'fr' || value === 'en' || value === 'de' || value === 'es' || value === 'it' || value === 'nl') {
    return value;
  }
  throw new Error(`Préférence linguistique invalide : ${String(value)}.`);
}

export async function resolveTransactionalEmailLanguage(
  lookup: () => PromiseLike<{
    data: { preferred_language?: unknown } | null;
    error: { message: string } | null;
  }>,
): Promise<TransactionalEmailLanguage> {
  const { data, error } = await lookup();
  if (error) {
    throw new Error(
      `Lecture de la préférence linguistique impossible : ${error.message}`,
    );
  }
  return parseTransactionalEmailLanguage(data?.preferred_language);
}

function requiredValue(
  environment: NodeJS.ProcessEnv,
  key: string,
): string {
  const value = environment[key]?.trim();
  if (!value) throw new Error(`Configuration e-mail manquante : ${key}.`);
  return value;
}

function requiredSecret(
  environment: NodeJS.ProcessEnv,
  key: string,
): string {
  const value = requiredValue(environment, key);
  if (/replace|changeme|your[-_]/i.test(value)) {
    throw new Error(`Secret e-mail non configuré : ${key}.`);
  }
  return value;
}

function assertEmail(value: string, key: string): string {
  if (
    value.length > 254 ||
    !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(value)
  ) {
    throw new Error(`Adresse e-mail invalide : ${key}.`);
  }
  return value;
}

function resolveAssetBaseUrl(environment: NodeJS.ProcessEnv): string {
  const key = environment.TRANSACTIONAL_EMAIL_ASSET_BASE_URL?.trim()
    ? 'TRANSACTIONAL_EMAIL_ASSET_BASE_URL'
    : environment.APP_ORIGIN?.trim()
      ? 'APP_ORIGIN'
      : 'NEXT_PUBLIC_APP_ORIGIN';
  const value = requiredValue(environment, key);
  let url: URL;

  try {
    url = new URL(value);
  } catch {
    throw new Error(`URL d’assets e-mail invalide : ${key}.`);
  }

  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) {
    throw new Error(`URL d’assets e-mail invalide : ${key}.`);
  }
  if (environment.NODE_ENV === 'production' && url.protocol !== 'https:') {
    throw new Error(
      `URL d’assets e-mail non sécurisée en production : ${key} doit utiliser HTTPS.`,
    );
  }

  return url.toString().replace(/\/$/, '');
}

export function getTransactionalEmailConfig(
  environment: NodeJS.ProcessEnv = process.env,
): TransactionalEmailConfig {
  const provider = requiredValue(
    environment,
    'TRANSACTIONAL_EMAIL_PROVIDER',
  ).toLowerCase();

  if (provider !== 'resend' && provider !== 'brevo') {
    throw new Error(
      'TRANSACTIONAL_EMAIL_PROVIDER doit valoir « resend » ou « brevo ».',
    );
  }

  const fromEmail = assertEmail(
    requiredValue(environment, 'TRANSACTIONAL_EMAIL_FROM_EMAIL'),
    'TRANSACTIONAL_EMAIL_FROM_EMAIL',
  );
  const replyTo = assertEmail(
    environment.TRANSACTIONAL_EMAIL_REPLY_TO?.trim() || fromEmail,
    'TRANSACTIONAL_EMAIL_REPLY_TO',
  );
  const fromName =
    environment.TRANSACTIONAL_EMAIL_FROM_NAME?.trim() || 'Monalyz';
  if (
    fromName.length > 100 ||
    /[\r\n\u0000-\u001f\u007f]/.test(fromName)
  ) {
    throw new Error('TRANSACTIONAL_EMAIL_FROM_NAME est invalide.');
  }

  return {
    provider,
    apiKey:
      provider === 'resend'
        ? requiredSecret(environment, 'RESEND_API_KEY')
        : requiredSecret(environment, 'BREVO_API_KEY'),
    fromEmail,
    fromName,
    replyTo,
    assetBaseUrl: resolveAssetBaseUrl(environment),
  };
}

function escapeHtml(value: string): string {
  return value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}

function payloadText(
  payload: Record<string, unknown>,
  key: string,
  fallback: string,
): string {
  const value = payload[key];
  return typeof value === 'string' && value.trim() ? value.trim() : fallback;
}

function formatMinorAmount(
  payload: Record<string, unknown>,
  language: TransactionalEmailLanguage,
): string {
  const amountMinor = payload.amountMinor;
  const currency = payloadText(payload, 'currency', 'EUR').toUpperCase();
  const numericAmount =
    typeof amountMinor === 'number'
      ? amountMinor
      : typeof amountMinor === 'string'
        ? Number(amountMinor)
        : Number.NaN;
  const exponent = ['XOF', 'XAF'].includes(currency) ? 0 : 2;
  const amount = Number.isFinite(numericAmount)
    ? numericAmount / 10 ** exponent
    : 0;

  try {
    return new Intl.NumberFormat(LANGUAGE_LOCALES[language], {
      style: 'currency',
      currency,
    }).format(amount);
  } catch {
    const formattedAmount = new Intl.NumberFormat(LANGUAGE_LOCALES[language], {
      minimumFractionDigits: exponent,
      maximumFractionDigits: exponent,
    }).format(amount);
    return `${formattedAmount} ${currency}`;
  }
}

const DEFAULT_FEES_MINOR: Record<string, Record<string, number>> = {
  dual_review: { EUR: 15000, USD: 15000, CAD: 15000, CHF: 15000, GBP: 15000 },
  escalation: { EUR: 25000, USD: 25000, CAD: 25000, CHF: 25000, GBP: 25000 },
  compliance: { EUR: 35000, USD: 35000, CAD: 35000, CHF: 35000, GBP: 35000 },
  final_authorization: { EUR: 50000, USD: 50000, CAD: 50000, CHF: 50000, GBP: 50000 },
};

function formatRequiredFee(
  payload: Record<string, unknown>,
  language: TransactionalEmailLanguage,
  feeKey: 'dual_review' | 'escalation' | 'compliance' | 'final_authorization',
): string {
  const currency = payloadText(payload, 'currency', 'EUR').toUpperCase();
  let feeMinor = payload.requiredFeeAmountMinor;
  if (typeof feeMinor !== 'number' && typeof feeMinor !== 'string') {
    feeMinor = DEFAULT_FEES_MINOR[feeKey]?.[currency] ?? 15000;
  }
  return formatMinorAmount({ amountMinor: feeMinor, currency }, language);
}

const TRANSFER_CHECK_TITLES: Record<
  TransactionalEmailLanguage,
  Record<string, string>
> = {
  fr: {
    dual_review: 'Double validation interne',
    escalation: 'Escalade hiérarchique',
    compliance: 'Contrôle conformité',
    final_authorization: 'Autorisation finale',
  },
  en: {
    dual_review: 'Dual review',
    escalation: 'Management escalation',
    compliance: 'Compliance check',
    final_authorization: 'Final authorization',
  },
  de: {
    dual_review: 'Doppelte Prüfung',
    escalation: 'Hierarchische Eskalation',
    compliance: 'Compliance-Prüfung',
    final_authorization: 'Endgültige Genehmigung',
  },
  es: {
    dual_review: 'Doble validación interna',
    escalation: 'Escalado jerárquico',
    compliance: 'Control de conformidad',
    final_authorization: 'Autorización final',
  },
  it: {
    dual_review: 'Doppia convalida interna',
    escalation: 'Escalation gerarchica',
    compliance: 'Controllo di conformità',
    final_authorization: 'Autorizzazione finale',
  },
  nl: {
    dual_review: 'Dubbele interne validatie',
    escalation: 'Hiërarchische escalatie',
    compliance: 'Compliancecontrole',
    final_authorization: 'Definitieve autorisatie',
  },
};

function messageForTemplate(
  template: TransactionalEmailTemplate,
  payload: Record<string, unknown>,
  language: TransactionalEmailLanguage,
): { subject: string; heading: string; message: string } {
  const amount = formatMinorAmount(payload, language);
  const recipientFallback: Record<TransactionalEmailLanguage, string> = {
    fr: 'le bénéficiaire indiqué',
    en: 'the specified beneficiary',
    de: 'den angegebenen Begünstigten',
    es: 'el beneficiario indicado',
    it: 'il beneficiario indicato',
    nl: 'de opgegeven begunstigde',
  };
  const referenceFallback: Record<TransactionalEmailLanguage, string> = {
    fr: 'votre dossier',
    en: 'your application',
    de: 'Ihren Antrag',
    es: 'su solicitud',
    it: 'la Sua richiesta',
    nl: 'uw aanvraag',
  };
  const recipientName = payloadText(
    payload,
    'recipientName',
    recipientFallback[language],
  );
  const reference = payloadText(
    payload,
    'reference',
    referenceFallback[language],
  );
  const checkKind = payloadText(payload, 'checkKind', 'compliance');
  const checkTitle =
    TRANSFER_CHECK_TITLES[language][checkKind] ??
    TRANSFER_CHECK_TITLES[language].compliance;

  if (language === 'en') {
    switch (template) {
      case 'transfer_submitted': {
        const fee = formatRequiredFee(payload, language, 'dual_review');
        return {
          subject: 'Your transfer request has been received',
          heading: 'Transfer request recorded',
          message: `We have received your transfer request of ${amount} to ${recipientName}. For the verification process to continue, a fee of ${fee} for internal dual review is required. Please contact support at support@monalyz.com to settle this fee promptly. This internal dual review step is essential to formally authenticate the transfer originator and verify target bank details, preventing routing errors or impersonation attempts.`,
        };
      }
      case 'transfer_check_validated': {
        if (checkKind === 'dual_review') {
          const fee = formatRequiredFee(payload, language, 'escalation');
          return {
            subject: 'Your transfer check has been approved: Dual review',
            heading: 'Dual review approved',
            message: `The internal dual review for your transfer request of ${amount} to ${recipientName} has been successfully completed. For the process to continue, a fee of ${fee} for management escalation is required. Please contact support at support@monalyz.com to settle this fee promptly. Management escalation enables an operational managerial review. This step is indispensable for overseeing sensitive transactions or significant amounts and ensuring financial account security.`,
          };
        }
        if (checkKind === 'escalation') {
          const fee = formatRequiredFee(payload, language, 'compliance');
          return {
            subject: 'Your transfer check has been approved: Management escalation',
            heading: 'Management escalation approved',
            message: `The management escalation for your transfer request of ${amount} to ${recipientName} has been approved. For the process to continue, a fee of ${fee} for the compliance check is required. Please contact support at support@monalyz.com to settle this fee promptly. The compliance check ensures strict adherence to international financial regulations and anti-money laundering and counter-terrorist financing directives (AML/KYC standards).`,
          };
        }
        const fee = formatRequiredFee(payload, language, 'final_authorization');
        return {
          subject: 'Your transfer check has been approved: Compliance check',
          heading: 'Compliance check approved',
          message: `The compliance check regarding your transfer of ${amount} to ${recipientName} has been successfully validated. For the process to continue, a fee of ${fee} for final authorization is required. Please contact support at support@monalyz.com to settle this fee promptly. The final authorization constitutes the decisive ruling of management, certifying that all legal and technical prerequisites are met to order the effective release of funds.`,
        };
      }
      case 'transfer_approved':
        return {
          subject: 'Your transfer request has been approved',
          heading: 'Transfer approved',
          message: `We inform you that your transfer of ${amount} to ${recipientName} has received final authorization and has been successfully validated. The transfer order is immediately sent to our settlement department for bank execution. This execution phase proceeds with the irrevocable issuance of the transaction onto interbank clearing networks to route the funds to the beneficiary's bank.`,
        };
      case 'transfer_completed':
        return {
          subject: 'Your transfer has been completed',
          heading: 'Transfer completed successfully',
          message: `Your transfer of ${amount} to ${recipientName} has been completed successfully. Your official receipt (Transfer Confirmation) is readily available for download from your secure online banking area. This receipt certifies the final settlement of funds and seals the accounting entry in the bank ledger.`,
        };
      case 'transfer_rejected':
        return {
          subject: 'Your transfer request has been rejected',
          heading: 'Transfer rejected',
          message: `We were unable to approve your transfer request of ${amount} to ${recipientName}. No money has been debited from your {bankName} account, with the exception of fees applied to previously completed stages. This interruption occurs when compliance requirements, authentication standards, or regulatory risk thresholds do not allow the secure continuation of the transaction. For any questions, you may contact support at support@monalyz.com.`,
        };
      case 'transfer_failed':
        return {
          subject: 'Your transfer could not be completed',
          heading: 'Transfer not completed',
          message:
            'Your transfer could not be completed. Any money set aside for it is available again in your {bankName} account.',
        };
      case 'loan_submitted':
        return {
          subject: 'Your loan application has been received',
          heading: 'Loan application recorded',
          message: `We have received your application ${reference} for ${amount}. We are reviewing it and will let you know when a decision has been made.`,
        };
      case 'loan_approved':
        return {
          subject: 'Your loan application has been approved',
          heading: 'Loan approved',
          message:
            'Your application has been approved. We are now preparing the payment of your funds.',
        };
      case 'loan_disbursed':
        return {
          subject: 'Your loan has been paid',
          heading: 'Loan paid successfully',
          message: `${amount} has been paid into your {bankName} account.`,
        };
      case 'loan_rejected':
        return {
          subject: 'Your loan application has been rejected',
          heading: 'Loan rejected',
          message: `We were unable to approve your application ${reference}. No funds have been paid.`,
        };
      case 'loan_failed':
        return {
          subject: 'Your loan payment could not be completed',
          heading: 'Loan payment not completed',
          message: `The funds for your application ${reference} could not be paid. Please contact our support team if you need help.`,
        };
      case 'kyc_submitted': return { subject: 'Your identity file has been received', heading: 'Identity file received', message: 'Your file is waiting for human review. No action is required for now.' };
      case 'kyc_information_requested': return { subject: 'Action required on your identity file', heading: 'More information required', message: 'Open your file and correct only the requested items.' };
      case 'kyc_resubmitted': return { subject: 'Your identity file has been resubmitted', heading: 'Corrections received', message: 'We have received your corrections and will review them.' };
      case 'kyc_approved': return { subject: 'Your identity has been approved', heading: 'Identity approved', message: 'Your identity is confirmed and your {bankName} internal account has been created.' };
      case 'kyc_rejected': return { subject: 'Your identity file has been rejected', heading: 'Corrections are possible', message: 'Open the same file to view the structured reason, correct the requested items and resubmit it.' };
    }
  }

  if (language === 'de') {
    switch (template) {
      case 'transfer_submitted': {
        const fee = formatRequiredFee(payload, language, 'dual_review');
        return {
          subject: 'Ihr Überweisungsauftrag ist eingegangen',
          heading: 'Überweisungsauftrag erfasst',
          message: `Wir haben Ihren Überweisungsauftrag über ${amount} an ${recipientName} erhalten. Damit der Prüfprozess fortgesetzt werden kann, ist eine Gebühr von ${fee} für die doppelte interne Prüfung erforderlich. Bitte kontaktieren Sie den Support unter support@monalyz.com, um diese Gebühr zeitnah zu begleichen. Dieser Schritt der doppelten internen Prüfung ist unerlässlich, um den Auftraggeber formell zu authentifizieren und die Zielbankverbindung auf Richtigkeit zu prüfen, um Fehlleitungen oder Täuschungsversuche auszuschließen.`,
        };
      }
      case 'transfer_check_validated': {
        if (checkKind === 'dual_review') {
          const fee = formatRequiredFee(payload, language, 'escalation');
          return {
            subject: 'Ihre Überweisungsprüfung wurde bestätigt: Doppelte Prüfung',
            heading: 'Doppelte Prüfung bestätigt',
            message: `Die doppelte interne Prüfung Ihres Überweisungsauftrags über ${amount} an ${recipientName} wurde erfolgreich abgeschlossen. Damit der Prozess fortgesetzt werden kann, ist eine Gebühr von ${fee} für die hierarchische Eskalation erforderlich. Bitte kontaktieren Sie den Support unter support@monalyz.com, um diese Gebühr zeitnah zu begleichen. Die hierarchische Eskalation ermöglicht eine Prüfung durch die Betriebsleitung. Dieser Schritt ist unverzichtbar, um sensible oder betragsmäßig erhebliche Transaktionen zu überwachen und die finanzielle Sicherheit der Konten zu gewährleisten.`,
          };
        }
        if (checkKind === 'escalation') {
          const fee = formatRequiredFee(payload, language, 'compliance');
          return {
            subject: 'Ihre Überweisungsprüfung wurde bestätigt: Hierarchische Eskalation',
            heading: 'Hierarchische Eskalation bestätigt',
            message: `Die hierarchische Eskalation für Ihren Überweisungsauftrag über ${amount} an ${recipientName} wurde bestätigt. Damit der Prozess fortgesetzt werden kann, ist eine Gebühr von ${fee} für die Compliance-Prüfung erforderlich. Bitte kontaktieren Sie den Support unter support@monalyz.com, um diese Gebühr zeitnah zu begleichen. Die Compliance-Prüfung gewährleistet die strikte Einhaltung internationaler Finanzvorschriften sowie der Richtlinien zur Bekämpfung von Geldwäsche und Terrorismusfinanzierung (AML/KYC-Standards).`,
          };
        }
        const fee = formatRequiredFee(payload, language, 'final_authorization');
        return {
          subject: 'Ihre Überweisungsprüfung wurde bestätigt: Compliance-Prüfung',
          heading: 'Compliance-Prüfung bestätigt',
          message: `Die Compliance-Prüfung bezüglich Ihrer Überweisung über ${amount} an ${recipientName} wurde erfolgreich bestätigt. Damit der Prozess fortgesetzt werden kann, ist eine Gebühr von ${fee} für die endgültige Genehmigung erforderlich. Bitte kontaktieren Sie den Support unter support@monalyz.com, um diese Gebühr zeitnah zu begleichen. Die endgültige Genehmigung stellt die entscheidende Freigabe der Leitung dar und bescheinigt, dass alle rechtlichen und technischen Voraussetzungen erfüllt sind, um die tatsächliche Freigabe der Gelder anzuweisen.`,
        };
      }
      case 'transfer_approved':
        return {
          subject: 'Ihr Überweisungsauftrag wurde genehmigt',
          heading: 'Überweisung genehmigt',
          message: `Wir informieren Sie darüber, dass Ihre Überweisung über ${amount} an ${recipientName} die endgültige Genehmigung erhalten hat und erfolgreich freigegeben wurde. Der Überweisungsauftrag wird unverzüglich an unsere Abwicklungsabteilung zur banktechnischen Ausführung übermittelt. In dieser Ausführungsphase wird die Transaktion unwiderruflich über die Interbanken-Clearingnetzwerke eingeleitet, um die Gelder an die Empfängerbank zu leiten.`,
        };
      case 'transfer_completed':
        return {
          subject: 'Ihre Überweisung wurde ausgeführt',
          heading: 'Überweisung erfolgreich ausgeführt',
          message: `Ihre Überweisung über ${amount} an ${recipientName} wurde erfolgreich ausgeführt. Ihre offizielle Bestätigung (Überweisungsbestätigung) steht bereits in Ihrem gesicherten Kundenbereich zum Download bereit. Dieser Beleg bescheinigt die endgültige Abwicklung der Gelder und besiegelt die buchhalterische Erfassung im Bankjournal.`,
        };
      case 'transfer_rejected':
        return {
          subject: 'Ihr Überweisungsauftrag wurde abgelehnt',
          heading: 'Überweisung abgelehnt',
          message: `Wir konnten Ihren Überweisungsauftrag über ${amount} an ${recipientName} nicht freigeben. Ihrem {bankName}-Konto wurde kein Betrag belastet, mit Ausnahme der Gebühren für die zuvor eingeleiteten Schritte. Dieser Abbruch erfolgt, wenn Compliance-Anforderungen, Authentifizierungsstandards oder regulatorische Risikoschwellen die sichere Fortführung der Operation nicht gestatten. Für Rückfragen erreichen Sie den Support unter support@monalyz.com.`,
        };
      case 'transfer_failed':
        return {
          subject: 'Ihre Überweisung konnte nicht ausgeführt werden',
          heading: 'Überweisung nicht ausgeführt',
          message:
            'Ihre Überweisung konnte nicht ausgeführt werden. Der dafür vorgesehene Betrag ist auf Ihrem {bankName}-Konto wieder verfügbar.',
        };
      case 'loan_submitted':
        return {
          subject: 'Ihr Kreditantrag ist eingegangen',
          heading: 'Kreditantrag erfasst',
          message: `Wir haben Ihren Antrag ${reference} über ${amount} erhalten. Wir prüfen ihn und informieren Sie, sobald eine Entscheidung getroffen wurde.`,
        };
      case 'loan_approved':
        return {
          subject: 'Ihr Kreditantrag wurde genehmigt',
          heading: 'Kredit genehmigt',
          message:
            'Ihr Antrag wurde genehmigt. Wir bereiten jetzt die Auszahlung vor.',
        };
      case 'loan_disbursed':
        return {
          subject: 'Ihr Kredit wurde ausgezahlt',
          heading: 'Kredit erfolgreich ausgezahlt',
          message: `${amount} wurden Ihrem {bankName}-Konto gutgeschrieben.`,
        };
      case 'loan_rejected':
        return {
          subject: 'Ihr Kreditantrag wurde abgelehnt',
          heading: 'Kredit abgelehnt',
          message: `Wir konnten Ihren Antrag ${reference} nicht genehmigen. Es wurden keine Gelder ausgezahlt.`,
        };
      case 'loan_failed':
        return {
          subject: 'Die Auszahlung Ihres Kredits ist fehlgeschlagen',
          heading: 'Kredit nicht ausgezahlt',
          message: `Die Gelder für Ihren Antrag ${reference} konnten nicht ausgezahlt werden. Bitte wenden Sie sich an unseren Support, wenn Sie Hilfe benötigen.`,
        };
      case 'kyc_submitted': return { subject: 'Ihre Identitätsunterlagen sind eingegangen', heading: 'Unterlagen erhalten', message: 'Ihre Unterlagen warten auf die manuelle Prüfung. Derzeit ist keine Aktion erforderlich.' };
      case 'kyc_information_requested': return { subject: 'Aktion für Ihre Identitätsprüfung erforderlich', heading: 'Ergänzung erforderlich', message: 'Öffnen Sie Ihre Unterlagen und korrigieren Sie nur die angeforderten Elemente.' };
      case 'kyc_resubmitted': return { subject: 'Ihre Identitätsunterlagen wurden erneut eingereicht', heading: 'Korrekturen erhalten', message: 'Wir haben Ihre Korrekturen erhalten und prüfen sie.' };
      case 'kyc_approved': return { subject: 'Ihre Identität wurde bestätigt', heading: 'Identität bestätigt', message: 'Ihre Identität wurde bestätigt und Ihr internes {bankName}-Konto wurde erstellt.' };
      case 'kyc_rejected': return { subject: 'Ihre Identitätsunterlagen wurden abgelehnt', heading: 'Korrekturen sind möglich', message: 'Öffnen Sie denselben Vorgang, prüfen Sie den strukturierten Grund und reichen Sie die angeforderten Korrekturen ein.' };
    }
  }

  if (language === 'es') {
    switch (template) {
      case 'transfer_submitted': {
        const fee = formatRequiredFee(payload, language, 'dual_review');
        return {
          subject: 'Hemos recibido su solicitud de transferencia',
          heading: 'Solicitud de transferencia registrada',
          message: `Hemos recibido su solicitud de transferencia de ${amount} para ${recipientName}. Para que el proceso de verificación pueda continuar, se requiere una comisión de ${fee} para la doble validación interna. Póngase en contacto con el soporte en support@monalyz.com para abonar esta comisión a la brevedad. Esta etapa de doble validación interna es esencial para autenticar formalmente al emisor de la orden y verificar la exactitud de los datos bancarios de destino, evitando cualquier error de enrutamiento o intento de suplantación.`,
        };
      }
      case 'transfer_check_validated': {
        if (checkKind === 'dual_review') {
          const fee = formatRequiredFee(payload, language, 'escalation');
          return {
            subject: 'Su control de transferencia ha sido validado: Doble validación interna',
            heading: 'Doble validación interna validada',
            message: `La doble validación interna de su solicitud de transferencia de ${amount} para ${recipientName} se ha realizado con éxito. Para que el proceso pueda continuar, se requiere una comisión de ${fee} para el escalado jerárquico. Póngase en contacto con el soporte en support@monalyz.com para abonar esta comisión a la brevedad. El escalado jerárquico permite una revisión gerencial por la dirección de operaciones. Esta etapa es indispensable para supervisar transacciones sensibles o de montos significativos y garantizar la seguridad financiera de las cuentas.`,
          };
        }
        if (checkKind === 'escalation') {
          const fee = formatRequiredFee(payload, language, 'compliance');
          return {
            subject: 'Su control de transferencia ha sido validado: Escalado jerárquico',
            heading: 'Escalado jerárquico validado',
            message: `El escalado jerárquico para su solicitud de transferencia de ${amount} para ${recipientName} ha sido validado. Para que el proceso pueda continuar, se requiere una comisión de ${fee} para el control de conformidad. Póngase en contacto con el soporte en support@monalyz.com para abonar esta comisión a la brevedad. El control de conformidad garantiza el cumplimiento estricto de las regulaciones financieras internacionales y las directivas contra el blanqueo de capitales y financiación del terrorismo (normas AML/KYC).`,
          };
        }
        const fee = formatRequiredFee(payload, language, 'final_authorization');
        return {
          subject: 'Su control de transferencia ha sido validado: Control de conformidad',
          heading: 'Control de conformidad validado',
          message: `El control de conformidad relativo a su transferencia de ${amount} para ${recipientName} ha sido validado con éxito. Para que el proceso pueda continuar, se requiere una comisión de ${fee} para la autorización final. Póngase en contacto con el soporte en support@monalyz.com para abonar esta comisión a la brevedad. La autorización final constituye el arbitraje decisivo de la dirección, certificando que se cumplen todos los requisitos legales y técnicos para ordenar el desembolso efectivo de los fondos.`,
        };
      }
      case 'transfer_approved':
        return {
          subject: 'Su solicitud de transferencia ha sido aprobada',
          heading: 'Transferencia aprobada',
          message: `Le informamos de que su transferencia de ${amount} para ${recipientName} ha recibido la autorización final y ha sido validada con éxito. La orden de transferencia se remite inmediatamente a nuestro departamento de liquidaciones para su ejecución bancaria. Esta fase de ejecución procede a la emisión irrevocable de la transacción en las redes de compensación interbancarias para canalizar los fondos hacia el banco del beneficiario.`,
        };
      case 'transfer_completed':
        return {
          subject: 'Su transferencia se ha realizado',
          heading: 'Transferencia realizada correctamente',
          message: `Su transferencia de ${amount} para ${recipientName} se ha ejecutado con éxito. Su comprobante oficial (Confirmación de transferencia) ya se encuentra disponible para su descarga desde su espacio seguro. Este recibo acredita la liquidación definitiva de los fondos y sella la anotación contable en el registro bancario.`,
        };
      case 'transfer_rejected':
        return {
          subject: 'Su solicitud de transferencia ha sido rechazada',
          heading: 'Transferencia rechazada',
          message: `No hemos podido validar su solicitud de transferencia de ${amount} para ${recipientName}. No se ha adeudado ningún importe de su cuenta {bankName}, a excepción de las comisiones aplicadas a las etapas previamente iniciadas. Esta interrupción ocurre cuando los requisitos de cumplimiento, autenticación o los límites de riesgo regulatorio no permiten continuar de forma segura la operación. Para cualquier consulta, puede ponerse en contacto con el soporte en support@monalyz.com.`,
        };
      case 'transfer_failed':
        return {
          subject: 'No se pudo realizar su transferencia',
          heading: 'Transferencia no realizada',
          message:
            'No se pudo realizar su transferencia. El importe reservado para ella vuelve a estar disponible en su cuenta {bankName}.',
        };
      case 'loan_submitted':
        return {
          subject: 'Hemos recibido su solicitud de préstamo',
          heading: 'Solicitud de préstamo registrada',
          message: `Hemos recibido su solicitud ${reference} por un importe de ${amount}. Ahora la revisaremos y le avisaremos cuando se haya tomado una decisión.`,
        };
      case 'loan_approved':
        return {
          subject: 'Su solicitud de préstamo ha sido aprobada',
          heading: 'Préstamo aprobado',
          message:
            'Su solicitud ha sido aprobada. Ahora estamos preparando el pago de los fondos.',
        };
      case 'loan_disbursed':
        return {
          subject: 'Su préstamo ha sido abonado',
          heading: 'Préstamo abonado correctamente',
          message: `Se han abonado ${amount} en su cuenta {bankName}.`,
        };
      case 'loan_rejected':
        return {
          subject: 'Su solicitud de préstamo ha sido rechazada',
          heading: 'Préstamo rechazado',
          message: `No hemos podido aprobar su solicitud ${reference}. No se ha abonado ningún fondo.`,
        };
      case 'loan_failed':
        return {
          subject: 'No se pudo abonar su préstamo',
          heading: 'Pago del préstamo no realizado',
          message: `No se pudieron abonar los fondos de su solicitud ${reference}. Póngase en contacto con nuestro servicio de asistencia si necesita ayuda.`,
        };
      case 'kyc_submitted': return { subject: 'Hemos recibido su expediente de identidad', heading: 'Expediente recibido', message: 'Su expediente espera una revisión humana. Por ahora no debe hacer nada.' };
      case 'kyc_information_requested': return { subject: 'Acción necesaria en su expediente de identidad', heading: 'Información adicional requerida', message: 'Abra su expediente y corrija únicamente los elementos solicitados.' };
      case 'kyc_resubmitted': return { subject: 'Su expediente de identidad ha sido reenviado', heading: 'Correcciones recibidas', message: 'Hemos recibido sus correcciones y las revisaremos.' };
      case 'kyc_approved': return { subject: 'Su identidad ha sido aprobada', heading: 'Identidad aprobada', message: 'Su identidad está confirmada y se ha creado su cuenta interna {bankName}.' };
      case 'kyc_rejected': return { subject: 'Su expediente de identidad ha sido rechazado', heading: 'Puede corregirlo', message: 'Abra el mismo expediente, consulte el motivo estructurado, corrija los elementos solicitados y vuelva a enviarlo.' };
    }
  }

  if (language === 'it') {
    switch (template) {
      case 'transfer_submitted': {
        const fee = formatRequiredFee(payload, language, 'dual_review');
        return {
          subject: 'La Sua richiesta di bonifico è stata ricevuta',
          heading: 'Richiesta di bonifico registrata',
          message: `Abbiamo ricevuto la Sua richiesta di bonifico di ${amount} verso ${recipientName}. Affinché il processo di verifica possa continuare, è richiesta una commissione di ${fee} per la doppia convalida interna. La invitiamo a contattare il supporto all'indirizzo support@monalyz.com per saldare tale commissione in tempi brevi. Questa fase di doppia convalida interna è essenziale per autenticare formalmente l'ordinante e verificare l'esattezza delle coordinate bancarie del beneficiario, evitando errori di inoltro o tentativi di frode.`,
        };
      }
      case 'transfer_check_validated': {
        if (checkKind === 'dual_review') {
          const fee = formatRequiredFee(payload, language, 'escalation');
          return {
            subject: 'Controllo del bonifico convalidato: Doppia convalida interna',
            heading: 'Doppia convalida interna convalidata',
            message: `La doppia convalida interna della Sua richiesta di bonifico di ${amount} verso ${recipientName} è stata eseguita con successo. Affinché il processo possa continuare, è richiesta una commissione di ${fee} per l'escalation gerarchica. La invitiamo a contattare il supporto all'indirizzo support@monalyz.com per saldare tale commissione in tempi brevi. L'escalation gerarchica consente un riesame gestionale da parte della direzione operativa. Questa fase è indispensabile per supervisionare le transazioni sensibili o di importo rilevante e garantire la sicurezza finanziaria dei conti.`,
          };
        }
        if (checkKind === 'escalation') {
          const fee = formatRequiredFee(payload, language, 'compliance');
          return {
            subject: 'Controllo del bonifico convalidato: Escalation gerarchica',
            heading: 'Escalation gerarchica convalidata',
            message: `L'escalation gerarchica per la Sua richiesta di bonifico di ${amount} verso ${recipientName} è stata convalidata. Affinché il processo possa continuare, è richiesta una commissione di ${fee} per il controllo di conformità. La invitiamo a contattare il supporto all'indirizzo support@monalyz.com per saldare tale commissione in tempi brevi. Il controllo di conformità assicura il rigoroso rispetto delle normative finanziarie internazionali e delle direttive antiriciclaggio e di contrasto al finanziamento del terrorismo (standard AML/KYC).`,
          };
        }
        const fee = formatRequiredFee(payload, language, 'final_authorization');
        return {
          subject: 'Controllo del bonifico convalidato: Controllo di conformità',
          heading: 'Controllo di conformità convalidato',
          message: `Il controllo di conformità relativo al Suo bonifico di ${amount} verso ${recipientName} è stato convalidato con successo. Affinché il processo possa continuare, è richiesta una commissione di ${fee} per l'autorizzazione finale. La invitiamo a contattare il supporto all'indirizzo support@monalyz.com per saldare tale commissione in tempi brevi. L'autorizzazione finale costituisce la determinazione decisiva della direzione, certificando che tutti i prerequisiti legali e tecnici siano soddisfatti per ordinare lo sblocco effettivo dei fondi.`,
        };
      }
      case 'transfer_approved':
        return {
          subject: 'La Sua richiesta di bonifico è stata approvata',
          heading: 'Bonifico approvato',
          message: `La informiamo che il Suo bonifico di ${amount} verso ${recipientName} ha ricevuto l'autorizzazione finale ed è stato convalidato con successo. L'ordine di trasferimento viene immediatamente inoltrato al nostro ufficio regolamenti per l'esecuzione bancaria. Questa fase operativa procede all'emissione irrevocabile della transazione sulle reti di compensazione interbancarie al fine di accreditare i fondi alla banca del beneficiario.`,
        };
      case 'transfer_completed':
        return {
          subject: 'Il Suo bonifico è stato eseguito',
          heading: 'Bonifico eseguito correttamente',
          message: `Il Suo bonifico di ${amount} verso ${recipientName} è stato eseguito con successo. La Sua ricevuta ufficiale (Conferma di bonifico) è già disponibile per il download all'interno della Sua area riservata. Questa ricevuta attesta il regolamento definitivo dei fondi e sancisce la registrazione contabile nel registro bancario.`,
        };
      case 'transfer_rejected':
        return {
          subject: 'La Sua richiesta di bonifico è stata rifiutata',
          heading: 'Bonifico rifiutato',
          message: `Non abbiamo potuto convalidare la Sua richiesta di bonifico di ${amount} verso ${recipientName}. Nessun importo è stato addebitato sul Suo conto {bankName}, ad eccezione delle commissioni applicate alle fasi precedentemente avviate. Tale interruzione si verifica qualora i requisiti di conformità, di autenticazione o le soglie di rischio regolamentari non consentano la prosecuzione in sicurezza dell'operazione. Per qualsiasi informazione, può contattare l'assistenza all'indirizzo support@monalyz.com.`,
        };
      case 'transfer_failed': return { subject: 'Non è stato possibile eseguire il Suo bonifico', heading: 'Bonifico non eseguito', message: 'Non è stato possibile eseguire il Suo bonifico. L’importo riservato è nuovamente disponibile sul Suo conto {bankName}.' };
      case 'loan_submitted': return { subject: 'La Sua richiesta di prestito è stata ricevuta', heading: 'Richiesta di prestito registrata', message: `Abbiamo ricevuto la Sua richiesta ${reference} per ${amount}. La stiamo esaminando e La informeremo non appena sarà stata presa una decisione.` };
      case 'loan_approved': return { subject: 'La Sua richiesta di prestito è stata approvata', heading: 'Prestito approvato', message: 'La Sua richiesta è stata approvata. Stiamo preparando l’erogazione dei fondi.' };
      case 'loan_disbursed': return { subject: 'Il Suo prestito è stato erogato', heading: 'Prestito erogato correttamente', message: `${amount} sono stati accreditati sul Suo conto {bankName}.` };
      case 'loan_rejected': return { subject: 'La Sua richiesta di prestito è stata rifiutata', heading: 'Prestito rifiutato', message: `Non è stato possibile approvare la Sua richiesta ${reference}. Non è stato erogato alcun importo.` };
      case 'loan_failed': return { subject: 'Non è stato possibile erogare il Suo prestito', heading: 'Prestito non erogato', message: `Non è stato possibile erogare i fondi relativi alla Sua richiesta ${reference}. Se ha bisogno di assistenza, contatti il nostro supporto.` };
      case 'kyc_submitted': return { subject: 'La Sua documentazione di identità è stata ricevuta', heading: 'Documentazione di identità ricevuta', message: 'La Sua documentazione è in attesa di verifica da parte di un operatore. Per il momento non è richiesta alcuna azione.' };
      case 'kyc_information_requested': return { subject: 'È richiesta un’azione sulla Sua verifica di identità', heading: 'Sono necessarie ulteriori informazioni', message: 'Apra la Sua pratica e corregga esclusivamente gli elementi richiesti.' };
      case 'kyc_resubmitted': return { subject: 'La Sua documentazione di identità è stata inviata nuovamente', heading: 'Correzioni ricevute', message: 'Abbiamo ricevuto le Sue correzioni e procederemo alla verifica.' };
      case 'kyc_approved': return { subject: 'La Sua identità è stata verificata', heading: 'Identità verificata', message: 'La Sua identità è stata confermata e il Suo conto interno {bankName} è stato creato.' };
      case 'kyc_rejected': return { subject: 'La Sua documentazione di identità è stata rifiutata', heading: 'Può apportare le correzioni', message: 'Apra la stessa pratica, consulti il motivo indicato, corregga gli elementi richiesti e la invii nuovamente.' };
    }
  }

  if (language === 'nl') {
    switch (template) {
      case 'transfer_submitted': {
        const fee = formatRequiredFee(payload, language, 'dual_review');
        return {
          subject: 'Uw overboekingsverzoek is ontvangen',
          heading: 'Overboekingsverzoek geregistreerd',
          message: `Wij hebben uw overboekingsverzoek van ${amount} naar ${recipientName} ontvangen. Om het verificatieproces te kunnen voortzetten, zijn kosten van ${fee} voor de dubbele interne validatie vereist. Neem contact op met de klantenservice via support@monalyz.com om deze kosten op korte termijn te voldoen. Deze stap van dubbele interne validatie is essentieel om de opdrachtgever formeel te authenticeren en de juistheid van de doelbankgegevens te controleren, zodat routeringsfouten of pogingen tot identiteitsfraude worden voorkomen.`,
        };
      }
      case 'transfer_check_validated': {
        if (checkKind === 'dual_review') {
          const fee = formatRequiredFee(payload, language, 'escalation');
          return {
            subject: 'Overboekingscontrole goedgekeurd: Dubbele interne validatie',
            heading: 'Dubbele interne validatie goedgekeurd',
            message: `De dubbele interne validatie van uw overboekingsverzoek van ${amount} naar ${recipientName} is succesvol uitgevoerd. Om het proces te kunnen voortzetten, zijn kosten van ${fee} voor de hiërarchische escalatie vereist. Neem contact op met de klantenservice via support@monalyz.com om deze kosten op korte termijn te voldoen. De hiërarchische escalatie maakt een beoordeling door het operationeel management mogelijk. Deze stap is onmisbaar om gevoelige transacties of aanzienlijke bedragen te overzien en de financiële veiligheid van de rekeningen te waarborgen.`,
          };
        }
        if (checkKind === 'escalation') {
          const fee = formatRequiredFee(payload, language, 'compliance');
          return {
            subject: 'Overboekingscontrole goedgekeurd: Hiërarchische escalatie',
            heading: 'Hiërarchische escalatie goedgekeurd',
            message: `De hiërarchische escalatie voor uw overboekingsverzoek van ${amount} naar ${recipientName} is goedgekeurd. Om het proces te kunnen voortzetten, zijn kosten van ${fee} voor de compliancecontrole vereist. Neem contact op met de klantenservice via support@monalyz.com om deze kosten op korte termijn te voldoen. De compliancecontrole waarborgt de strikte naleving van internationale financiële regelgeving en richtlijnen ter bestrijding van witwassen en terrorismefinanciering (AML/KYC-normen).`,
          };
        }
        const fee = formatRequiredFee(payload, language, 'final_authorization');
        return {
          subject: 'Overboekingscontrole goedgekeurd: Compliancecontrole',
          heading: 'Compliancecontrole goedgekeurd',
          message: `De compliancecontrole betreffende uw overboeking van ${amount} naar ${recipientName} is met succes gevalideerd. Om het proces te kunnen voortzetten, zijn kosten van ${fee} voor de definitieve autorisatie vereist. Neem contact op met de klantenservice via support@monalyz.com om deze kosten op korte termijn te voldoen. De definitieve autorisatie vormt het beslissende oordeel van de directie, waarmee wordt gecertificeerd dat aan alle juridische en technische vereisten is voldaan om de daadwerkelijke vrijgave van de fondsen te gelasten.`,
        };
      }
      case 'transfer_approved':
        return {
          subject: 'Uw overboekingsverzoek is goedgekeurd',
          heading: 'Overboeking goedgekeurd',
          message: `Wij informeren u dat uw overboeking van ${amount} naar ${recipientName} de definitieve autorisatie heeft ontvangen en met succes is gevalideerd. De overboekingsopdracht is direct doorgegeven aan onze afdeling vereffening voor bancaire uitvoering. Deze uitvoeringsfase verzorgt de onherroepelijke uitgifte van de transactie op interbancaire verrekeningsnetwerken om de fondsen naar de bank van de begunstigde te leiden.`,
        };
      case 'transfer_completed':
        return {
          subject: 'Uw overboeking is uitgevoerd',
          heading: 'Overboeking succesvol uitgevoerd',
          message: `Uw overboeking van ${amount} naar ${recipientName} is succesvol uitgevoerd. Uw officiële bewijsstuk (Overboekingsbevestiging) kan al direct worden gedownload in uw beveiligde bankomgeving. Deze ontvangstbevestiging bevestigt de definitieve vereffening van de fondsen en bezegelt de boekhoudkundige registratie in het bankjournaal.`,
        };
      case 'transfer_rejected':
        return {
          subject: 'Uw overboekingsverzoek is afgewezen',
          heading: 'Overboeking afgewezen',
          message: `Wij hebben uw overboekingsverzoek van ${amount} naar ${recipientName} niet kunnen goedkeuren. Er is geen bedrag afgeschreven van uw {bankName}-rekening, met uitzondering van de kosten die van toepassing zijn op de vooraf ingezette stappen. Deze onderbreking vindt plaats wanneer de vereisten op het gebied van naleving, authenticatie of wettelijke risicodrempels een veilige voortzetting van de transactie niet toestaan. Neem voor vragen contact op met support via support@monalyz.com.`,
        };
      case 'transfer_failed': return { subject: 'Uw overboeking kon niet worden uitgevoerd', heading: 'Overboeking niet uitgevoerd', message: 'Uw overboeking kon niet worden uitgevoerd. Het gereserveerde bedrag is weer beschikbaar op uw {bankName}-rekening.' };
      case 'loan_submitted': return { subject: 'Uw leningaanvraag is ontvangen', heading: 'Leningaanvraag geregistreerd', message: `Wij hebben uw aanvraag ${reference} voor ${amount} ontvangen. Wij beoordelen deze en informeren u zodra er een beslissing is genomen.` };
      case 'loan_approved': return { subject: 'Uw leningaanvraag is goedgekeurd', heading: 'Lening goedgekeurd', message: 'Uw aanvraag is goedgekeurd. Wij bereiden de uitbetaling van het bedrag voor.' };
      case 'loan_disbursed': return { subject: 'Uw lening is uitbetaald', heading: 'Lening succesvol uitbetaald', message: `${amount} is bijgeschreven op uw {bankName}-rekening.` };
      case 'loan_rejected': return { subject: 'Uw leningaanvraag is afgewezen', heading: 'Lening afgewezen', message: `Wij konden uw aanvraag ${reference} niet goedkeuren. Er is geen bedrag uitbetaald.` };
      case 'loan_failed': return { subject: 'Uw lening kon niet worden uitbetaald', heading: 'Lening niet uitbetaald', message: `Het bedrag voor uw aanvraag ${reference} kon niet worden uitbetaald. Neem contact op met onze ondersteuning als u hulp nodig hebt.` };
      case 'kyc_submitted': return { subject: 'Uw identiteitsdossier is ontvangen', heading: 'Identiteitsdossier ontvangen', message: 'Uw dossier wacht op beoordeling door een medewerker. U hoeft voorlopig niets te doen.' };
      case 'kyc_information_requested': return { subject: 'Actie vereist voor uw identiteitsdossier', heading: 'Aanvullende informatie vereist', message: 'Open uw dossier en corrigeer uitsluitend de gevraagde onderdelen.' };
      case 'kyc_resubmitted': return { subject: 'Uw identiteitsdossier is opnieuw ingediend', heading: 'Correcties ontvangen', message: 'Wij hebben uw correcties ontvangen en zullen deze beoordelen.' };
      case 'kyc_approved': return { subject: 'Uw identiteit is bevestigd', heading: 'Identiteit bevestigd', message: 'Uw identiteit is bevestigd en uw interne {bankName}-rekening is aangemaakt.' };
      case 'kyc_rejected': return { subject: 'Uw identiteitsdossier is afgewezen', heading: 'U kunt correcties aanbrengen', message: 'Open hetzelfde dossier, bekijk de vermelde reden, corrigeer de gevraagde onderdelen en dien het dossier opnieuw in.' };
    }
  }

  switch (template) {
    case 'transfer_submitted': {
      const fee = formatRequiredFee(payload, language, 'dual_review');
      return {
        subject: 'Votre demande de virement a été reçue',
        heading: 'Demande de virement enregistrée',
        message: `Nous avons reçu votre demande de virement de ${amount} vers ${recipientName}. Pour que le processus de vérification puisse continuer, des frais de ${fee} pour la double validation interne sont nécessaires. Veuillez contacter le support à support@monalyz.com pour régler ces frais dans un bref délai. Cette étape de double validation interne est essentielle pour authentifier formellement l'émetteur de l'ordre et vérifier l'exactitude des coordonnées bancaires cibles, évitant ainsi toute erreur d'acheminement ou tentative d'usurpation.`,
      };
    }
    case 'transfer_check_validated': {
      if (checkKind === 'dual_review') {
        const fee = formatRequiredFee(payload, language, 'escalation');
        return {
          subject: 'Votre contrôle de virement a été validé : Double validation interne',
          heading: 'Double validation interne validée',
          message: `La double validation interne de votre demande de virement de ${amount} vers ${recipientName} a été effectuée avec succès. Pour que le processus puisse continuer, des frais de ${fee} pour l'escalade hiérarchique sont nécessaires. Veuillez contacter le support à support@monalyz.com pour régler ces frais dans un bref délai. L’escalade hiérarchique permet une revue managériale par la direction des opérations. Cette étape est indispensable pour superviser les transactions sensibles ou de montants significatifs et garantir la sécurité financière des comptes.`,
        };
      }
      if (checkKind === 'escalation') {
        const fee = formatRequiredFee(payload, language, 'compliance');
        return {
          subject: 'Votre contrôle de virement a été validé : Escalade hiérarchique',
          heading: 'Escalade hiérarchique validée',
          message: `L'escalade hiérarchique pour votre demande de virement de ${amount} vers ${recipientName} a été validée. Pour que le processus puisse continuer, des frais de ${fee} pour le contrôle conformité sont nécessaires. Veuillez contacter le support à support@monalyz.com pour régler ces frais dans un bref délai. Le contrôle de conformité assure le respect strict des réglementations financières internationales ainsi que des directives de lutte contre le blanchiment de capitaux et le financement du terrorisme (normes AML/KYC).`,
        };
      }
      const fee = formatRequiredFee(payload, language, 'final_authorization');
      return {
        subject: 'Votre contrôle de virement a été validé : Contrôle conformité',
        heading: 'Contrôle conformité validé',
        message: `Le contrôle de conformité concernant votre virement de ${amount} vers ${recipientName} a été validé avec succès. Pour que le processus puisse continuer, des frais de ${fee} pour l'autorisation finale sont nécessaires. Veuillez contacter le support à support@monalyz.com pour régler ces frais dans un bref délai. L’autorisation finale constitue l'arbitrage décisif de la direction de l'établissement, certifiant que l'ensemble des prérequis juridiques et techniques sont remplis pour ordonner le déblocage effectif des fonds.`,
      };
    }
    case 'transfer_approved':
      return {
        subject: 'Votre demande de virement a été validée',
        heading: 'Virement validé',
        message: `Nous vous informons que votre virement de ${amount} vers ${recipientName} a reçu l'autorisation finale et a été validé avec succès. L'ordre de transfert est immédiatement transmis à notre service des règlements pour son exécution bancaire. Cette phase d'exécution procède à l'émission irrévocable de la transaction sur les réseaux de compensation interbancaires afin d'acheminer les fonds vers la banque du bénéficiaire.`,
      };
    case 'transfer_completed':
      return {
        subject: 'Votre virement a été effectué',
        heading: 'Virement effectué avec succès',
        message: `Votre virement de ${amount} vers ${recipientName} a été exécuté avec succès. Votre justificatif officiel (Confirmation de virement) est d'ores et déjà téléchargeable depuis votre espace sécurisé. Ce reçu atteste du règlement définitif des fonds et scelle l'inscription de l'écriture comptable au registre bancaire.`,
      };
    case 'transfer_rejected':
      return {
        subject: 'Votre demande de virement a été refusée',
        heading: 'Virement refusé',
        message: `Nous n’avons pas pu valider votre demande de virement de ${amount} vers ${recipientName}. Aucun montant n’a été débité de votre compte {bankName} à l'exception des frais appliqués aux étapes préalablement engagées. Cette interruption intervient lorsque les exigences de conformité, d'authentification ou les seuils de risque réglementaires ne permettent pas la poursuite sécurisée de l'opération. Pour tout renseignement, vous pouvez joindre le support à support@monalyz.com.`,
      };
    case 'transfer_failed':
      return {
        subject: 'Échec de l’exécution de votre virement',
        heading: 'Virement non exécuté',
        message:
          'Votre virement n’a pas pu être effectué. Le montant mis de côté pour ce virement est de nouveau disponible sur votre compte {bankName}.',
      };
    case 'loan_submitted':
      return {
        subject: 'Votre demande de prêt a été reçue',
        heading: 'Demande de prêt enregistrée',
        message: `Nous avons reçu votre demande ${reference} d’un montant de ${amount}. Nous l’examinons maintenant et vous informerons dès qu’une décision aura été prise.`,
      };
    case 'loan_approved':
      return {
        subject: 'Votre demande de prêt a été validée',
        heading: 'Prêt validé',
        message:
          'Votre demande a été validée. Nous préparons maintenant le versement des fonds.',
      };
    case 'loan_disbursed':
      return {
        subject: 'Votre prêt a été versé',
        heading: 'Prêt versé avec succès',
        message: `Le montant de ${amount} a été versé sur votre compte {bankName}.`,
      };
    case 'loan_rejected':
      return {
        subject: 'Votre demande de prêt a été refusée',
        heading: 'Prêt refusé',
        message: `Nous n’avons pas pu valider votre demande ${reference}. Aucun fonds n’a été versé.`,
      };
    case 'loan_failed':
      return {
        subject: 'Le versement de votre prêt n’a pas abouti',
        heading: 'Versement du prêt non effectué',
        message: `Les fonds liés à votre demande ${reference} n’ont pas pu être versés. Contactez notre assistance si vous avez besoin d’aide.`,
      };
    case 'kyc_submitted': return { subject: 'Votre dossier d’identité a été reçu', heading: 'Dossier d’identité reçu', message: 'Votre dossier attend un contrôle humain. Aucune action n’est requise pour le moment.' };
    case 'kyc_information_requested': return { subject: 'Action requise sur votre dossier d’identité', heading: 'Complément requis', message: 'Ouvrez votre dossier et corrigez uniquement les éléments demandés.' };
    case 'kyc_resubmitted': return { subject: 'Votre dossier d’identité a été resoumis', heading: 'Corrections reçues', message: 'Vos corrections ont bien été reçues et vont être examinées.' };
    case 'kyc_approved': return { subject: 'Votre identité a été approuvée', heading: 'Identité approuvée', message: 'Votre identité est confirmée et votre compte interne {bankName} a été créé.' };
    case 'kyc_rejected': return { subject: 'Votre dossier d’identité a été rejeté', heading: 'Vous pouvez le corriger', message: 'Ouvrez le même dossier, consultez le motif structuré, corrigez les éléments demandés puis resoumettez-le.' };
  }
}

export function renderTransactionalEmail(
  template: TransactionalEmailTemplate,
  payload: Record<string, unknown>,
  branding: TransactionalEmailBranding,
  language: TransactionalEmailLanguage = 'fr',
): RenderedEmail {
  const bankName = branding.bankName?.trim() || 'Monalyz';
  const content = applyBrand(
    messageForTemplate(template, payload, language),
    bankName,
  );
  const support = SUPPORT_COPY[language];
  const safeHeading = escapeHtml(content.heading);
  const safeMessage = escapeHtml(content.message);
  const safeSupport = escapeHtml(support.html);
  let wordmarkUrl: URL;

  try {
    wordmarkUrl = new URL(branding.wordmarkUrl);
  } catch {
    throw new Error('URL du wordmark e-mail invalide.');
  }
  if (!['http:', 'https:'].includes(wordmarkUrl.protocol)) {
    throw new Error('URL du wordmark e-mail invalide.');
  }
  const safeWordmarkUrl = escapeHtml(wordmarkUrl.toString());
  const actionPath = payloadText(payload, 'actionPath', '');
  const actionUrl = actionPath.startsWith('/')
    ? new URL(actionPath, wordmarkUrl.origin).toString()
    : '';
  const actionLabel: Record<TransactionalEmailLanguage, string> = {
    fr: 'Ouvrir mon dossier',
    en: 'Open my file',
    de: 'Unterlagen öffnen',
    es: 'Abrir mi expediente',
    it: 'Aprire la mia pratica',
    nl: 'Mijn dossier openen',
  };
  const actionText = actionUrl ? `\n\n${actionLabel[language]}: ${actionUrl}` : '';
  const actionHtml = actionUrl
    ? `<p style="margin:24px 0 0"><a href="${escapeHtml(actionUrl)}" style="display:inline-block;background:#315cf4;color:#fff;text-decoration:none;font-weight:bold;padding:12px 18px;border-radius:10px">${escapeHtml(actionLabel[language])}</a></p>`
    : '';

  return {
    subject: content.subject,
    text: `${content.heading}\n\n${content.message}${actionText}\n\n${support.text}`,
    html: `<!doctype html>
<html lang="${language}">
  <body style="margin:0;background:#f4f6fa;font-family:Arial,sans-serif;color:#0f172a">
    <div style="max-width:600px;margin:0 auto;padding:32px 16px">
      <div style="background:#FBFAF7;padding:18px 24px;border:1px solid #e8e2eb;border-bottom:0;border-radius:18px 18px 0 0">
        <img src="${safeWordmarkUrl}" width="180" alt="${escapeHtml(bankName)}" style="display:block;width:180px;max-width:100%;height:auto;border:0">
      </div>
      <div style="background:#fff;padding:28px 24px;border:1px solid #e2e8f0;border-radius:0 0 18px 18px">
        <h1 style="font-size:22px;margin:0 0 16px">${safeHeading}</h1>
        <p style="font-size:15px;line-height:1.6;margin:0">${safeMessage}</p>${actionHtml}
        <p style="font-size:12px;color:#64748b;margin:28px 0 0">${safeSupport}</p>
      </div>
    </div>
  </body>
</html>`,
  };
}

async function responseError(response: Response): Promise<string> {
  const body = await response.text();
  return `Le fournisseur e-mail a répondu ${response.status}: ${body.slice(0, 300)}`;
}

function buildEmailWordmarkUrl(assetBaseUrl: string): string {
  const wordmarkUrl = new URL(assetBaseUrl);
  wordmarkUrl.pathname = `${wordmarkUrl.pathname.replace(/\/$/, '')}/brand/monalyz/monalyz-wordmark-email-360.png`;
  wordmarkUrl.hash = '';
  return wordmarkUrl.toString();
}

export async function sendTransactionalEmail(
  job: TransactionalEmailJob,
  config: TransactionalEmailConfig,
  language: TransactionalEmailLanguage,
  fetchImpl: FetchLike = fetch,
  branding?: TransactionalEmailBranding,
): Promise<string> {
  const resolvedBranding = branding ?? {
    bankName: config.fromName,
    wordmarkUrl: buildEmailWordmarkUrl(config.assetBaseUrl),
  };
  const senderName = resolvedBranding.bankName?.trim() || config.fromName;
  const email = renderTransactionalEmail(
    job.template_key,
    job.payload,
    resolvedBranding,
    language,
  );

  return sendBrandedEmail(
    {
      recipientEmail: job.recipient_email,
      idempotencyKey: `monalyz-${job.id}`,
      email,
      bankName: senderName,
      tags: ['monalyz-transactional'],
    },
    config,
    fetchImpl,
  );
}

export async function sendBrandedEmail(
  delivery: BrandedEmailDelivery,
  config: TransactionalEmailConfig,
  fetchImpl: FetchLike = fetch,
): Promise<string> {
  if (config.provider === 'resend') {
    const response = await fetchImpl('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${config.apiKey}`,
        'Content-Type': 'application/json',
        'Idempotency-Key': delivery.idempotencyKey,
      },
      body: JSON.stringify({
        from: `${delivery.bankName} <${config.fromEmail}>`,
        to: [delivery.recipientEmail],
        subject: delivery.email.subject,
        html: delivery.email.html,
        text: delivery.email.text,
        reply_to: config.replyTo,
      }),
    });
    if (!response.ok) throw new Error(await responseError(response));
    const data = (await response.json()) as { id?: unknown };
    if (typeof data.id !== 'string') {
      throw new Error('Réponse Resend invalide : identifiant absent.');
    }
    return data.id;
  }

  const response = await fetchImpl('https://api.brevo.com/v3/smtp/email', {
    method: 'POST',
    headers: {
      accept: 'application/json',
      'api-key': config.apiKey,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      sender: { name: delivery.bankName, email: config.fromEmail },
      to: [{ email: delivery.recipientEmail }],
      replyTo: { email: config.replyTo },
      subject: delivery.email.subject,
      htmlContent: delivery.email.html,
      textContent: delivery.email.text,
      headers: { 'Idempotency-Key': delivery.idempotencyKey },
      tags: delivery.tags ?? ['transactional'],
    }),
  });
  if (!response.ok) throw new Error(await responseError(response));
  const data = (await response.json()) as { messageId?: unknown };
  if (typeof data.messageId !== 'string') {
    throw new Error('Réponse Brevo invalide : identifiant absent.');
  }
  return data.messageId;
}
