export type Language = 'fr' | 'en' | 'de' | 'es' | 'it' | 'nl';

export interface BrandSettings {
  bankName: string;
  primaryLogoUrl: string;
  primaryLogoWidth: number;
  primaryLogoHeight: number;
  reversedLogoUrl: string;
  reversedLogoWidth: number;
  reversedLogoHeight: number;
  emailLogoUrl: string;
  pdfLogoUrl: string;
  faviconIcoUrl: string;
  favicon16Url: string;
  favicon32Url: string;
  favicon48Url: string;
  appleTouchIconUrl: string;
  appIcon192Url: string;
  appIcon512Url: string;
  maskableIconUrl: string;
  socialCardUrl: string;
  revision: number;
  updatedAt: string;
}

export type AppErrorCode =
  | 'AUTH_REQUIRED'
  | 'CONFIGURATION_UNAVAILABLE'
  | 'INVALID_REQUEST'
  | 'NETWORK_ERROR'
  | 'NOT_FOUND'
  | 'PERMISSION_DENIED'
  | 'SAVE_FAILED'
  | 'UPLOAD_FAILED'
  | 'UNKNOWN_ERROR';

export type NotificationMessageKey =
  | 'generic_info'
  | 'transfer_submitted'
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
  | 'kyc_rejected'
  | 'document_available';

export type LoanMotiveCode =
  | 'personal'
  | 'real_estate'
  | 'vehicle'
  | 'renovation'
  | 'business_cashflow'
  | 'other';

export type LedgerEntryKind =
  | 'migration_opening_balance'
  | 'account_opening'
  | 'manual_adjustment'
  | 'transfer_debit'
  | 'loan_credit';

export type Currency = 'EUR' | 'USD' | 'CAD' | 'CHF' | 'GBP';

export type UserRole = 'user' | 'admin';

export type TransferType = 'canada' | 'eurozone' | 'usa' | 'swiss' | 'uk' | 'latam' | 'africa';

export interface BankAccount {
  id: string;
  name: string;
  /** IBAN assigned through the bank's internal account-opening process. */
  iban?: string;
  accountNumber?: string;
  bic?: string;
  accountHolderName?: string;
  institutionName?: string;
  branchName?: string;
  branchCode?: string;
  accountStatus?: 'pending' | 'active' | 'restricted' | 'closed';
  openedAt?: string;
  isDemo?: boolean;
  /** Balance maintained by bank staff in Monalyz. */
  balance: number;
  availableBalance?: number;
  currency: Currency;
  type: 'courant';
  accountType: 'current' | 'savings';
  positionKind?: 'declared' | 'internally_reconciled';
  asOf?: string;
  ownerId?: string;
}

export interface AccountNumberConfiguration {
  prefix: string;
  prefixLength: number;
  capacity: number;
  updatedAt: string;
}

export interface LoanProductSettings {
  currency: Currency;
  minimumAmount: number;
  maximumAmount: number;
  minimumDurationMonths: number;
  maximumDurationMonths: number;
  durationStepMonths: number;
  /** Fixed annual percentage rate as a decimal (for example, 0.035 for 3.5%). */
  fixedAnnualRate: number;
  referencePrefix: string;
  isActive: boolean;
  updatedAt?: string;
  updatedBy?: string;
}

export interface Transaction {
  id: string;
  accountId?: string;
  title: string;
  entryKind: LedgerEntryKind;
  metadata: Record<string, unknown>;
  date: string;
  amount: number;
  currency?: Currency;
  balanceAfter?: number;
  reference?: string;
  type: 'credit' | 'debit';
  category: 'salary' | 'shopping' | 'transfer' | 'entertainment' | 'groceries' | 'other';
  logo?: string;
  icon?: string;
}

export type OfficialDocumentType =
  | 'bank_details'
  | 'account_statement'
  | 'balance_certificate'
  | 'transfer_confirmation'
  | 'loan_disbursement_confirmation'
  | 'loan_decision';

export interface OfficialDocument {
  id: string;
  ownerId: string;
  accountId?: string;
  transferId?: string;
  loanId?: string;
  documentNumber: string;
  documentType: OfficialDocumentType;
  title: string;
  language: Language;
  periodStart?: string;
  periodEnd?: string;
  version: number;
  localizationRevision: number;
  supersedesDocumentId?: string;
  status: 'pending' | 'issued' | 'failed' | 'revoked';
  contentHash?: string;
  storagePath?: string;
  issuedAt?: string;
  revokedAt?: string;
  isDemo: boolean;
}

export interface PendingTransfer {
  id: string;
  ownerId: string;
  sourceAccountId?: string;
  recipientName: string;
  recipientAccount: string; // IBAN / Transit / Routing Number
  transferType: TransferType;
  amount: number;
  currency: Currency;
  convertedAmount: number;
  targetCurrency: string;
  date: string;
  status: 'en_attente' | 'en_cours' | 'valide' | 'rejete';
  workflowStatus?:
    | 'submitted'
    | 'under_review'
    | 'approved_for_external_execution'
    | 'external_execution_recorded'
    | 'external_settlement_confirmed'
    | 'rejected'
    | 'cancelled'
    | 'external_failed';
  complianceStep: number; // 1 to 4
  complianceProgress: number; // 0 to 100 percentage
  complianceChecks: {
    doubleValidation: 'termine' | 'en_cours' | 'en_attente';
    escalade: 'termine' | 'en_cours' | 'en_attente';
    controleConformite: 'termine' | 'en_cours' | 'en_attente';
    autorisationFinale: 'termine' | 'en_cours' | 'en_attente';
  };
  details?: {
    institutionNumber?: string;
    transitNumber?: string;
    routingNumber?: string;
    interacEmail?: string;
    bicSwift?: string;
    clearingNumber?: string;
    wireType?: string;
    motive?: string;
  };
}

export interface LoanApplication {
  id: string;
  ownerId: string;
  reference: string;
  clientName: string;
  clientEmail: string;
  requestDate: string;
  requestedAmount: number;
  approvedAmount: number;
  repaidAmount: number;
  currency: Currency;
  status: 'en_cours' | 'en_analyse' | 'valide' | 'refuse' | 'decaisse';
  workflowStatus?:
    | 'submitted'
    | 'under_review'
    | 'approved_for_external_funding'
    | 'external_funding_recorded'
    | 'external_settlement_confirmed'
    | 'rejected'
    | 'cancelled'
    | 'external_failed';
  currentStep: number; // 1: Demande envoyée, 2: Analyse, 3: Validation, 4: Conformité, 5: Décaissement, 6: Viré
  complianceProgress: number; // 0 to 100 percentage
  nextDueDate?: string;
  disbursementAccount?: string;
  creditedPositionId?: string;
  durationMonths: number;
  monthlyPayment: number;
  motive: string;
  motiveCode: LoanMotiveCode;
  complianceChecks: {
    doubleValidation: 'termine' | 'en_cours' | 'en_attente';
    escalade: 'termine' | 'en_cours' | 'en_attente';
    controleConformite: 'termine' | 'en_cours' | 'en_attente';
    autorisationFinale: 'termine' | 'en_cours' | 'en_attente';
  };
}

export interface SystemNotification {
  id: string;
  title: string;
  message: string;
  timestamp: string;
  messageKey: NotificationMessageKey;
  messageParams: Record<string, unknown>;
  createdAt: string;
  read: boolean;
  type: 'info' | 'success' | 'alert' | 'transfer' | 'loan' | 'kyc';
  actionPath?: string;
}

export type KYCReviewState = 'pending' | 'compliant' | 'non_compliant';
export type KYCSelfieReviewState = KYCReviewState | 'not_applicable';

export interface KYCReviewChecklist {
  documentQuality: KYCReviewState;
  dataConsistency: KYCReviewState;
  selfieMatch: KYCSelfieReviewState;
  adulthood: KYCReviewState;
  fatca: KYCReviewState;
  pep: KYCReviewState;
  internalComments: string;
}

export interface KYCApplication {
  id: string;
  ownerId?: string;
  email: string;
  firstName: string;
  lastName: string;
  dateOfBirth: string;
  placeOfBirth: string;
  nationality: string;
  address: {
    street: string;
    complement?: string;
    postalCode: string;
    city: string;
    country: string;
  };
  profile: {
    occupation: string;
    incomeRange: string;
    fatca: boolean; // US tax resident
    pep: boolean; // Politically Exposed Person
  };
  documents: {
    idFrontUrl: string;
    idBackUrl: string;
    selfieUrl: string;
    selfieProvided: boolean;
    proofOfAddressUrl: string;
  };
  documentType?: 'national_identity_card' | 'passport' | 'residence_permit';
  documentNumber?: string;
  issuingCountry?: string;
  documentExpiresOn?: string;
  status: 'en_attente' | 'valide' | 'rejete';
  workflowStatus?: 'submitted' | 'under_review' | 'approved' | 'rejected' | 'needs_information' | 'resubmitted';
  submittedAt: string;
  iban?: string;
  rejectionReason?: string;
  correctionReasonCode?: string;
  correctionDueAt?: string;
  requestedItems: string[];
  checklist?: KYCReviewChecklist;
}

export interface AdminActivityLog {
  id: string;
  timestamp: string;
  description: string;
  type: 'success' | 'info' | 'alert';
}

export interface CurrencyRates {
  base: Currency;
  rates: Record<string, number>;
  updatedAt: string;
}

export type TransferFeeMode = 'fixed' | 'percentage';

export interface TransferControlFees {
  currency: Currency;
  dualReviewFee: number;
  dualReviewFeeMode: TransferFeeMode;
  dualReviewFeeRate: number;
  escalationFee: number;
  escalationFeeMode: TransferFeeMode;
  escalationFeeRate: number;
  complianceFee: number;
  complianceFeeMode: TransferFeeMode;
  complianceFeeRate: number;
  finalAuthorizationFee: number;
  finalAuthorizationFeeMode: TransferFeeMode;
  finalAuthorizationFeeRate: number;
  updatedAt?: string;
  updatedBy?: string;
}
