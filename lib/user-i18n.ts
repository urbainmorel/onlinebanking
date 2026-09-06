import { bankingMessages } from './banking-i18n';
import { translations } from './i18n';
import { kycTranslations } from './kyc-i18n';
import { publicMessages } from './public-i18n';
import type {
  AppErrorCode,
  Language,
  LedgerEntryKind,
  LoanMotiveCode,
  NotificationMessageKey,
  OfficialDocumentType,
} from './types';

type DeepStringShape<T> = {
  [K in keyof T]: T[K] extends string
    ? string
    : T[K] extends Record<string, unknown>
      ? DeepStringShape<T[K]>
      : never;
};

const fr = {
  common: {
    back: 'Retour',
    next: 'Continuer',
    close: 'Fermer',
    cancel: 'Annuler',
    save: 'Enregistrer',
    saving: 'Enregistrement…',
    submit: 'Transmettre',
    submitting: 'Transmission…',
    loading: 'Chargement…',
    unavailable: 'Non renseigné',
    other: 'Autre',
    or: 'ou',
  },
  shell: {
    greeting: 'Bonjour, {name}',
    greetingFallback: 'Bonjour',
    welcome: 'Bienvenue dans votre espace bancaire sécurisé.',
    homeAria: 'Accueil {bankName}',
    closeMenu: 'Fermer le menu',
    mainNavigation: 'Navigation principale',
    actions: 'Actions',
    userHelp: 'Besoin d’aide ? Notre équipe vous accompagne.',
    adminHelp: 'Support des opérations et de la conformité.',
    contact: 'Nous contacter',
    loadingSession: 'Chargement de votre espace bancaire…',
  },
  settings: {
    eyebrow: 'Préférences', title: 'Paramètres de votre compte {bankName}',
    displayName: 'Nom affiché', phone: 'Téléphone', interfaceLanguage: 'Langue de l’interface',
    preferredCurrency: 'Devise de simulation préférée', hideAmounts: 'Masquer les montants',
    hideAmountsHint: 'Préférence locale de confidentialité visuelle',
    deploymentNotice: 'La configuration du service est définie par le déploiement et ne peut pas être modifiée depuis votre navigateur.',
    saved: 'Vos préférences ont été enregistrées.', languageFailed: 'La langue n’a pas pu être mise à jour.',
  },
  contact: {
    title: 'Assistance {bankName}', subtitle: 'Assistance par e-mail',
    description: 'Pour toute demande, écrivez à notre équipe d’assistance. Votre messagerie s’ouvrira avec l’adresse {bankName} préremplie.',
  },
  support: {
    openChat: 'Contacter le support',
    unavailable: 'Le support est momentanément indisponible',
    pushTitle: 'Notifications du support',
    pushDescription: 'Recevez une notification sécurisée lorsqu’une nouvelle réponse du support est disponible.',
    pushChecking: 'Vérification de la disponibilité des notifications…',
    pushEnable: 'Activer les notifications',
    pushDisable: 'Désactiver',
    pushEnabled: 'Les notifications du support sont activées sur cet appareil.',
    pushDenied: 'Les notifications sont bloquées dans les réglages de votre navigateur.',
    pushUnsupported: 'Les notifications Web Push ne sont pas disponibles sur cet appareil.',
    pushEnabling: 'Activation…',
    pushDisabling: 'Désactivation…',
    pushError: 'Les notifications n’ont pas pu être configurées. Veuillez réessayer.',
  },
  loanModal: {
    subtitle: 'Simulation en temps réel et dépôt de votre dossier',
    stepInformation: 'Informations', stepSimulation: 'Simulation',
    disclaimer: 'Votre demande est enregistrée pour étude. Cette simulation ne constitue ni une offre de crédit, ni une approbation, ni une promesse de versement.',
    errorIntro: 'Veuillez vérifier les informations signalées :',
    identityNotice: 'Votre identité provient de votre session sécurisée. Aucun nom ni aucune adresse e-mail libre ne peut la remplacer.',
    productUnavailable: 'Aucune offre de prêt active n’est disponible dans cette devise.',
    fixedAnnualRate: 'TAEG fixe',
    perMonth: 'par mois', rateHypothesis: 'Hypothèse indicative à {rate}',
  },
  transferModal: {
    subtitle: 'Instruction préparée dans {bankName} — exécution hors application',
    stepRecipient: 'Bénéficiaire', stepDetails: 'Coordonnées externes', stepAmount: 'Montant',
    errorIntro: 'Veuillez vérifier les informations signalées :', required: '{field} est obligatoire.',
    invalidEmail: 'Saisissez une adresse e-mail valide.',
    canadaSelection: 'Renseignez soit l’adresse e-mail Interac, soit les coordonnées de dépôt direct (transit, institution et compte).',
    positiveAmount: 'Le montant doit être supérieur à zéro.', recipientPlaceholder: 'Ex. : Claire Dupont',
    destinationCanada: 'Canada (CAD)', destinationEurozone: 'Zone euro (EUR)', destinationUsa: 'États-Unis (USD)',
    destinationSwiss: 'Suisse (CHF)', destinationUk: 'Royaume-Uni (GBP)', destinationLatam: 'Amérique latine', destinationAfrica: 'Afrique',
    receivingCurrency: 'Devise de réception', accountOrClabe: 'Numéro de compte / CLABE / CPF',
    recipientInstitution: 'Établissement destinataire déclaré', accountOrRib: 'Numéro de compte / RIB',
    accountOrRibPlaceholder: 'Numéro de compte ou RIB', externalBankCode: 'Code externe BIC / SWIFT / établissement',
    transferMotive: 'Motif du virement', motivePlaceholder: 'Ex. : facture 4029',
    externalFees: 'Frais externes', externalFeesUnknown: 'non connus par {bankName}', rateAsOf: 'Taux indicatif au {date}',
    beneficiary: 'Bénéficiaire', motive: 'Motif', saveInstruction: 'Enregistrer l’instruction',
    fields: {
      recipientName: 'Le nom du bénéficiaire', iban: 'L’IBAN', bicSwift: 'Le code BIC / SWIFT',
      routingNumber: 'Le numéro d’acheminement', accountNumber: 'Le numéro de compte', swissIban: 'L’IBAN suisse',
      clearingNumber: 'Le numéro de clearing', sortCode: 'Le sort code', accountOrClabe: 'Le numéro de compte ou CLABE',
      bankName: 'Le nom de la banque', accountOrRib: 'Le numéro de compte ou RIB', bankCode: 'Le code BIC / SWIFT / établissement',
      transitNumber: 'Le numéro de transit', institutionNumber: 'Le numéro d’institution', interacEmail: 'L’adresse e-mail Interac',
    },
  },
  accountTypes: {
    current: 'Compte courant',
    savings: 'Compte d’épargne',
  },
  loanMotives: {
    personal: 'Projet personnel',
    real_estate: 'Projet immobilier',
    vehicle: 'Achat d’un véhicule',
    renovation: 'Travaux et rénovation',
    business_cashflow: 'Trésorerie professionnelle',
    other: 'Autre',
  },
  ledger: {
    migration_opening_balance: 'Solde initial',
    account_opening: 'Ouverture du compte',
    manual_adjustment: 'Ajustement effectué par la banque',
    transfer_debit: 'Virement à {recipient}',
    loan_credit: 'Versement du prêt {reference}',
  },
  notifications: {
    title: 'Notifications',
    subtitle: 'Suivez l’avancement de vos opérations.',
    empty: 'Vous n’avez aucune notification.',
    markAllRead: 'Tout marquer comme lu',
    openItem: 'Ouvrir le dossier',
    markRead: 'Marquer comme lu',
    generic_info: {
      title: 'Information concernant votre espace',
      message: 'Une mise à jour est disponible dans votre espace sécurisé.',
    },
    transfer_submitted: {
      title: 'Virement enregistré',
      message: 'Frais de {fee} pour la double validation interne nécessaires.',
    },
    transfer_approved: {
      title: 'Virement approuvé',
      message: 'Votre virement est approuvé. Exécution en cours.',
    },
    transfer_completed: {
      title: 'Virement exécuté',
      message: 'Virement effectué avec succès.',
    },
    transfer_rejected: {
      title: 'Virement refusé',
      message: 'Virement refusé. Frais engagés non remboursables.',
    },
    transfer_failed: {
      title: 'Virement non exécuté',
      message: 'Votre virement n’a pas pu être exécuté. Consultez son suivi.',
    },
    loan_submitted: {
      title: 'Demande de prêt enregistrée',
      message: 'Votre demande de prêt a été transmise pour analyse.',
    },
    loan_approved: {
      title: 'Prêt approuvé',
      message: 'Votre demande de prêt a été approuvée.',
    },
    loan_disbursed: {
      title: 'Prêt versé',
      message: 'Les fonds de votre prêt ont été crédités sur votre compte.',
    },
    loan_rejected: {
      title: 'Demande de prêt refusée',
      message: 'Votre demande de prêt n’a pas été acceptée.',
    },
    loan_failed: {
      title: 'Versement du prêt interrompu',
      message: 'Le versement de votre prêt n’a pas pu être finalisé. Consultez son suivi.',
    },
    kyc_submitted: {
      title: 'Dossier d’identité transmis',
      message: 'Votre dossier d’identité a été transmis pour vérification.',
    },
    kyc_information_requested: {
      title: 'Informations complémentaires requises',
      message: 'Des éléments complémentaires sont nécessaires pour vérifier votre identité.',
    },
    kyc_resubmitted: {
      title: 'Corrections transmises',
      message: 'Vos corrections ont été transmises pour vérification.',
    },
    kyc_approved: {
      title: 'Identité vérifiée',
      message: 'La vérification de votre identité est terminée.',
    },
    kyc_rejected: {
      title: 'Vérification d’identité non aboutie',
      message: 'Votre dossier d’identité n’a pas pu être validé.',
    },
    document_available: {
      title: 'Nouveau document disponible',
      message: 'Un nouveau document officiel est disponible dans votre espace.',
    },
  },
  documents: {
    bank_details: 'Relevé d’identité bancaire',
    account_statement: 'Relevé de compte',
    balance_certificate: 'Attestation de solde',
    transfer_confirmation: 'Confirmation de virement',
    loan_disbursement_confirmation: 'Confirmation de versement du prêt',
    loan_decision: 'Décision de prêt',
  },
  errors: {
    AUTH_REQUIRED: 'Votre session a expiré. Veuillez vous reconnecter.',
    CONFIGURATION_UNAVAILABLE: 'Le service est temporairement indisponible.',
    INVALID_REQUEST: 'Certaines informations sont invalides. Veuillez les vérifier.',
    NETWORK_ERROR: 'La connexion au service a échoué. Veuillez réessayer.',
    NOT_FOUND: 'L’élément demandé est introuvable.',
    PERMISSION_DENIED: 'Vous n’êtes pas autorisé à effectuer cette opération.',
    SAVE_FAILED: 'L’enregistrement a échoué. Veuillez réessayer.',
    UPLOAD_FAILED: 'Le téléversement a échoué. Veuillez réessayer.',
    UNKNOWN_ERROR: 'Une erreur est survenue. Veuillez réessayer.',
  },
} as const;

type ExtraMessages = DeepStringShape<typeof fr>;

const en: ExtraMessages = {
  common: {
    back: 'Back', next: 'Continue', close: 'Close', cancel: 'Cancel', save: 'Save',
    saving: 'Saving…', submit: 'Submit', submitting: 'Submitting…', loading: 'Loading…',
    unavailable: 'Not provided', other: 'Other', or: 'or',
  },
  shell: {
    greeting: 'Hello, {name}', greetingFallback: 'Hello',
    welcome: 'Welcome to your secure online banking area.', homeAria: '{bankName} home',
    closeMenu: 'Close menu', mainNavigation: 'Main navigation', actions: 'Actions',
    userHelp: 'Need help? Our team is here to assist you.',
    adminHelp: 'Operations and compliance support.', contact: 'Contact us',
    loadingSession: 'Loading your online banking area…',
  },
  settings: {
    eyebrow: 'Preferences', title: 'Your {bankName} account settings', displayName: 'Display name',
    phone: 'Phone number', interfaceLanguage: 'Interface language', preferredCurrency: 'Preferred simulation currency',
    hideAmounts: 'Hide amounts', hideAmountsHint: 'Local visual privacy preference',
    deploymentNotice: 'The service configuration is set by the deployment and cannot be changed from your browser.',
    saved: 'Your preferences have been saved.', languageFailed: 'The language could not be updated.',
  },
  contact: {
    title: '{bankName} support', subtitle: 'Email support',
    description: 'For assistance, email our support team. Your email application will open with the {bankName} address already entered.',
  },
  support: {
    openChat: 'Contact support',
    unavailable: 'Support is temporarily unavailable',
    pushTitle: 'Support notifications',
    pushDescription: 'Receive a secure notification when a new support reply is available.',
    pushChecking: 'Checking notification availability…',
    pushEnable: 'Enable notifications',
    pushDisable: 'Disable',
    pushEnabled: 'Support notifications are enabled on this device.',
    pushDenied: 'Notifications are blocked in your browser settings.',
    pushUnsupported: 'Web Push notifications are not available on this device.',
    pushEnabling: 'Enabling…',
    pushDisabling: 'Disabling…',
    pushError: 'Notifications could not be configured. Please try again.',
  },
  loanModal: {
    subtitle: 'Real-time simulation and application submission', stepInformation: 'Information', stepSimulation: 'Simulation',
    disclaimer: 'Your application has been submitted for review. This simulation is not a credit offer, an approval or a commitment to disburse funds.',
    errorIntro: 'Please review the highlighted information:',
    identityNotice: 'Your identity is taken from your secure session. It cannot be replaced by a freely entered name or email address.',
    productUnavailable: 'No active loan offer is available in this currency.',
    fixedAnnualRate: 'Fixed APR',
    perMonth: 'per month', rateHypothesis: 'Illustrative assumption at {rate}',
  },
  transferModal: {
    subtitle: 'Instruction prepared in {bankName} — execution outside the application', stepRecipient: 'Recipient', stepDetails: 'External details', stepAmount: 'Amount',
    errorIntro: 'Please review the highlighted information:', required: '{field} is required.', invalidEmail: 'Enter a valid email address.',
    canadaSelection: 'Enter either the Interac email address or the direct-deposit details (transit, institution and account).',
    positiveAmount: 'The amount must be greater than zero.', recipientPlaceholder: 'E.g. Claire Dupont',
    destinationCanada: 'Canada (CAD)', destinationEurozone: 'Euro area (EUR)', destinationUsa: 'United States (USD)', destinationSwiss: 'Switzerland (CHF)', destinationUk: 'United Kingdom (GBP)', destinationLatam: 'Latin America', destinationAfrica: 'Africa',
    receivingCurrency: 'Receiving currency', accountOrClabe: 'Account number / CLABE / CPF', recipientInstitution: 'Declared recipient institution',
    accountOrRib: 'Account number / RIB', accountOrRibPlaceholder: 'Account number or RIB', externalBankCode: 'External BIC / SWIFT / institution code',
    transferMotive: 'Transfer purpose', motivePlaceholder: 'E.g. invoice 4029', externalFees: 'External fees', externalFeesUnknown: 'not known by {bankName}',
    rateAsOf: 'Indicative rate as of {date}', beneficiary: 'Recipient', motive: 'Purpose', saveInstruction: 'Save instruction',
    fields: {
      recipientName: 'Recipient name', iban: 'IBAN', bicSwift: 'BIC / SWIFT code', routingNumber: 'Routing number', accountNumber: 'Account number',
      swissIban: 'Swiss IBAN', clearingNumber: 'Clearing number', sortCode: 'Sort code', accountOrClabe: 'Account number or CLABE', bankName: 'Bank name',
      accountOrRib: 'Account number or RIB', bankCode: 'BIC / SWIFT / institution code', transitNumber: 'Transit number', institutionNumber: 'Institution number', interacEmail: 'Interac email address',
    },
  },
  accountTypes: { current: 'Current account', savings: 'Savings account' },
  loanMotives: {
    personal: 'Personal project', real_estate: 'Property project', vehicle: 'Vehicle purchase',
    renovation: 'Renovation work', business_cashflow: 'Business cash flow', other: 'Other',
  },
  ledger: {
    migration_opening_balance: 'Opening balance', account_opening: 'Account opening',
    manual_adjustment: 'Adjustment made by the bank', transfer_debit: 'Transfer to {recipient}',
    loan_credit: 'Loan disbursement {reference}',
  },
  notifications: {
    title: 'Notifications', subtitle: 'Track the progress of your transactions.',
    empty: 'You have no notifications.', markAllRead: 'Mark all as read', openItem: 'Open record', markRead: 'Mark as read',
    generic_info: { title: 'Account information', message: 'An update is available in your secure area.' },
    transfer_submitted: { title: 'Transfer recorded', message: 'A fee of {fee} is required for internal dual review.' },
    transfer_approved: { title: 'Transfer approved', message: 'Your transfer is approved. Execution in progress.' },
    transfer_completed: { title: 'Transfer executed', message: 'Transfer completed successfully.' },
    transfer_rejected: { title: 'Transfer rejected', message: 'Transfer rejected. Incurred fees are non-refundable.' },
    transfer_failed: { title: 'Transfer not completed', message: 'Your transfer could not be completed. Please review its status.' },
    loan_submitted: { title: 'Loan application submitted', message: 'Your loan application has been submitted for review.' },
    loan_approved: { title: 'Loan approved', message: 'Your loan application has been approved.' },
    loan_disbursed: { title: 'Loan disbursed', message: 'Your loan funds have been credited to your account.' },
    loan_rejected: { title: 'Loan application declined', message: 'Your loan application was not approved.' },
    loan_failed: { title: 'Loan disbursement interrupted', message: 'Your loan could not be disbursed. Please review its status.' },
    kyc_submitted: { title: 'Identity file submitted', message: 'Your identity file has been submitted for verification.' },
    kyc_information_requested: { title: 'Additional information required', message: 'Additional items are required to verify your identity.' },
    kyc_resubmitted: { title: 'Corrections submitted', message: 'Your corrections have been submitted for verification.' },
    kyc_approved: { title: 'Identity verified', message: 'Your identity verification is complete.' },
    kyc_rejected: { title: 'Identity verification unsuccessful', message: 'Your identity file could not be approved.' },
    document_available: { title: 'New document available', message: 'A new official document is available in your account.' },
  },
  documents: {
    bank_details: 'Bank account details', account_statement: 'Account statement',
    balance_certificate: 'Balance certificate', transfer_confirmation: 'Transfer confirmation',
    loan_disbursement_confirmation: 'Loan disbursement confirmation', loan_decision: 'Loan decision',
  },
  errors: {
    AUTH_REQUIRED: 'Your session has expired. Please sign in again.',
    CONFIGURATION_UNAVAILABLE: 'The service is temporarily unavailable.',
    INVALID_REQUEST: 'Some information is invalid. Please review it.',
    NETWORK_ERROR: 'The service could not be reached. Please try again.',
    NOT_FOUND: 'The requested item could not be found.',
    PERMISSION_DENIED: 'You are not authorised to perform this action.',
    SAVE_FAILED: 'Your changes could not be saved. Please try again.',
    UPLOAD_FAILED: 'The upload failed. Please try again.',
    UNKNOWN_ERROR: 'Something went wrong. Please try again.',
  },
};

const de: ExtraMessages = {
  common: {
    back: 'Zurück', next: 'Weiter', close: 'Schließen', cancel: 'Abbrechen', save: 'Speichern',
    saving: 'Wird gespeichert…', submit: 'Übermitteln', submitting: 'Wird übermittelt…', loading: 'Wird geladen…',
    unavailable: 'Nicht angegeben', other: 'Sonstiges', or: 'oder',
  },
  shell: {
    greeting: 'Guten Tag, {name}', greetingFallback: 'Guten Tag',
    welcome: 'Willkommen in Ihrem sicheren Online-Banking.', homeAria: '{bankName}-Startseite',
    closeMenu: 'Menü schließen', mainNavigation: 'Hauptnavigation', actions: 'Aktionen',
    userHelp: 'Benötigen Sie Hilfe? Unser Team unterstützt Sie gerne.',
    adminHelp: 'Unterstützung für Betrieb und Compliance.', contact: 'Kontakt',
    loadingSession: 'Ihr Online-Banking wird geladen…',
  },
  settings: {
    eyebrow: 'Einstellungen', title: 'Einstellungen Ihres {bankName}-Kontos', displayName: 'Anzeigename',
    phone: 'Telefonnummer', interfaceLanguage: 'Sprache der Benutzeroberfläche', preferredCurrency: 'Bevorzugte Simulationswährung',
    hideAmounts: 'Beträge ausblenden', hideAmountsHint: 'Lokale Einstellung zum Schutz Ihrer Privatsphäre',
    deploymentNotice: 'Die Dienstkonfiguration wird bei der Bereitstellung festgelegt und kann nicht in Ihrem Browser geändert werden.',
    saved: 'Ihre Einstellungen wurden gespeichert.', languageFailed: 'Die Sprache konnte nicht aktualisiert werden.',
  },
  contact: {
    title: '{bankName}-Support', subtitle: 'Support per E-Mail',
    description: 'Bei Fragen wenden Sie sich per E-Mail an unser Supportteam. Ihr E-Mail-Programm wird mit der bereits eingetragenen {bankName}-Adresse geöffnet.',
  },
  support: {
    openChat: 'Support kontaktieren',
    unavailable: 'Der Support ist vorübergehend nicht verfügbar',
    pushTitle: 'Support-Benachrichtigungen',
    pushDescription: 'Erhalten Sie eine sichere Benachrichtigung, sobald eine neue Support-Antwort verfügbar ist.',
    pushChecking: 'Verfügbarkeit der Benachrichtigungen wird geprüft…',
    pushEnable: 'Benachrichtigungen aktivieren',
    pushDisable: 'Deaktivieren',
    pushEnabled: 'Support-Benachrichtigungen sind auf diesem Gerät aktiviert.',
    pushDenied: 'Benachrichtigungen sind in Ihren Browsereinstellungen blockiert.',
    pushUnsupported: 'Web-Push-Benachrichtigungen sind auf diesem Gerät nicht verfügbar.',
    pushEnabling: 'Wird aktiviert…',
    pushDisabling: 'Wird deaktiviert…',
    pushError: 'Benachrichtigungen konnten nicht eingerichtet werden. Bitte versuchen Sie es erneut.',
  },
  loanModal: {
    subtitle: 'Echtzeitsimulation und Einreichung Ihres Antrags', stepInformation: 'Angaben', stepSimulation: 'Simulation',
    disclaimer: 'Ihr Antrag wurde zur Prüfung eingereicht. Diese Simulation stellt weder ein Kreditangebot noch eine Genehmigung oder Auszahlungszusage dar.',
    errorIntro: 'Bitte prüfen Sie die markierten Angaben:',
    identityNotice: 'Ihre Identität wird aus Ihrer sicheren Sitzung übernommen. Sie kann nicht durch einen frei eingegebenen Namen oder eine E-Mail-Adresse ersetzt werden.',
    productUnavailable: 'In dieser Währung ist derzeit kein aktives Kreditangebot verfügbar.',
    fixedAnnualRate: 'Eff. Jahreszins',
    perMonth: 'pro Monat', rateHypothesis: 'Unverbindliche Annahme mit {rate}',
  },
  transferModal: {
    subtitle: 'In {bankName} vorbereiteter Auftrag — Ausführung außerhalb der Anwendung', stepRecipient: 'Empfänger', stepDetails: 'Externe Bankdaten', stepAmount: 'Betrag',
    errorIntro: 'Bitte prüfen Sie die markierten Angaben:', required: '{field} ist erforderlich.', invalidEmail: 'Geben Sie eine gültige E-Mail-Adresse ein.',
    canadaSelection: 'Geben Sie entweder die Interac-E-Mail-Adresse oder die Daten für die Direktgutschrift (Transit, Institut und Konto) ein.',
    positiveAmount: 'Der Betrag muss größer als null sein.', recipientPlaceholder: 'Z. B. Claire Dupont',
    destinationCanada: 'Kanada (CAD)', destinationEurozone: 'Euro-Raum (EUR)', destinationUsa: 'Vereinigte Staaten (USD)', destinationSwiss: 'Schweiz (CHF)', destinationUk: 'Vereinigtes Königreich (GBP)', destinationLatam: 'Lateinamerika', destinationAfrica: 'Afrika',
    receivingCurrency: 'Empfangswährung', accountOrClabe: 'Kontonummer / CLABE / CPF', recipientInstitution: 'Angegebenes Empfängerinstitut',
    accountOrRib: 'Kontonummer / RIB', accountOrRibPlaceholder: 'Kontonummer oder RIB', externalBankCode: 'Externer BIC-/SWIFT-/Institutscode',
    transferMotive: 'Verwendungszweck', motivePlaceholder: 'Z. B. Rechnung 4029', externalFees: 'Externe Gebühren', externalFeesUnknown: '{bankName} nicht bekannt',
    rateAsOf: 'Unverbindlicher Kurs vom {date}', beneficiary: 'Empfänger', motive: 'Verwendungszweck', saveInstruction: 'Auftrag speichern',
    fields: {
      recipientName: 'Name des Empfängers', iban: 'IBAN', bicSwift: 'BIC-/SWIFT-Code', routingNumber: 'Routing-Nummer', accountNumber: 'Kontonummer',
      swissIban: 'Schweizer IBAN', clearingNumber: 'Clearing-Nummer', sortCode: 'Sort Code', accountOrClabe: 'Kontonummer oder CLABE', bankName: 'Name der Bank',
      accountOrRib: 'Kontonummer oder RIB', bankCode: 'BIC-/SWIFT-/Institutscode', transitNumber: 'Transit-Nummer', institutionNumber: 'Institutionsnummer', interacEmail: 'Interac-E-Mail-Adresse',
    },
  },
  accountTypes: { current: 'Girokonto', savings: 'Sparkonto' },
  loanMotives: {
    personal: 'Persönliches Vorhaben', real_estate: 'Immobilienvorhaben', vehicle: 'Fahrzeugkauf',
    renovation: 'Renovierung', business_cashflow: 'Betriebliche Liquidität', other: 'Sonstiges',
  },
  ledger: {
    migration_opening_balance: 'Anfangssaldo', account_opening: 'Kontoeröffnung',
    manual_adjustment: 'Anpassung durch die Bank', transfer_debit: 'Überweisung an {recipient}',
    loan_credit: 'Kreditauszahlung {reference}',
  },
  notifications: {
    title: 'Benachrichtigungen', subtitle: 'Verfolgen Sie den Status Ihrer Vorgänge.',
    empty: 'Sie haben keine Benachrichtigungen.', markAllRead: 'Alle als gelesen markieren', openItem: 'Vorgang öffnen', markRead: 'Als gelesen markieren',
    generic_info: { title: 'Information zu Ihrem Konto', message: 'In Ihrem sicheren Bereich ist eine Aktualisierung verfügbar.' },
    transfer_submitted: { title: 'Überweisung erfasst', message: 'Eine Gebühr von {fee} ist für die doppelte interne Prüfung erforderlich.' },
    transfer_approved: { title: 'Überweisung genehmigt', message: 'Ihre Überweisung ist genehmigt. Ausführung läuft.' },
    transfer_completed: { title: 'Überweisung ausgeführt', message: 'Überweisung erfolgreich ausgeführt.' },
    transfer_rejected: { title: 'Überweisung abgelehnt', message: 'Überweisung abgelehnt. Angefallene Gebühren sind nicht erstattungsfähig.' },
    transfer_failed: { title: 'Überweisung nicht ausgeführt', message: 'Ihre Überweisung konnte nicht ausgeführt werden. Bitte prüfen Sie den Status.' },
    loan_submitted: { title: 'Kreditantrag eingereicht', message: 'Ihr Kreditantrag wurde zur Prüfung eingereicht.' },
    loan_approved: { title: 'Kredit genehmigt', message: 'Ihr Kreditantrag wurde genehmigt.' },
    loan_disbursed: { title: 'Kredit ausgezahlt', message: 'Der Kreditbetrag wurde Ihrem Konto gutgeschrieben.' },
    loan_rejected: { title: 'Kreditantrag abgelehnt', message: 'Ihr Kreditantrag wurde nicht genehmigt.' },
    loan_failed: { title: 'Kreditauszahlung unterbrochen', message: 'Ihr Kredit konnte nicht ausgezahlt werden. Bitte prüfen Sie den Status.' },
    kyc_submitted: { title: 'Identitätsunterlagen eingereicht', message: 'Ihre Identitätsunterlagen wurden zur Prüfung eingereicht.' },
    kyc_information_requested: { title: 'Zusätzliche Angaben erforderlich', message: 'Für die Identitätsprüfung sind weitere Angaben erforderlich.' },
    kyc_resubmitted: { title: 'Korrekturen eingereicht', message: 'Ihre Korrekturen wurden zur Prüfung eingereicht.' },
    kyc_approved: { title: 'Identität bestätigt', message: 'Ihre Identitätsprüfung ist abgeschlossen.' },
    kyc_rejected: { title: 'Identitätsprüfung nicht erfolgreich', message: 'Ihre Identitätsunterlagen konnten nicht genehmigt werden.' },
    document_available: { title: 'Neues Dokument verfügbar', message: 'In Ihrem Konto ist ein neues offizielles Dokument verfügbar.' },
  },
  documents: {
    bank_details: 'Bankverbindung', account_statement: 'Kontoauszug',
    balance_certificate: 'Saldenbestätigung', transfer_confirmation: 'Überweisungsbestätigung',
    loan_disbursement_confirmation: 'Bestätigung der Kreditauszahlung', loan_decision: 'Kreditentscheidung',
  },
  errors: {
    AUTH_REQUIRED: 'Ihre Sitzung ist abgelaufen. Bitte melden Sie sich erneut an.',
    CONFIGURATION_UNAVAILABLE: 'Der Dienst ist vorübergehend nicht verfügbar.',
    INVALID_REQUEST: 'Einige Angaben sind ungültig. Bitte prüfen Sie sie.',
    NETWORK_ERROR: 'Der Dienst konnte nicht erreicht werden. Bitte versuchen Sie es erneut.',
    NOT_FOUND: 'Das angeforderte Element wurde nicht gefunden.',
    PERMISSION_DENIED: 'Sie sind zu dieser Aktion nicht berechtigt.',
    SAVE_FAILED: 'Die Angaben konnten nicht gespeichert werden. Bitte versuchen Sie es erneut.',
    UPLOAD_FAILED: 'Das Hochladen ist fehlgeschlagen. Bitte versuchen Sie es erneut.',
    UNKNOWN_ERROR: 'Ein Fehler ist aufgetreten. Bitte versuchen Sie es erneut.',
  },
};

const es: ExtraMessages = {
  common: {
    back: 'Volver', next: 'Continuar', close: 'Cerrar', cancel: 'Cancelar', save: 'Guardar',
    saving: 'Guardando…', submit: 'Enviar', submitting: 'Enviando…', loading: 'Cargando…',
    unavailable: 'No informado', other: 'Otro', or: 'o',
  },
  shell: {
    greeting: 'Hola, {name}', greetingFallback: 'Hola',
    welcome: 'Le damos la bienvenida a su banca en línea segura.', homeAria: 'Inicio de {bankName}',
    closeMenu: 'Cerrar el menú', mainNavigation: 'Navegación principal', actions: 'Acciones',
    userHelp: '¿Necesita ayuda? Nuestro equipo está a su disposición.',
    adminHelp: 'Asistencia de operaciones y cumplimiento.', contact: 'Contáctenos',
    loadingSession: 'Cargando su banca en línea…',
  },
  settings: {
    eyebrow: 'Preferencias', title: 'Configuración de su cuenta {bankName}', displayName: 'Nombre visible',
    phone: 'Teléfono', interfaceLanguage: 'Idioma de la interfaz', preferredCurrency: 'Moneda de simulación preferida',
    hideAmounts: 'Ocultar importes', hideAmountsHint: 'Preferencia local de privacidad visual',
    deploymentNotice: 'La configuración del servicio se establece durante el despliegue y no puede modificarse desde su navegador.',
    saved: 'Sus preferencias se han guardado.', languageFailed: 'No se pudo actualizar el idioma.',
  },
  contact: {
    title: 'Asistencia de {bankName}', subtitle: 'Asistencia por correo electrónico',
    description: 'Para cualquier consulta, escriba a nuestro equipo de asistencia. Su aplicación de correo se abrirá con la dirección de {bankName} ya indicada.',
  },
  support: {
    openChat: 'Contactar con soporte',
    unavailable: 'El soporte no está disponible temporalmente',
    pushTitle: 'Notificaciones de soporte',
    pushDescription: 'Reciba una notificación segura cuando haya una nueva respuesta de soporte.',
    pushChecking: 'Comprobando la disponibilidad de las notificaciones…',
    pushEnable: 'Activar notificaciones',
    pushDisable: 'Desactivar',
    pushEnabled: 'Las notificaciones de soporte están activadas en este dispositivo.',
    pushDenied: 'Las notificaciones están bloqueadas en la configuración de su navegador.',
    pushUnsupported: 'Las notificaciones Web Push no están disponibles en este dispositivo.',
    pushEnabling: 'Activando…',
    pushDisabling: 'Desactivando…',
    pushError: 'No se pudieron configurar las notificaciones. Inténtelo de nuevo.',
  },
  loanModal: {
    subtitle: 'Simulación en tiempo real y envío de su solicitud', stepInformation: 'Información', stepSimulation: 'Simulación',
    disclaimer: 'Su solicitud se ha enviado para su evaluación. Esta simulación no constituye una oferta de crédito, una aprobación ni un compromiso de desembolso.',
    errorIntro: 'Revise los datos señalados:',
    identityNotice: 'Su identidad procede de su sesión segura. No puede sustituirse por un nombre o una dirección de correo introducidos libremente.',
    productUnavailable: 'No hay ninguna oferta de préstamo activa disponible en esta moneda.',
    fixedAnnualRate: 'TAE fija',
    perMonth: 'al mes', rateHypothesis: 'Hipótesis orientativa al {rate}',
  },
  transferModal: {
    subtitle: 'Orden preparada en {bankName} — ejecución fuera de la aplicación', stepRecipient: 'Beneficiario', stepDetails: 'Datos bancarios externos', stepAmount: 'Importe',
    errorIntro: 'Revise los datos señalados:', required: '{field} es obligatorio.', invalidEmail: 'Introduzca una dirección de correo válida.',
    canadaSelection: 'Indique el correo de Interac o los datos de depósito directo (tránsito, institución y cuenta).',
    positiveAmount: 'El importe debe ser superior a cero.', recipientPlaceholder: 'Ej.: Claire Dupont',
    destinationCanada: 'Canadá (CAD)', destinationEurozone: 'Zona euro (EUR)', destinationUsa: 'Estados Unidos (USD)', destinationSwiss: 'Suiza (CHF)', destinationUk: 'Reino Unido (GBP)', destinationLatam: 'América Latina', destinationAfrica: 'África',
    receivingCurrency: 'Moneda de recepción', accountOrClabe: 'Número de cuenta / CLABE / CPF', recipientInstitution: 'Entidad beneficiaria declarada',
    accountOrRib: 'Número de cuenta / RIB', accountOrRibPlaceholder: 'Número de cuenta o RIB', externalBankCode: 'Código externo BIC / SWIFT / entidad',
    transferMotive: 'Concepto de la transferencia', motivePlaceholder: 'Ej.: factura 4029', externalFees: 'Comisiones externas', externalFeesUnknown: '{bankName} no las conoce',
    rateAsOf: 'Tipo indicativo a fecha de {date}', beneficiary: 'Beneficiario', motive: 'Concepto', saveInstruction: 'Guardar orden',
    fields: {
      recipientName: 'Nombre del beneficiario', iban: 'IBAN', bicSwift: 'Código BIC / SWIFT', routingNumber: 'Número de ruta', accountNumber: 'Número de cuenta',
      swissIban: 'IBAN suizo', clearingNumber: 'Número de clearing', sortCode: 'Sort code', accountOrClabe: 'Número de cuenta o CLABE', bankName: 'Nombre del banco',
      accountOrRib: 'Número de cuenta o RIB', bankCode: 'Código BIC / SWIFT / entidad', transitNumber: 'Número de tránsito', institutionNumber: 'Número de institución', interacEmail: 'Correo de Interac',
    },
  },
  accountTypes: { current: 'Cuenta corriente', savings: 'Cuenta de ahorro' },
  loanMotives: {
    personal: 'Proyecto personal', real_estate: 'Proyecto inmobiliario', vehicle: 'Compra de un vehículo',
    renovation: 'Obras y reformas', business_cashflow: 'Liquidez empresarial', other: 'Otro',
  },
  ledger: {
    migration_opening_balance: 'Saldo inicial', account_opening: 'Apertura de la cuenta',
    manual_adjustment: 'Ajuste realizado por el banco', transfer_debit: 'Transferencia a {recipient}',
    loan_credit: 'Desembolso del préstamo {reference}',
  },
  notifications: {
    title: 'Notificaciones', subtitle: 'Consulte el progreso de sus operaciones.',
    empty: 'No tiene notificaciones.', markAllRead: 'Marcar todo como leído', openItem: 'Abrir expediente', markRead: 'Marcar como leído',
    generic_info: { title: 'Información de su cuenta', message: 'Hay una actualización disponible en su espacio seguro.' },
    transfer_submitted: { title: 'Transferencia registrada', message: 'Se requiere una comisión de {fee} para la doble validación interna.' },
    transfer_approved: { title: 'Transferencia aprobada', message: 'Su transferencia está aprobada. Ejecución en curso.' },
    transfer_completed: { title: 'Transferencia ejecutada', message: 'Transferencia realizada con éxito.' },
    transfer_rejected: { title: 'Transferencia rechazada', message: 'Transferencia rechazada. Los gastos incurridos no son reembolsables.' },
    transfer_failed: { title: 'Transferencia no ejecutada', message: 'No se pudo ejecutar su transferencia. Consulte su estado.' },
    loan_submitted: { title: 'Solicitud de préstamo enviada', message: 'Su solicitud de préstamo se ha enviado para su evaluación.' },
    loan_approved: { title: 'Préstamo aprobado', message: 'Su solicitud de préstamo ha sido aprobada.' },
    loan_disbursed: { title: 'Préstamo desembolsado', message: 'Los fondos de su préstamo se han abonado en su cuenta.' },
    loan_rejected: { title: 'Solicitud de préstamo rechazada', message: 'Su solicitud de préstamo no ha sido aprobada.' },
    loan_failed: { title: 'Desembolso del préstamo interrumpido', message: 'No se pudo desembolsar su préstamo. Consulte su estado.' },
    kyc_submitted: { title: 'Expediente de identidad enviado', message: 'Su expediente de identidad se ha enviado para su verificación.' },
    kyc_information_requested: { title: 'Información adicional requerida', message: 'Se necesitan datos adicionales para verificar su identidad.' },
    kyc_resubmitted: { title: 'Correcciones enviadas', message: 'Sus correcciones se han enviado para su verificación.' },
    kyc_approved: { title: 'Identidad verificada', message: 'La verificación de su identidad ha finalizado.' },
    kyc_rejected: { title: 'Verificación de identidad no completada', message: 'No se pudo aprobar su expediente de identidad.' },
    document_available: { title: 'Nuevo documento disponible', message: 'Hay un nuevo documento oficial disponible en su cuenta.' },
  },
  documents: {
    bank_details: 'Datos bancarios', account_statement: 'Estado de cuenta',
    balance_certificate: 'Certificado de saldo', transfer_confirmation: 'Confirmación de transferencia',
    loan_disbursement_confirmation: 'Confirmación de desembolso del préstamo', loan_decision: 'Decisión de préstamo',
  },
  errors: {
    AUTH_REQUIRED: 'Su sesión ha caducado. Vuelva a iniciar sesión.',
    CONFIGURATION_UNAVAILABLE: 'El servicio no está disponible temporalmente.',
    INVALID_REQUEST: 'Algunos datos no son válidos. Revíselos.',
    NETWORK_ERROR: 'No se pudo conectar con el servicio. Inténtelo de nuevo.',
    NOT_FOUND: 'No se encontró el elemento solicitado.',
    PERMISSION_DENIED: 'No tiene autorización para realizar esta operación.',
    SAVE_FAILED: 'No se pudieron guardar los cambios. Inténtelo de nuevo.',
    UPLOAD_FAILED: 'La carga ha fallado. Inténtelo de nuevo.',
    UNKNOWN_ERROR: 'Se ha producido un error. Inténtelo de nuevo.',
  },
};

const it: ExtraMessages = {
  common: {
    back: 'Indietro', next: 'Continua', close: 'Chiudi', cancel: 'Annulla', save: 'Salva',
    saving: 'Salvataggio…', submit: 'Invia', submitting: 'Invio…', loading: 'Caricamento…',
    unavailable: 'Non indicato', other: 'Altro', or: 'oppure',
  },
  shell: {
    greeting: 'Buongiorno, {name}', greetingFallback: 'Buongiorno',
    welcome: 'Benvenuto nella sua area bancaria protetta.', homeAria: 'Home page {bankName}',
    closeMenu: 'Chiudi il menu', mainNavigation: 'Navigazione principale', actions: 'Azioni',
    userHelp: 'Ha bisogno di aiuto? Il nostro team è a sua disposizione.',
    adminHelp: 'Assistenza per operazioni e conformità.', contact: 'Contattaci',
    loadingSession: 'Caricamento della sua area bancaria…',
  },
  settings: {
    eyebrow: 'Preferenze', title: 'Impostazioni del suo conto {bankName}', displayName: 'Nome visualizzato',
    phone: 'Telefono', interfaceLanguage: 'Lingua dell’interfaccia', preferredCurrency: 'Valuta preferita per le simulazioni',
    hideAmounts: 'Nascondi gli importi', hideAmountsHint: 'Preferenza locale per la riservatezza visiva',
    deploymentNotice: 'La configurazione del servizio è definita durante la distribuzione e non può essere modificata dal browser.',
    saved: 'Le sue preferenze sono state salvate.', languageFailed: 'Non è stato possibile aggiornare la lingua.',
  },
  contact: {
    title: 'Assistenza {bankName}', subtitle: 'Assistenza via e-mail',
    description: 'Per ricevere assistenza, scriva al nostro team. L’applicazione e-mail si aprirà con l’indirizzo {bankName} già compilato.',
  },
  support: {
    openChat: 'Contatta l’assistenza',
    unavailable: 'L’assistenza è temporaneamente indisponibile',
    pushTitle: 'Notifiche dell’assistenza',
    pushDescription: 'Riceva una notifica protetta quando è disponibile una nuova risposta dell’assistenza.',
    pushChecking: 'Verifica della disponibilità delle notifiche…',
    pushEnable: 'Attiva le notifiche',
    pushDisable: 'Disattiva',
    pushEnabled: 'Le notifiche dell’assistenza sono attive su questo dispositivo.',
    pushDenied: 'Le notifiche sono bloccate nelle impostazioni del browser.',
    pushUnsupported: 'Le notifiche Web Push non sono disponibili su questo dispositivo.',
    pushEnabling: 'Attivazione…',
    pushDisabling: 'Disattivazione…',
    pushError: 'Non è stato possibile configurare le notifiche. Riprovi.',
  },
  loanModal: {
    subtitle: 'Simulazione in tempo reale e invio della pratica', stepInformation: 'Informazioni', stepSimulation: 'Simulazione',
    disclaimer: 'La sua richiesta è stata registrata per la valutazione. Questa simulazione non costituisce un’offerta di credito, un’approvazione o un impegno a erogare fondi.',
    errorIntro: 'Verifichi le informazioni evidenziate:',
    identityNotice: 'La sua identità proviene dalla sessione protetta. Non può essere sostituita da un nome o un indirizzo e-mail inserito liberamente.',
    productUnavailable: 'Non è disponibile alcuna offerta di prestito attiva in questa valuta.',
    fixedAnnualRate: 'TAEG fisso',
    perMonth: 'al mese', rateHypothesis: 'Ipotesi indicativa al {rate}',
  },
  transferModal: {
    subtitle: 'Istruzione preparata in {bankName} — esecuzione fuori dall’applicazione', stepRecipient: 'Beneficiario', stepDetails: 'Coordinate esterne', stepAmount: 'Importo',
    errorIntro: 'Verifichi le informazioni evidenziate:', required: '{field} è obbligatorio.', invalidEmail: 'Inserisca un indirizzo e-mail valido.',
    canadaSelection: 'Inserisca l’indirizzo e-mail Interac oppure le coordinate per l’accredito diretto (transit, istituto e conto).',
    positiveAmount: 'L’importo deve essere superiore a zero.', recipientPlaceholder: 'Es. Claire Dupont',
    destinationCanada: 'Canada (CAD)', destinationEurozone: 'Area euro (EUR)', destinationUsa: 'Stati Uniti (USD)', destinationSwiss: 'Svizzera (CHF)', destinationUk: 'Regno Unito (GBP)', destinationLatam: 'America Latina', destinationAfrica: 'Africa',
    receivingCurrency: 'Valuta di ricezione', accountOrClabe: 'Numero di conto / CLABE / CPF', recipientInstitution: 'Istituto destinatario dichiarato',
    accountOrRib: 'Numero di conto / RIB', accountOrRibPlaceholder: 'Numero di conto o RIB', externalBankCode: 'Codice esterno BIC / SWIFT / istituto',
    transferMotive: 'Causale del bonifico', motivePlaceholder: 'Es. fattura 4029', externalFees: 'Commissioni esterne', externalFeesUnknown: 'non note a {bankName}',
    rateAsOf: 'Tasso indicativo al {date}', beneficiary: 'Beneficiario', motive: 'Causale', saveInstruction: 'Salva l’istruzione',
    fields: {
      recipientName: 'Il nome del beneficiario', iban: 'L’IBAN', bicSwift: 'Il codice BIC / SWIFT', routingNumber: 'Il routing number', accountNumber: 'Il numero di conto',
      swissIban: 'L’IBAN svizzero', clearingNumber: 'Il numero di clearing', sortCode: 'Il sort code', accountOrClabe: 'Il numero di conto o CLABE', bankName: 'Il nome della banca',
      accountOrRib: 'Il numero di conto o RIB', bankCode: 'Il codice BIC / SWIFT / istituto', transitNumber: 'Il numero di transito', institutionNumber: 'Il numero dell’istituto', interacEmail: 'L’indirizzo e-mail Interac',
    },
  },
  accountTypes: { current: 'Conto corrente', savings: 'Conto di risparmio' },
  loanMotives: {
    personal: 'Progetto personale', real_estate: 'Progetto immobiliare', vehicle: 'Acquisto di un veicolo',
    renovation: 'Lavori e ristrutturazione', business_cashflow: 'Liquidità aziendale', other: 'Altro',
  },
  ledger: {
    migration_opening_balance: 'Saldo iniziale', account_opening: 'Apertura del conto',
    manual_adjustment: 'Rettifica effettuata dalla banca', transfer_debit: 'Bonifico a {recipient}',
    loan_credit: 'Erogazione del prestito {reference}',
  },
  notifications: {
    title: 'Notifiche', subtitle: 'Segua l’avanzamento delle sue operazioni.',
    empty: 'Non ha notifiche.', markAllRead: 'Segna tutte come lette', openItem: 'Apri la pratica', markRead: 'Segna come letta',
    generic_info: { title: 'Informazioni sulla sua area', message: 'È disponibile un aggiornamento nella sua area protetta.' },
    transfer_submitted: { title: 'Bonifico registrato', message: 'È richiesta una commissione di {fee} per la doppia convalida interna.' },
    transfer_approved: { title: 'Bonifico approvato', message: 'Il Suo bonifico è approvato. Esecuzione in corso.' },
    transfer_completed: { title: 'Bonifico eseguito', message: 'Bonifico eseguito con successo.' },
    transfer_rejected: { title: 'Bonifico rifiutato', message: 'Bonifico rifiutato. Le commissioni sostenute non sono rimborsabili.' },
    transfer_failed: { title: 'Bonifico non eseguito', message: 'Non è stato possibile eseguire il bonifico. Consulti il relativo stato.' },
    loan_submitted: { title: 'Richiesta di prestito registrata', message: 'La sua richiesta di prestito è stata inviata per la valutazione.' },
    loan_approved: { title: 'Prestito approvato', message: 'La sua richiesta di prestito è stata approvata.' },
    loan_disbursed: { title: 'Prestito erogato', message: 'I fondi del prestito sono stati accreditati sul suo conto.' },
    loan_rejected: { title: 'Richiesta di prestito rifiutata', message: 'La sua richiesta di prestito non è stata accettata.' },
    loan_failed: { title: 'Erogazione del prestito interrotta', message: 'Non è stato possibile completare l’erogazione del prestito. Consulti il relativo stato.' },
    kyc_submitted: { title: 'Pratica d’identità inviata', message: 'La sua pratica d’identità è stata inviata per la verifica.' },
    kyc_information_requested: { title: 'Informazioni aggiuntive richieste', message: 'Sono necessari ulteriori elementi per verificare la sua identità.' },
    kyc_resubmitted: { title: 'Correzioni inviate', message: 'Le sue correzioni sono state inviate per la verifica.' },
    kyc_approved: { title: 'Identità verificata', message: 'La verifica della sua identità è terminata.' },
    kyc_rejected: { title: 'Verifica dell’identità non riuscita', message: 'Non è stato possibile approvare la sua pratica d’identità.' },
    document_available: { title: 'Nuovo documento disponibile', message: 'Un nuovo documento ufficiale è disponibile nella sua area.' },
  },
  documents: {
    bank_details: 'Coordinate bancarie', account_statement: 'Estratto conto',
    balance_certificate: 'Attestazione del saldo', transfer_confirmation: 'Conferma del bonifico',
    loan_disbursement_confirmation: 'Conferma dell’erogazione del prestito', loan_decision: 'Decisione sul prestito',
  },
  errors: {
    AUTH_REQUIRED: 'La sua sessione è scaduta. Acceda nuovamente.',
    CONFIGURATION_UNAVAILABLE: 'Il servizio è temporaneamente indisponibile.',
    INVALID_REQUEST: 'Alcune informazioni non sono valide. Le verifichi.',
    NETWORK_ERROR: 'Non è stato possibile raggiungere il servizio. Riprovi.',
    NOT_FOUND: 'L’elemento richiesto non è stato trovato.',
    PERMISSION_DENIED: 'Non è autorizzato a eseguire questa operazione.',
    SAVE_FAILED: 'Non è stato possibile salvare le modifiche. Riprovi.',
    UPLOAD_FAILED: 'Caricamento non riuscito. Riprovi.',
    UNKNOWN_ERROR: 'Si è verificato un errore. Riprovi.',
  },
};

const nl: ExtraMessages = {
  common: {
    back: 'Terug', next: 'Doorgaan', close: 'Sluiten', cancel: 'Annuleren', save: 'Opslaan',
    saving: 'Opslaan…', submit: 'Indienen', submitting: 'Indienen…', loading: 'Laden…',
    unavailable: 'Niet opgegeven', other: 'Overig', or: 'of',
  },
  shell: {
    greeting: 'Goedendag, {name}', greetingFallback: 'Goedendag',
    welcome: 'Welkom in uw beveiligde bankomgeving.', homeAria: 'Startpagina van {bankName}',
    closeMenu: 'Menu sluiten', mainNavigation: 'Hoofdnavigatie', actions: 'Acties',
    userHelp: 'Hulp nodig? Ons team staat voor u klaar.',
    adminHelp: 'Ondersteuning voor transacties en naleving.', contact: 'Contact opnemen',
    loadingSession: 'Uw bankomgeving laden…',
  },
  settings: {
    eyebrow: 'Voorkeuren', title: 'Instellingen van uw {bankName}-rekening', displayName: 'Weergavenaam',
    phone: 'Telefoonnummer', interfaceLanguage: 'Interfacetaal', preferredCurrency: 'Voorkeursvaluta voor berekeningen',
    hideAmounts: 'Bedragen verbergen', hideAmountsHint: 'Lokale voorkeur voor visuele privacy',
    deploymentNotice: 'De serviceconfiguratie wordt tijdens de implementatie ingesteld en kan niet vanuit uw browser worden gewijzigd.',
    saved: 'Uw voorkeuren zijn opgeslagen.', languageFailed: 'De taal kon niet worden bijgewerkt.',
  },
  contact: {
    title: '{bankName}-ondersteuning', subtitle: 'Ondersteuning per e-mail',
    description: 'Stuur voor hulp een e-mail naar ons ondersteuningsteam. Uw e-mailprogramma wordt geopend met het adres van {bankName} al ingevuld.',
  },
  support: {
    openChat: 'Contact opnemen met ondersteuning',
    unavailable: 'Ondersteuning is tijdelijk niet beschikbaar',
    pushTitle: 'Ondersteuningsmeldingen',
    pushDescription: 'Ontvang een beveiligde melding wanneer er een nieuw antwoord van ondersteuning beschikbaar is.',
    pushChecking: 'Beschikbaarheid van meldingen controleren…',
    pushEnable: 'Meldingen inschakelen',
    pushDisable: 'Uitschakelen',
    pushEnabled: 'Ondersteuningsmeldingen zijn op dit apparaat ingeschakeld.',
    pushDenied: 'Meldingen zijn geblokkeerd in uw browserinstellingen.',
    pushUnsupported: 'Webpushmeldingen zijn niet beschikbaar op dit apparaat.',
    pushEnabling: 'Inschakelen…',
    pushDisabling: 'Uitschakelen…',
    pushError: 'Meldingen konden niet worden ingesteld. Probeer het opnieuw.',
  },
  loanModal: {
    subtitle: 'Directe berekening en indiening van uw aanvraag', stepInformation: 'Gegevens', stepSimulation: 'Berekening',
    disclaimer: 'Uw aanvraag is ter beoordeling geregistreerd. Deze berekening is geen kredietaanbod, goedkeuring of toezegging tot uitbetaling.',
    errorIntro: 'Controleer de gemarkeerde gegevens:',
    identityNotice: 'Uw identiteit is afkomstig uit uw beveiligde sessie. Deze kan niet worden vervangen door een vrij ingevoerde naam of e-mailadres.',
    productUnavailable: 'Er is geen actief leningaanbod beschikbaar in deze valuta.',
    fixedAnnualRate: 'Vast jaarlijks kostenpercentage',
    perMonth: 'per maand', rateHypothesis: 'Indicatieve aanname bij {rate}',
  },
  transferModal: {
    subtitle: 'Opdracht voorbereid in {bankName} — uitvoering buiten de toepassing', stepRecipient: 'Begunstigde', stepDetails: 'Externe bankgegevens', stepAmount: 'Bedrag',
    errorIntro: 'Controleer de gemarkeerde gegevens:', required: '{field} is verplicht.', invalidEmail: 'Vul een geldig e-mailadres in.',
    canadaSelection: 'Vul het Interac-e-mailadres of de gegevens voor directe storting in (transit, instelling en rekening).',
    positiveAmount: 'Het bedrag moet groter zijn dan nul.', recipientPlaceholder: 'Bijv. Claire Dupont',
    destinationCanada: 'Canada (CAD)', destinationEurozone: 'Eurozone (EUR)', destinationUsa: 'Verenigde Staten (USD)', destinationSwiss: 'Zwitserland (CHF)', destinationUk: 'Verenigd Koninkrijk (GBP)', destinationLatam: 'Latijns-Amerika', destinationAfrica: 'Afrika',
    receivingCurrency: 'Ontvangstvaluta', accountOrClabe: 'Rekeningnummer / CLABE / CPF', recipientInstitution: 'Opgegeven ontvangende instelling',
    accountOrRib: 'Rekeningnummer / RIB', accountOrRibPlaceholder: 'Rekeningnummer of RIB', externalBankCode: 'Externe BIC-/SWIFT-/instellingscode',
    transferMotive: 'Omschrijving van de overschrijving', motivePlaceholder: 'Bijv. factuur 4029', externalFees: 'Externe kosten', externalFeesUnknown: 'niet bekend bij {bankName}',
    rateAsOf: 'Indicatieve koers op {date}', beneficiary: 'Begunstigde', motive: 'Omschrijving', saveInstruction: 'Opdracht opslaan',
    fields: {
      recipientName: 'De naam van de begunstigde', iban: 'Het IBAN', bicSwift: 'De BIC-/SWIFT-code', routingNumber: 'Het routingnummer', accountNumber: 'Het rekeningnummer',
      swissIban: 'Het Zwitserse IBAN', clearingNumber: 'Het clearingnummer', sortCode: 'De sortcode', accountOrClabe: 'Het rekeningnummer of CLABE', bankName: 'De naam van de bank',
      accountOrRib: 'Het rekeningnummer of RIB', bankCode: 'De BIC-/SWIFT-/instellingscode', transitNumber: 'Het transitnummer', institutionNumber: 'Het instellingsnummer', interacEmail: 'Het Interac-e-mailadres',
    },
  },
  accountTypes: { current: 'Betaalrekening', savings: 'Spaarrekening' },
  loanMotives: {
    personal: 'Persoonlijk project', real_estate: 'Vastgoedproject', vehicle: 'Aankoop van een voertuig',
    renovation: 'Verbouwing en renovatie', business_cashflow: 'Zakelijke liquiditeit', other: 'Overig',
  },
  ledger: {
    migration_opening_balance: 'Beginsaldo', account_opening: 'Rekening geopend',
    manual_adjustment: 'Aanpassing door de bank', transfer_debit: 'Overschrijving naar {recipient}',
    loan_credit: 'Uitbetaling van lening {reference}',
  },
  notifications: {
    title: 'Meldingen', subtitle: 'Volg de voortgang van uw transacties.',
    empty: 'U hebt geen meldingen.', markAllRead: 'Alles als gelezen markeren', openItem: 'Dossier openen', markRead: 'Als gelezen markeren',
    generic_info: { title: 'Informatie over uw omgeving', message: 'Er is een update beschikbaar in uw beveiligde omgeving.' },
    transfer_submitted: { title: 'Overboeking geregistreerd', message: 'Kosten van {fee} voor de dubbele interne validatie zijn vereist.' },
    transfer_approved: { title: 'Overboeking goedgekeurd', message: 'Uw overboeking is goedgekeurd. Uitvoering in behandeling.' },
    transfer_completed: { title: 'Overboeking uitgevoerd', message: 'Overboeking succesvol uitgevoerd.' },
    transfer_rejected: { title: 'Overboeking geweigerd', message: 'Overboeking geweigerd. Gemaakte kosten zijn niet-restitueerbaar.' },
    transfer_failed: { title: 'Overschrijving niet uitgevoerd', message: 'Uw overschrijving kon niet worden uitgevoerd. Bekijk de status.' },
    loan_submitted: { title: 'Leningaanvraag geregistreerd', message: 'Uw leningaanvraag is ter beoordeling ingediend.' },
    loan_approved: { title: 'Lening goedgekeurd', message: 'Uw leningaanvraag is goedgekeurd.' },
    loan_disbursed: { title: 'Lening uitbetaald', message: 'De lening is op uw rekening gestort.' },
    loan_rejected: { title: 'Leningaanvraag afgewezen', message: 'Uw leningaanvraag is niet geaccepteerd.' },
    loan_failed: { title: 'Uitbetaling van lening onderbroken', message: 'De lening kon niet volledig worden uitbetaald. Bekijk de status.' },
    kyc_submitted: { title: 'Identiteitsdossier ingediend', message: 'Uw identiteitsdossier is ter controle ingediend.' },
    kyc_information_requested: { title: 'Aanvullende informatie vereist', message: 'Er zijn aanvullende gegevens nodig om uw identiteit te controleren.' },
    kyc_resubmitted: { title: 'Correcties ingediend', message: 'Uw correcties zijn ter controle ingediend.' },
    kyc_approved: { title: 'Identiteit geverifieerd', message: 'De controle van uw identiteit is afgerond.' },
    kyc_rejected: { title: 'Identiteitscontrole niet geslaagd', message: 'Uw identiteitsdossier kon niet worden goedgekeurd.' },
    document_available: { title: 'Nieuw document beschikbaar', message: 'Er is een nieuw officieel document beschikbaar in uw omgeving.' },
  },
  documents: {
    bank_details: 'Bankgegevens', account_statement: 'Rekeningoverzicht',
    balance_certificate: 'Saldoverklaring', transfer_confirmation: 'Bevestiging van de overboeking',
    loan_disbursement_confirmation: 'Bevestiging van de uitbetaling van de lening', loan_decision: 'Beslissing over de lening',
  },
  errors: {
    AUTH_REQUIRED: 'Uw sessie is verlopen. Log opnieuw in.',
    CONFIGURATION_UNAVAILABLE: 'De service is tijdelijk niet beschikbaar.',
    INVALID_REQUEST: 'Sommige gegevens zijn ongeldig. Controleer ze.',
    NETWORK_ERROR: 'De service kon niet worden bereikt. Probeer het opnieuw.',
    NOT_FOUND: 'Het gevraagde onderdeel is niet gevonden.',
    PERMISSION_DENIED: 'U bent niet bevoegd om deze handeling uit te voeren.',
    SAVE_FAILED: 'Uw wijzigingen konden niet worden opgeslagen. Probeer het opnieuw.',
    UPLOAD_FAILED: 'Het uploaden is mislukt. Probeer het opnieuw.',
    UNKNOWN_ERROR: 'Er is een fout opgetreden. Probeer het opnieuw.',
  },
};

export const extraUserMessages: Record<Language, ExtraMessages> = { fr, en, de, es, it, nl };

export const userMessages = {
  fr: { app: translations.fr, banking: bankingMessages.fr, public: publicMessages.fr, kyc: kycTranslations.fr, extra: fr },
  en: { app: translations.en, banking: bankingMessages.en, public: publicMessages.en, kyc: kycTranslations.en, extra: en },
  de: { app: translations.de, banking: bankingMessages.de, public: publicMessages.de, kyc: kycTranslations.de, extra: de },
  es: { app: translations.es, banking: bankingMessages.es, public: publicMessages.es, kyc: kycTranslations.es, extra: es },
  it: { app: translations.it, banking: bankingMessages.it, public: publicMessages.it, kyc: kycTranslations.it, extra: it },
  nl: { app: translations.nl, banking: bankingMessages.nl, public: publicMessages.nl, kyc: kycTranslations.nl, extra: nl },
} as const;

export function interpolate(message: string, params: Record<string, unknown> = {}) {
  return message.replace(/\{([a-zA-Z0-9_]+)\}/g, (_match, key: string) => {
    const value = params[key];
    return value === undefined || value === null || value === '' ? '—' : String(value);
  });
}

export function notificationCopy(
  language: Language,
  key: NotificationMessageKey,
  params: Record<string, unknown> = {},
) {
  let effectiveParams = params;
  if (key === 'transfer_submitted' && !params.fee) {
    const currency = String(params.currency || 'EUR').toUpperCase();
    const defaultFee = currency === 'USD' ? '150,00 $' : currency === 'GBP' ? '£150.00' : '150,00 €';
    effectiveParams = { ...params, fee: defaultFee };
  }
  const message = extraUserMessages[language].notifications[key];
  return { title: interpolate(message.title, effectiveParams), message: interpolate(message.message, effectiveParams) };
}

export function localizedAppError(language: Language, code: AppErrorCode = 'UNKNOWN_ERROR') {
  return extraUserMessages[language].errors[code];
}

export function appErrorCode(error: unknown): AppErrorCode {
  if (error && typeof error === 'object' && 'code' in error) {
    const code = String(error.code);
    if (code === 'PGRST301' || code === '401') return 'AUTH_REQUIRED';
    if (code === '42501' || code === '403') return 'PERMISSION_DENIED';
    if (code === 'PGRST116' || code === '404') return 'NOT_FOUND';
    if ((fr.errors as Record<string, string>)[code]) return code as AppErrorCode;
  }
  if (error instanceof TypeError) return 'NETWORK_ERROR';
  return 'UNKNOWN_ERROR';
}

export function accountTypeLabel(language: Language, type: 'current' | 'savings') {
  return extraUserMessages[language].accountTypes[type];
}

export function loanMotiveLabel(language: Language, code: LoanMotiveCode) {
  return extraUserMessages[language].loanMotives[code];
}

export function normalizeLoanMotiveCode(value: string | null | undefined): LoanMotiveCode {
  const normalized = value?.trim().toLocaleLowerCase('fr-FR') ?? '';
  const mapping: Record<string, LoanMotiveCode> = {
    personal: 'personal', 'prêt personnel': 'personal', 'projet personnel': 'personal',
    real_estate: 'real_estate', 'projet immobilier': 'real_estate', immobilier: 'real_estate',
    vehicle: 'vehicle', 'achat véhicule': 'vehicle', 'achat véhicule / auto': 'vehicle', auto: 'vehicle',
    renovation: 'renovation', travaux: 'renovation', 'travaux / rénovation': 'renovation',
    business_cashflow: 'business_cashflow', 'trésorerie entreprise': 'business_cashflow',
    other: 'other', autre: 'other',
  };
  return mapping[normalized] ?? 'other';
}

export function ledgerEntryLabel(
  language: Language,
  kind: LedgerEntryKind,
  metadata: Record<string, unknown> = {},
) {
  return interpolate(extraUserMessages[language].ledger[kind], {
    recipient: metadata.recipient_name ?? metadata.recipient ?? extraUserMessages[language].common.unavailable,
    reference: metadata.loan_reference ?? metadata.reference ?? '',
  });
}

export function officialDocumentTitle(language: Language, type: OfficialDocumentType) {
  return extraUserMessages[language].documents[type];
}
