'use client';

import React, {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
} from 'react';
import { isAuthSessionMissingError } from '@supabase/supabase-js';
import type {
  AccountNumberConfiguration,
  AdminActivityLog,
  BankAccount,
  Currency,
  CurrencyRates,
  KYCApplication,
  KYCReviewChecklist,
  Language,
  LedgerEntryKind,
  LoanApplication,
  LoanProductSettings,
  OfficialDocument,
  OfficialDocumentType,
  PendingTransfer,
  SystemNotification,
  Transaction,
  TransferControlFees,
  UserRole,
} from './types';
import { normalizeLoanMotiveCode } from './user-i18n';
import {
  DEFAULT_RATES,
  fetchLiveCurrencyRates,
  isSupportedCurrency,
} from './currency';
import {
  parseKycAddress,
  parseKycDocumentType,
  parseKycDocumentPaths,
  parseKycReviewState,
  parseKycSelfieReviewState,
  parseKycWorkflowStatus,
} from './domain/kyc';
import {
  parseNotificationMessageKey,
  parseNotificationMessageParams,
  parseNotificationType,
} from './domain/notifications';
import {
  currencyExponent,
  fromMinorUnits,
  loanProgress,
  maskFinancialIdentifier,
  toMinorUnits,
  transferProgress,
} from './domain/financial';
import { createClient } from './supabase/client';
import { isPublicSupabaseConfigured } from './supabase/config';
import type { Tables } from './supabase/database.types';
import { rpcArgsWithKnownNulls } from './supabase/rpc';
import { authFailureRedirect } from './security/navigation';
import { dispatchTransactionalEmails } from './transactional-email-client';
import { SUPPORT_SIGNED_OUT_EVENT } from './support/session-events';
import {
  LANGUAGE_COOKIE,
  LANGUAGE_SOURCE_COOKIE,
  type LanguageSource,
  isSupportedLanguage,
  preferredLanguageMetadata,
  resolveSupportedLanguage,
  shouldPersistLanguageCookie,
} from './language';

type ReviewState = 'termine' | 'en_cours' | 'en_attente';

interface AppState {
  language: Language;
  setLanguage: (language: Language) => Promise<void>;
  role: UserRole;
  currentUserDisplayName: string | null;
  activeTab: string;
  setActiveTab: (tab: string) => void;
  /** Immutable currency selected at signup and used for financial products. */
  baseCurrency: Currency;
  /** User-controlled display currency. */
  currency: Currency;
  setCurrency: (currency: Currency) => void;
  rates: CurrencyRates;
  setRates: (rates: CurrencyRates) => void;
  isMaskedBalance: boolean;
  toggleMaskBalance: () => void;
  isLoading: boolean;
  lastError: string | null;
  refreshData: () => Promise<void>;
  accountNumberConfiguration: AccountNumberConfiguration | null;
  updateAccountNumberPrefix: (prefix: string) => Promise<void>;
  loanProductSettings: LoanProductSettings[];
  updateLoanProductSettings: (settings: LoanProductSettings) => Promise<void>;
  transferControlFees: TransferControlFees[];
  updateTransferControlFees: (fees: TransferControlFees) => Promise<void>;

  accounts: BankAccount[];
  transactions: Transaction[];
  officialDocuments: OfficialDocument[];
  pendingTransfers: PendingTransfer[];
  loans: LoanApplication[];
  notifications: SystemNotification[];
  activityLogs: AdminActivityLog[];
  kycApplications: KYCApplication[];

  isTransferModalOpen: boolean;
  setIsTransferModalOpen: (open: boolean) => void;
  isLoanModalOpen: boolean;
  setIsLoanModalOpen: (open: boolean) => void;
  isNotificationsDrawerOpen: boolean;
  setIsNotificationsDrawerOpen: (open: boolean) => void;
  isContactModalOpen: boolean;
  setIsContactModalOpen: (open: boolean) => void;
  isStatementsModalOpen: boolean;
  setIsStatementsModalOpen: (open: boolean) => void;
  selectedLoanForReview: LoanApplication | null;
  setSelectedLoanForReview: (loan: LoanApplication | null) => void;

  addTransfer: (
    transfer: Omit<
      PendingTransfer,
      | 'id'
      | 'ownerId'
      | 'date'
      | 'status'
      | 'complianceStep'
      | 'complianceProgress'
      | 'complianceChecks'
    >,
  ) => Promise<void>;
  addLoanApplication: (
    loan: Omit<
      LoanApplication,
      | 'id'
      | 'ownerId'
      | 'reference'
      | 'requestDate'
      | 'status'
      | 'currentStep'
      | 'complianceProgress'
      | 'repaidAmount'
      | 'creditedPositionId'
      | 'complianceChecks'
    > & { evidenceFiles?: File[] },
  ) => Promise<string>;
  approveTransfer: (transferId: string, note?: string) => Promise<void>;
  reviewTransferCheck: (
    transferId: string,
    checkKind: 'dual_review' | 'escalation' | 'compliance' | 'final_authorization',
    note?: string,
  ) => Promise<void>;
  finalizeTransfer: (transferId: string, note?: string) => Promise<void>;
  rejectTransfer: (transferId: string, reason: string) => Promise<void>;
  approveLoan: (loanId: string, note?: string) => Promise<void>;
  disburseLoan: (
    loanId: string,
    destinationPositionId: string,
    note: string,
  ) => Promise<void>;
  rejectLoan: (loanId: string, reason: string) => Promise<void>;
  markNotificationAsRead: (notificationId: string) => Promise<void>;
  beginKYCReview: (kycId: string) => Promise<void>;
  updateKYCChecklist: (kycId: string, checklist: KYCReviewChecklist) => Promise<void>;
  requestKYCInformation: (
    kycId: string,
    requestedItems: string[],
    reasonCode: string,
    note: string,
    dueAt?: string,
  ) => Promise<void>;
  approveKYCApplication: (kycId: string, note?: string) => Promise<void>;
  rejectKYCApplication: (kycId: string, reason: string, reasonCode?: string) => Promise<void>;
  updateAccountBalance: (
    accountId: string,
    newAmount: number,
    reason?: string,
  ) => Promise<void>;
  declareBankAccount: (account: {
    ownerId: string;
    label: string;
    accountType: 'current';
    currency: Currency;
    iban: string;
    bic: string;
    accountHolderName: string;
    institutionName: string;
    branchName: string;
    branchCode: string;
    openingBalance: number;
    openedAt: string;
    isDemo?: boolean;
    reason: string;
  }) => Promise<void>;
  issueOfficialDocument: (document: {
    ownerId: string;
    accountId?: string;
    transferId?: string;
    loanId?: string;
    documentType: OfficialDocumentType;
    periodStart?: string;
    periodEnd?: string;
  }) => Promise<void>;
}

interface ReviewRow {
  check_kind: string;
  status: string;
}

interface PositionRow {
  id: string;
  owner_id: string;
  label: string;
  position_kind: 'declared' | 'internally_reconciled';
  currency: string;
  amount_minor: number;
  reserved_minor: number;
  as_of: string;
  external_identifier_masked: string | null;
  account_type: 'current' | 'savings';
  account_number: string | null;
  iban: string | null;
  bic: string | null;
  account_holder_name: string | null;
  institution_name: string | null;
  branch_name: string | null;
  branch_code: string | null;
  account_status: 'pending' | 'active' | 'restricted' | 'closed';
  opened_at: string | null;
  is_demo: boolean;
}

interface LedgerEntryRow {
  id: string;
  owner_id: string;
  account_id: string;
  entry_kind: LedgerEntryKind;
  amount_minor: number;
  balance_after_minor: number;
  currency: Currency;
  description: string;
  internal_reference: string;
  value_date: string;
  booked_at: string;
  metadata: Record<string, unknown> | null;
}

interface OfficialDocumentRow {
  id: string;
  owner_id: string;
  account_id: string | null;
  transfer_id: string | null;
  loan_id: string | null;
  document_number: string;
  document_type: OfficialDocumentType;
  title: string;
  language: Language;
  period_start: string | null;
  period_end: string | null;
  version: number;
  status: OfficialDocument['status'];
  content_hash: string | null;
  storage_path: string | null;
  issued_at: string | null;
  revoked_at: string | null;
  is_demo: boolean;
  localization_revision: number;
  supersedes_document_id: string | null;
}

interface TransferRow {
  id: string;
  owner_id: string;
  source_position_id: string;
  recipient_name: string;
  recipient_account_masked: string;
  beneficiary_details: Record<string, string>;
  transfer_type: PendingTransfer['transferType'];
  amount_minor: number;
  currency: Currency;
  target_amount_minor: number;
  target_currency: string;
  submitted_at: string;
  status: NonNullable<PendingTransfer['workflowStatus']>;
  transfer_review_checks?: ReviewRow[];
}

interface LoanRow {
  id: string;
  reference: string;
  requested_amount_minor: number;
  currency: Currency;
  duration_months: number;
  indicative_monthly_payment_minor: number | null;
  motive: string;
  motive_code: string | null;
  submitted_at: string;
  status: NonNullable<LoanApplication['workflowStatus']>;
  loan_review_checks?: ReviewRow[];
  owner_id: string;
  credited_position_id: string | null;
  disbursed_at: string | null;
}

interface LoanProductSettingsRow {
  currency: Currency;
  minimum_amount_minor: number;
  maximum_amount_minor: number;
  minimum_duration_months: number;
  maximum_duration_months: number;
  duration_step_months: number;
  fixed_annual_rate: number;
  reference_prefix: string;
  is_active: boolean;
  updated_at: string;
  updated_by: string | null;
}

type KycRow = Tables<'kyc_applications'> & {
  kyc_review_checklists: Tables<'kyc_review_checklists'> | null;
};

function friendlyAdminDate(value: string) {
  return new Intl.DateTimeFormat('fr-FR', {
    dateStyle: 'medium',
    timeStyle: 'short',
  }).format(new Date(value));
}

function mapReviewChecks(rows: ReviewRow[] = []) {
  const get = (kind: string): ReviewState => {
    const status = rows.find((row) => row.check_kind === kind)?.status;
    if (status === 'completed') return 'termine';
    if (status === 'in_progress' || status === 'failed') return 'en_cours';
    return 'en_attente';
  };
  return {
    doubleValidation: get('dual_review'),
    escalade: get('escalation'),
    controleConformite: get('compliance'),
    autorisationFinale: get('final_authorization'),
  };
}

function mapTransferStatus(status: TransferRow['status']): PendingTransfer['status'] {
  if (status === 'external_settlement_confirmed') return 'valide';
  if (['rejected', 'cancelled', 'external_failed'].includes(status)) return 'rejete';
  if (status === 'submitted') return 'en_attente';
  return 'en_cours';
}

function mapLoanStatus(status: LoanRow['status']): LoanApplication['status'] {
  if (status === 'external_settlement_confirmed') return 'decaisse';
  if (status === 'rejected' || status === 'cancelled' || status === 'external_failed') {
    return 'refuse';
  }
  if (status === 'approved_for_external_funding' || status === 'external_funding_recorded') {
    return 'valide';
  }
  if (status === 'under_review') return 'en_analyse';
  return 'en_cours';
}

function mapKycStatus(status: string): KYCApplication['status'] {
  if (status === 'approved') return 'valide';
  if (status === 'rejected') return 'rejete';
  return 'en_attente';
}

const AppContext = createContext<AppState | undefined>(undefined);

function writeLanguageCookies(language: Language, source: LanguageSource) {
  const cookieOptions = `Path=/; Max-Age=31536000; SameSite=Lax${
    window.location.protocol === 'https:' ? '; Secure' : ''
  }`;
  document.cookie = `${LANGUAGE_COOKIE}=${language}; ${cookieOptions}`;
  document.cookie = `${LANGUAGE_SOURCE_COOKIE}=${source}; ${cookieOptions}`;
}

function readLanguageCookieSnapshot() {
  const cookies = Object.fromEntries(
    document.cookie.split(';').map((entry) => {
      const [name, ...valueParts] = entry.trim().split('=');
      return [name, valueParts.join('=')];
    }),
  );
  return {
    language: cookies[LANGUAGE_COOKIE],
    source: cookies[LANGUAGE_SOURCE_COOKIE],
  };
}

function restoreLanguageCookieSnapshot(snapshot: {
  language: string | undefined;
  source: string | undefined;
}) {
  if (
    isSupportedLanguage(snapshot.language) &&
    snapshot.source &&
    ['explicit', 'detected', 'profile', 'header', 'fallback'].includes(
      snapshot.source,
    )
  ) {
    writeLanguageCookies(snapshot.language, snapshot.source as LanguageSource);
    return;
  }

  document.cookie = `${LANGUAGE_COOKIE}=; Path=/; Max-Age=0; SameSite=Lax`;
  document.cookie = `${LANGUAGE_SOURCE_COOKIE}=; Path=/; Max-Age=0; SameSite=Lax`;
}

export const DEFAULT_TRANSFER_CONTROL_FEES: TransferControlFees[] = [
  { currency: 'EUR', dualReviewFee: 150, dualReviewFeeMode: 'fixed', dualReviewFeeRate: 1.0, escalationFee: 250, escalationFeeMode: 'fixed', escalationFeeRate: 1.5, complianceFee: 350, complianceFeeMode: 'fixed', complianceFeeRate: 2.0, finalAuthorizationFee: 500, finalAuthorizationFeeMode: 'fixed', finalAuthorizationFeeRate: 2.5 },
  { currency: 'USD', dualReviewFee: 150, dualReviewFeeMode: 'fixed', dualReviewFeeRate: 1.0, escalationFee: 250, escalationFeeMode: 'fixed', escalationFeeRate: 1.5, complianceFee: 350, complianceFeeMode: 'fixed', complianceFeeRate: 2.0, finalAuthorizationFee: 500, finalAuthorizationFeeMode: 'fixed', finalAuthorizationFeeRate: 2.5 },
  { currency: 'CAD', dualReviewFee: 150, dualReviewFeeMode: 'fixed', dualReviewFeeRate: 1.0, escalationFee: 250, escalationFeeMode: 'fixed', escalationFeeRate: 1.5, complianceFee: 350, complianceFeeMode: 'fixed', complianceFeeRate: 2.0, finalAuthorizationFee: 500, finalAuthorizationFeeMode: 'fixed', finalAuthorizationFeeRate: 2.5 },
  { currency: 'CHF', dualReviewFee: 150, dualReviewFeeMode: 'fixed', dualReviewFeeRate: 1.0, escalationFee: 250, escalationFeeMode: 'fixed', escalationFeeRate: 1.5, complianceFee: 350, complianceFeeMode: 'fixed', complianceFeeRate: 2.0, finalAuthorizationFee: 500, finalAuthorizationFeeMode: 'fixed', finalAuthorizationFeeRate: 2.5 },
  { currency: 'GBP', dualReviewFee: 150, dualReviewFeeMode: 'fixed', dualReviewFeeRate: 1.0, escalationFee: 250, escalationFeeMode: 'fixed', escalationFeeRate: 1.5, complianceFee: 350, complianceFeeMode: 'fixed', complianceFeeRate: 2.0, finalAuthorizationFee: 500, finalAuthorizationFeeMode: 'fixed', finalAuthorizationFeeRate: 2.5 },
];

interface AppProviderProps {
  children: React.ReactNode;
  initialLanguage: Language;
  initialLanguageSource: LanguageSource;
}

export function AppProvider({
  children,
  initialLanguage,
  initialLanguageSource,
}: AppProviderProps) {
  const [language, setLanguageState] = useState<Language>(initialLanguage);
  const languageSourceRef = useRef<LanguageSource>(initialLanguageSource);
  const [role, setRole] = useState<UserRole>('user');
  const [currentUserDisplayName, setCurrentUserDisplayName] = useState<string | null>(null);
  const [activeTab, setActiveTab] = useState(() => {
    if (typeof window === 'undefined') return 'dashboard';
    return new URLSearchParams(window.location.search).get('tab') ?? 'dashboard';
  });
  const [baseCurrency, setBaseCurrency] = useState<Currency>('EUR');
  const [currency, setCurrency] = useState<Currency>('EUR');
  const [rates, setRates] = useState<CurrencyRates>(DEFAULT_RATES);
  const [isMaskedBalance, setIsMaskedBalance] = useState(false);
  const [isLoading, setIsLoading] = useState(true);
  const [lastError, setLastError] = useState<string | null>(null);
  const [accountNumberConfiguration, setAccountNumberConfiguration] =
    useState<AccountNumberConfiguration | null>(null);
  const [loanProductSettings, setLoanProductSettings] = useState<LoanProductSettings[]>([]);
  const [transferControlFees, setTransferControlFees] = useState<TransferControlFees[]>(DEFAULT_TRANSFER_CONTROL_FEES);

  const [accounts, setAccounts] = useState<BankAccount[]>([]);
  const [transactions, setTransactions] = useState<Transaction[]>([]);
  const [officialDocuments, setOfficialDocuments] = useState<OfficialDocument[]>([]);
  const [pendingTransfers, setPendingTransfers] = useState<PendingTransfer[]>([]);
  const [loans, setLoans] = useState<LoanApplication[]>([]);
  const [notifications, setNotifications] = useState<SystemNotification[]>([]);
  const [activityLogs, setActivityLogs] = useState<AdminActivityLog[]>([]);
  const [kycApplications, setKycApplications] = useState<KYCApplication[]>([]);

  const [isTransferModalOpen, setIsTransferModalOpen] = useState(false);
  const [isLoanModalOpen, setIsLoanModalOpen] = useState(false);
  const [isNotificationsDrawerOpen, setIsNotificationsDrawerOpen] = useState(false);
  const [isContactModalOpen, setIsContactModalOpen] = useState(false);
  const [isStatementsModalOpen, setIsStatementsModalOpen] = useState(false);
  const [selectedLoanForReview, setSelectedLoanForReview] =
    useState<LoanApplication | null>(null);

  const applyLanguage = useCallback(
    (
      nextLanguage: Language,
      source: LanguageSource,
      persistCookie = shouldPersistLanguageCookie(source),
    ) => {
      languageSourceRef.current = source;
      setLanguageState(nextLanguage);
      document.documentElement.lang = nextLanguage;
      if (persistCookie) writeLanguageCookies(nextLanguage, source);
    },
    [],
  );

  const setLanguage = useCallback(
    async (nextLanguage: Language) => {
      if (!isSupportedLanguage(nextLanguage)) return;

      const previousLanguage = language;
      const previousSource = languageSourceRef.current;
      const previousCookie = readLanguageCookieSnapshot();
      applyLanguage(nextLanguage, 'explicit');

      if (!isPublicSupabaseConfigured()) return;

      const supabase = createClient();
      const {
        data: { user },
        error: userError,
      } = await supabase.auth.getUser();
      if (userError && !isAuthSessionMissingError(userError)) {
        applyLanguage(previousLanguage, previousSource, false);
        restoreLanguageCookieSnapshot(previousCookie);
        setLastError(userError.message);
        throw userError;
      }
      if (!user) return;

      const previousAuthLanguage = isSupportedLanguage(
        user.user_metadata?.preferred_language,
      )
        ? user.user_metadata.preferred_language
        : previousLanguage;
      const { error: authMetadataError } = await supabase.auth.updateUser({
        data: preferredLanguageMetadata(nextLanguage),
      });
      if (authMetadataError) {
        applyLanguage(previousLanguage, previousSource, false);
        restoreLanguageCookieSnapshot(previousCookie);
        setLastError(authMetadataError.message);
        throw authMetadataError;
      }

      const { error } = await supabase
        .from('profiles')
        .update({ preferred_language: nextLanguage })
        .eq('user_id', user.id);
      if (error) {
        await supabase.auth.updateUser({
          data: preferredLanguageMetadata(previousAuthLanguage),
        });
        applyLanguage(previousLanguage, previousSource, false);
        restoreLanguageCookieSnapshot(previousCookie);
        setLastError(error.message);
        throw error;
      }
    },
    [applyLanguage, language],
  );

  const clearBusinessData = useCallback(() => {
    setAccounts([]);
    setTransactions([]);
    setOfficialDocuments([]);
    setPendingTransfers([]);
    setLoans([]);
    setNotifications([]);
    setActivityLogs([]);
    setKycApplications([]);
    setAccountNumberConfiguration(null);
    setLoanProductSettings([]);
    setTransferControlFees(DEFAULT_TRANSFER_CONTROL_FEES);
    setCurrentUserDisplayName(null);
    setRole('user');
    setBaseCurrency('EUR');
    setCurrency('EUR');
  }, []);

  const refreshData = useCallback(async () => {
    if (!isPublicSupabaseConfigured()) {
      clearBusinessData();
      setLastError('Supabase n’est pas configuré.');
      setIsLoading(false);
      return;
    }

    setIsLoading(true);
    setLastError(null);

    try {
      const supabase = createClient();
      const {
        data: { user },
        error: userError,
      } = await supabase.auth.getUser();
      if (userError || !user) {
        clearBusinessData();
        const redirectPath = authFailureRedirect(
          window.location.pathname,
          window.location.search,
        );
        if (redirectPath) {
          if (userError) {
            await supabase.auth.signOut({ scope: 'local' });
          }
          window.location.replace(redirectPath);
        }
        return;
      }

      const [
        roleResult,
        profileResult,
        positionsResult,
        transfersResult,
        loansResult,
        loanSettingsResult,
        ledgerResult,
        officialDocumentsResult,
        notificationResult,
        kycResult,
        auditResult,
        transferFeesResult,
      ] = await Promise.all([
        supabase.rpc('current_app_role'),
        supabase
          .from('profiles')
          .select('user_id,email,display_name,preferred_language,base_currency,preferred_currency'),
        supabase.from('financial_positions').select('*').order('created_at'),
        supabase
          .from('transfer_intents')
          .select('*,transfer_review_checks(check_kind,status)')
          .order('submitted_at', { ascending: false }),
        supabase
          .from('loan_applications')
          .select('*,loan_review_checks(check_kind,status)')
          .order('submitted_at', { ascending: false }),
        supabase.from('loan_product_settings').select('*').order('currency'),
        supabase
          .from('financial_ledger_entries')
          .select('*')
          .order('booked_at', { ascending: false }),
        supabase
          .from('official_documents')
          .select('*')
          .order('issued_at', { ascending: false, nullsFirst: false }),
        supabase.from('notifications').select('*').order('created_at', { ascending: false }),
        supabase
          .from('kyc_applications')
          .select('*,kyc_review_checklists(*)')
          .order('submitted_at', { ascending: false }),
        supabase.from('audit_events').select('*').order('created_at', { ascending: false }).limit(100),
        supabase
          .from('transfer_control_fees' as any)
          .select('*')
          .order('currency')
          .then(
            (res: any) => res,
            () => ({ data: null, error: null }),
          ),
      ]);

      const firstError = [
        roleResult,
        profileResult,
        positionsResult,
        transfersResult,
        loansResult,
        loanSettingsResult,
        ledgerResult,
        officialDocumentsResult,
        notificationResult,
        kycResult,
        auditResult,
      ].find((result) => result.error)?.error;
      if (firstError) throw firstError;

      setLoanProductSettings(
        ((loanSettingsResult.data ?? []) as LoanProductSettingsRow[]).map((settings) => ({
          currency: settings.currency,
          minimumAmount: fromMinorUnits(settings.minimum_amount_minor, settings.currency),
          maximumAmount: fromMinorUnits(settings.maximum_amount_minor, settings.currency),
          minimumDurationMonths: settings.minimum_duration_months,
          maximumDurationMonths: settings.maximum_duration_months,
          durationStepMonths: settings.duration_step_months,
          fixedAnnualRate: Number(settings.fixed_annual_rate),
          referencePrefix: settings.reference_prefix,
          isActive: settings.is_active,
          updatedAt: settings.updated_at,
          updatedBy: settings.updated_by ?? undefined,
        })),
      );

      if (
        (transferFeesResult as any)?.data &&
        Array.isArray((transferFeesResult as any).data) &&
        (transferFeesResult as any).data.length > 0
      ) {
        setTransferControlFees(
          ((transferFeesResult as any).data as any[]).map((row) => ({
            currency: row.currency,
            dualReviewFee: fromMinorUnits(row.dual_review_fee_minor, row.currency),
            dualReviewFeeMode: row.dual_review_fee_mode ?? 'fixed',
            dualReviewFeeRate: Number(row.dual_review_fee_rate ?? 1.0),
            escalationFee: fromMinorUnits(row.escalation_fee_minor, row.currency),
            escalationFeeMode: row.escalation_fee_mode ?? 'fixed',
            escalationFeeRate: Number(row.escalation_fee_rate ?? 1.5),
            complianceFee: fromMinorUnits(row.compliance_fee_minor, row.currency),
            complianceFeeMode: row.compliance_fee_mode ?? 'fixed',
            complianceFeeRate: Number(row.compliance_fee_rate ?? 2.0),
            finalAuthorizationFee: fromMinorUnits(
              row.final_authorization_fee_minor,
              row.currency,
            ),
            finalAuthorizationFeeMode: row.final_authorization_fee_mode ?? 'fixed',
            finalAuthorizationFeeRate: Number(row.final_authorization_fee_rate ?? 2.5),
            updatedAt: row.updated_at,
            updatedBy: row.updated_by ?? undefined,
          })),
        );
      }

      const isAdmin = roleResult.data === 'admin';
      setRole(isAdmin ? 'admin' : 'user');
      if (isAdmin) {
        const { data: configurationRows, error: configurationError } =
          await supabase.rpc('get_account_number_configuration');
        if (configurationError) throw configurationError;
        const configuration = Array.isArray(configurationRows)
          ? configurationRows[0]
          : configurationRows;
        setAccountNumberConfiguration(
          configuration
            ? {
                prefix: configuration.prefix,
                prefixLength: configuration.prefix_length,
                capacity: configuration.capacity,
                updatedAt: configuration.updated_at,
              }
            : null,
        );
      } else {
        setAccountNumberConfiguration(null);
      }

      const ownProfile = (profileResult.data ?? []).find(
        (profile) => profile.user_id === user.id,
      );
      setCurrentUserDisplayName(
        ownProfile?.display_name?.trim() || ownProfile?.email?.split('@')[0] || null,
      );
      if (!isAdmin && isSupportedCurrency(ownProfile?.base_currency)) {
        setBaseCurrency(ownProfile.base_currency);
      }
      if (!isAdmin && isSupportedCurrency(ownProfile?.preferred_currency)) {
        setCurrency(ownProfile.preferred_currency);
      }
      if (isAdmin) {
        applyLanguage('fr', 'profile', false);
      } else if (isSupportedLanguage(ownProfile?.preferred_language)) {
        applyLanguage(ownProfile.preferred_language, 'profile', false);
      }

      const profileEmails = new Map(
        (profileResult.data ?? []).map((profile) => [profile.user_id, profile.email]),
      );
      const profileNames = new Map(
        (profileResult.data ?? []).map((profile) => [
          profile.user_id,
          profile.display_name || profile.email,
        ]),
      );

      const positionRows = (positionsResult.data ?? []) as PositionRow[];
      const currentAccountIds = new Set(positionRows.map((position) => position.id));
      setAccounts(
        positionRows.map((position) => ({
          id: position.id,
          ownerId: position.owner_id,
          name: position.label,
          iban: position.iban ?? undefined,
          accountNumber: position.account_number ?? undefined,
          bic: position.bic ?? undefined,
          accountHolderName:
            position.account_holder_name ??
            profileNames.get(position.owner_id) ??
            undefined,
          institutionName: position.institution_name ?? undefined,
          branchName: position.branch_name ?? undefined,
          branchCode: position.branch_code ?? undefined,
          accountStatus: position.account_status,
          openedAt: position.opened_at ?? undefined,
          isDemo: position.is_demo,
          balance: fromMinorUnits(position.amount_minor, position.currency),
          availableBalance: fromMinorUnits(
            position.amount_minor - position.reserved_minor,
            position.currency,
          ),
          currency: position.currency as Currency,
          type: 'courant',
          accountType: position.account_type,
          positionKind: position.position_kind,
          asOf: position.as_of,
        })),
      );

      const transferRows = (transfersResult.data ?? []) as TransferRow[];
      const mappedTransfers = transferRows.map((transfer): PendingTransfer => {
        const checks = mapReviewChecks(transfer.transfer_review_checks);
        const completed = Object.values(checks).filter((status) => status === 'termine').length;
        const details = transfer.beneficiary_details ?? {};
        return {
          id: transfer.id,
          ownerId: transfer.owner_id,
          sourceAccountId: transfer.source_position_id,
          recipientName: transfer.recipient_name,
          recipientAccount: transfer.recipient_account_masked,
          transferType: transfer.transfer_type,
          amount: fromMinorUnits(transfer.amount_minor, transfer.currency),
          currency: transfer.currency,
          convertedAmount: fromMinorUnits(
            transfer.target_amount_minor,
            transfer.target_currency,
          ),
          targetCurrency: transfer.target_currency,
          date: transfer.submitted_at,
          status: mapTransferStatus(transfer.status),
          workflowStatus: transfer.status,
          complianceStep: Math.min(4, completed + 1),
          complianceProgress: transferProgress(transfer.status, completed),
          complianceChecks: checks,
          details: {
            institutionNumber: details.institutionNumber,
            transitNumber: details.transitNumber,
            routingNumber: details.routingNumber,
            interacEmail: details.interacEmail,
            bicSwift: details.bicSwift,
            clearingNumber: details.clearingNumber,
            motive: details.motive,
          },
        };
      });
      setPendingTransfers(mappedTransfers);

      const loanRows = (loansResult.data ?? []) as LoanRow[];
      const positionById = new Map(positionRows.map((position) => [position.id, position]));
      const mappedLoans = loanRows.map((loan): LoanApplication => {
        const checks = mapReviewChecks(loan.loan_review_checks);
        const completed = Object.values(checks).filter(
          (status) => status === 'termine',
        ).length;
        const amount = fromMinorUnits(loan.requested_amount_minor, loan.currency);
        const creditedPosition = loan.credited_position_id
          ? positionById.get(loan.credited_position_id)
          : undefined;
        return {
          id: loan.id,
          ownerId: loan.owner_id,
          reference: loan.reference,
          clientName: profileEmails.get(loan.owner_id)?.split('@')[0] ?? 'Utilisateur',
          clientEmail: profileEmails.get(loan.owner_id) ?? '',
          requestDate: loan.submitted_at,
          requestedAmount: amount,
          approvedAmount:
            loan.status === 'approved_for_external_funding' ||
            loan.status === 'external_funding_recorded' ||
            loan.status === 'external_settlement_confirmed'
              ? amount
              : 0,
          repaidAmount: 0,
          currency: loan.currency,
          status: mapLoanStatus(loan.status),
          workflowStatus: loan.status,
          currentStep: Math.min(6, completed + 1),
          complianceProgress: loanProgress(loan.status, completed),
          nextDueDate: undefined,
          disbursementAccount: creditedPosition?.account_number ?? undefined,
          creditedPositionId: loan.credited_position_id ?? undefined,
          durationMonths: loan.duration_months,
          monthlyPayment: loan.indicative_monthly_payment_minor
            ? fromMinorUnits(loan.indicative_monthly_payment_minor, loan.currency)
            : 0,
          motive: loan.motive,
          motiveCode: normalizeLoanMotiveCode(loan.motive_code ?? loan.motive),
          complianceChecks: checks,
        };
      });
      setLoans(mappedLoans);

      setTransactions(
        ((ledgerResult.data ?? []) as LedgerEntryRow[])
          .filter((entry) => currentAccountIds.has(entry.account_id))
          .map((entry) => ({
            id: entry.id,
            accountId: entry.account_id,
            title: entry.description,
            entryKind: entry.entry_kind,
            metadata: entry.metadata ?? {},
            date: entry.value_date ?? entry.booked_at,
            amount: fromMinorUnits(entry.amount_minor, entry.currency),
            currency: entry.currency,
            balanceAfter: fromMinorUnits(entry.balance_after_minor, entry.currency),
            reference: entry.internal_reference,
            type: entry.amount_minor < 0 ? ('debit' as const) : ('credit' as const),
            category:
              entry.entry_kind === 'transfer_debit'
                ? ('transfer' as const)
                : ('other' as const),
          })),
      );

      setOfficialDocuments(
        ((officialDocumentsResult.data ?? []) as OfficialDocumentRow[]).map(
          (document) => ({
            id: document.id,
            ownerId: document.owner_id,
            accountId: document.account_id ?? undefined,
            transferId: document.transfer_id ?? undefined,
            loanId: document.loan_id ?? undefined,
            documentNumber: document.document_number,
            documentType: document.document_type,
            title: document.title,
            language: document.language,
            periodStart: document.period_start ?? undefined,
            periodEnd: document.period_end ?? undefined,
            version: document.version,
            localizationRevision: document.localization_revision ?? 1,
            supersedesDocumentId: document.supersedes_document_id ?? undefined,
            status: document.status,
            contentHash: document.content_hash ?? undefined,
            storagePath: document.storage_path ?? undefined,
            issuedAt: document.issued_at ?? undefined,
            revokedAt: document.revoked_at ?? undefined,
            isDemo: document.is_demo,
          }),
        ),
      );

      setNotifications(
        (notificationResult.data ?? []).map((notification) => ({
          id: notification.id,
          title: notification.title,
          message: notification.message,
          timestamp: notification.created_at,
          createdAt: notification.created_at,
          messageKey: parseNotificationMessageKey(notification.message_key),
          messageParams: parseNotificationMessageParams(notification.message_params),
          read: Boolean(notification.read_at),
          type: parseNotificationType(notification.notification_type),
          actionPath: notification.action_path ?? undefined,
        })),
      );

      const kycRows = (kycResult.data ?? []) as KycRow[];
      const mappedKyc = await Promise.all(
        kycRows.map(async (kyc): Promise<KYCApplication> => {
          const documentPaths = parseKycDocumentPaths(
            kyc.document_object_paths,
          );
          const pathEntries = Object.entries(documentPaths);
          const signedEntries = await Promise.all(
            pathEntries.map(async ([key, path]) => {
              const { data } = await supabase.storage
                .from('kyc-evidence')
                .createSignedUrl(path, 300);
              return [key, data?.signedUrl ?? ''] as const;
            }),
          );
          const signed = Object.fromEntries(signedEntries);
          return {
            id: kyc.id,
            ownerId: kyc.owner_id,
            email: profileEmails.get(kyc.owner_id) ?? '',
            firstName: kyc.first_name,
            lastName: kyc.last_name,
            dateOfBirth: kyc.date_of_birth,
            placeOfBirth: kyc.place_of_birth,
            nationality: kyc.nationality,
            address: parseKycAddress(kyc.address),
            profile: {
              occupation: kyc.occupation,
              incomeRange: kyc.income_range,
              fatca: kyc.fatca,
              pep: kyc.pep,
            },
            documents: {
              idFrontUrl: signed.id_front ?? '',
              idBackUrl: signed.id_back ?? '',
              selfieUrl: signed.selfie ?? '',
              selfieProvided: Boolean(documentPaths.selfie),
              proofOfAddressUrl: signed.proof_of_address ?? '',
            },
            documentType: parseKycDocumentType(kyc.document_type),
            documentNumber: kyc.document_number ?? undefined,
            issuingCountry: kyc.issuing_country ?? undefined,
            documentExpiresOn: kyc.document_expires_on ?? undefined,
            status: mapKycStatus(kyc.status),
            workflowStatus: parseKycWorkflowStatus(kyc.status),
            submittedAt: kyc.submitted_at,
            rejectionReason: kyc.review_note ?? undefined,
            correctionReasonCode: kyc.correction_reason_code ?? undefined,
            correctionDueAt: kyc.correction_due_at
              ? kyc.correction_due_at
              : undefined,
            requestedItems: kyc.requested_items ?? [],
            checklist: kyc.kyc_review_checklists
              ? {
                  documentQuality: parseKycReviewState(
                    kyc.kyc_review_checklists.document_quality,
                  ),
                  dataConsistency: parseKycReviewState(
                    kyc.kyc_review_checklists.data_consistency,
                  ),
                  selfieMatch: parseKycSelfieReviewState(
                    kyc.kyc_review_checklists.selfie_match,
                  ),
                  adulthood: parseKycReviewState(
                    kyc.kyc_review_checklists.adulthood,
                  ),
                  fatca: parseKycReviewState(kyc.kyc_review_checklists.fatca),
                  pep: parseKycReviewState(kyc.kyc_review_checklists.pep),
                  internalComments:
                    kyc.kyc_review_checklists.internal_comments ?? '',
                }
              : undefined,
          };
        }),
      );
      setKycApplications(mappedKyc);

      setActivityLogs(
        (auditResult.data ?? []).map((event) => ({
          id: String(event.id),
          timestamp: friendlyAdminDate(event.created_at),
          description: `${event.action} — ${event.entity_type}`,
          type: event.action.includes('failed') || event.action.includes('reject')
            ? 'alert'
            : 'info',
        })),
      );
    } catch {
      const message = 'Chargement des données impossible. Veuillez réessayer.';
      setLastError(message);
      clearBusinessData();
    } finally {
      setIsLoading(false);
    }
  }, [applyLanguage, clearBusinessData]);

  useEffect(() => {
    document.documentElement.lang = initialLanguage;

    if (
      languageSourceRef.current === 'profile' ||
      languageSourceRef.current === 'explicit'
    ) {
      return;
    }

    const detectedLanguage = resolveSupportedLanguage(navigator.languages);
    if (!detectedLanguage) return;

    if (detectedLanguage === initialLanguage) {
      languageSourceRef.current = 'detected';
      writeLanguageCookies(detectedLanguage, 'detected');
      return;
    }

    const detectionTimer = window.setTimeout(() => {
      applyLanguage(detectedLanguage, 'detected');
    }, 0);

    return () => window.clearTimeout(detectionTimer);
  }, [applyLanguage, initialLanguage]);

  useEffect(() => {
    const initialRefresh = window.setTimeout(() => {
      void refreshData();
    }, 0);
    if (!isPublicSupabaseConfigured()) {
      return () => window.clearTimeout(initialRefresh);
    }

    const supabase = createClient();
    const { data } = supabase.auth.onAuthStateChange((event) => {
      if (event === 'SIGNED_OUT') {
        clearBusinessData();
        setIsLoading(false);
        const shouldRedirect = authFailureRedirect(
          window.location.pathname,
          window.location.search,
        );
        // Give the protected support shell a synchronous teardown signal before
        // a store-level redirect can unload it. Public routes have no listener.
        window.dispatchEvent(new Event(SUPPORT_SIGNED_OUT_EVENT));
        if (shouldRedirect) {
          window.setTimeout(() => {
            if (
              authFailureRedirect(window.location.pathname, window.location.search)
            ) {
              window.location.replace('/login');
            }
          }, 0);
        }
        return;
      }
      window.setTimeout(() => {
        void refreshData();
      }, 0);
    });
    return () => {
      window.clearTimeout(initialRefresh);
      data.subscription.unsubscribe();
    };
  }, [clearBusinessData, refreshData]);

  useEffect(() => {
    void fetchLiveCurrencyRates().then(setRates);
  }, []);

  const executeAndRefresh = useCallback(
    async (
      operation: () => PromiseLike<{ error: { message: string } | null }>,
    ) => {
      setLastError(null);
      const { error } = await operation();
      if (error) {
        const message = 'L’opération n’a pas pu être effectuée. Vérifiez les informations puis réessayez.';
        setLastError(message);
        throw new Error(message);
      }
      await refreshData();
      void dispatchTransactionalEmails();
    },
    [refreshData],
  );

  const addTransfer: AppState['addTransfer'] = async (transfer) => {
    const account = accounts.find((candidate) => candidate.id === transfer.sourceAccountId);
    if (!account) throw new Error('Position source introuvable.');
    const idempotencyKey = crypto.randomUUID();
    const rate =
      transfer.amount > 0 ? transfer.convertedAmount / transfer.amount : 0;

    await executeAndRefresh(() =>
      createClient().rpc(
        'submit_transfer_intent',
        rpcArgsWithKnownNulls<'submit_transfer_intent'>({
          p_source_position_id: account.id,
          p_recipient_name: transfer.recipientName.trim(),
          p_recipient_account_masked: maskFinancialIdentifier(
            transfer.recipientAccount,
          ),
          p_beneficiary_details: {
            recipientAccount: transfer.recipientAccount,
            ...transfer.details,
          },
          p_transfer_type: transfer.transferType,
          p_amount_minor: toMinorUnits(transfer.amount, account.currency),
          p_currency: account.currency,
          p_target_amount_minor: toMinorUnits(
            transfer.convertedAmount,
            transfer.targetCurrency,
          ),
          p_target_currency: transfer.targetCurrency,
          p_quote_rate: rate,
          p_quote_as_of: rates.updatedAt,
          p_motive: transfer.details?.motive ?? null,
          p_idempotency_key: idempotencyKey,
        }),
      ),
    );
  };

  const addLoanApplication: AppState['addLoanApplication'] = async (loan) => {
    setLastError(null);
    const supabase = createClient();
    const idempotencyKey = crypto.randomUUID();
    try {
      const {
        data: { user },
        error: userError,
      } = await supabase.auth.getUser();
      if (userError || !user) throw userError ?? new Error('Session expirée.');

      const { data, error } = await supabase.rpc('submit_loan_application', {
        p_requested_amount_minor: toMinorUnits(loan.requestedAmount, loan.currency),
        p_currency: loan.currency,
        p_duration_months: loan.durationMonths,
        p_motive_code: loan.motiveCode,
        p_document_object_paths: [],
        p_idempotency_key: idempotencyKey,
      });
      if (error) throw error;
      const submittedLoan = Array.isArray(data) ? data[0] : data;
      const reference =
        submittedLoan &&
        typeof submittedLoan === 'object' &&
        'reference' in submittedLoan &&
        typeof submittedLoan.reference === 'string'
          ? submittedLoan.reference
          : 'Référence générée';
      await refreshData();
      void dispatchTransactionalEmails();
      return reference;
    } catch {
      const message = 'La demande n’a pas pu être déposée.';
      setLastError(message);
      throw new Error(message);
    }
  };

  const approveTransfer: AppState['approveTransfer'] = async (transferId, note) => {
    await executeAndRefresh(() =>
      createClient().rpc('branch_manager_approve_transfer', {
        p_transfer_id: transferId,
        p_note: note?.trim() || undefined,
      }),
    );
  };

  const reviewTransferCheck: AppState['reviewTransferCheck'] = async (
    transferId,
    checkKind,
    note,
  ) => {
    await executeAndRefresh(() =>
      createClient().rpc('branch_manager_review_transfer_check', {
        p_transfer_id: transferId,
        p_check_kind: checkKind,
        p_note: note?.trim() || undefined,
      }),
    );
  };

  const finalizeTransfer: AppState['finalizeTransfer'] = async (transferId, note) => {
    await executeAndRefresh(() =>
      createClient().rpc('branch_manager_finalize_transfer', {
        p_transfer_id: transferId,
        p_note: note?.trim() || undefined,
      }),
    );
  };

  const rejectTransfer: AppState['rejectTransfer'] = async (transferId, reason) => {
    if (!reason.trim()) throw new Error('Le motif de refus est obligatoire.');
    await executeAndRefresh(() =>
      createClient().rpc('branch_manager_reject_transfer', {
        p_transfer_id: transferId,
        p_reason: reason.trim(),
      }),
    );
  };

  const approveLoan: AppState['approveLoan'] = async (loanId, note) => {
    await executeAndRefresh(() =>
      createClient().rpc('branch_manager_approve_loan', {
        p_loan_id: loanId,
        p_note: note?.trim() || undefined,
      }),
    );
  };

  const disburseLoan: AppState['disburseLoan'] = async (
    loanId,
    destinationPositionId,
    note,
  ) => {
    if (!destinationPositionId) {
      throw new Error('Sélectionnez le compte courant à créditer.');
    }
    if (!note.trim()) throw new Error('La note de décaissement est obligatoire.');
    await executeAndRefresh(() =>
      createClient().rpc('branch_manager_disburse_loan', {
        p_loan_id: loanId,
        p_destination_position_id: destinationPositionId,
        p_note: note.trim(),
      }),
    );
  };

  const rejectLoan: AppState['rejectLoan'] = async (loanId, reason) => {
    await executeAndRefresh(() =>
      createClient().rpc('branch_manager_reject_loan', {
        p_loan_id: loanId,
        p_reason: reason,
      }),
    );
  };

  const markNotificationAsRead: AppState['markNotificationAsRead'] = async (
    notificationId,
  ) => {
    await executeAndRefresh(() =>
      createClient().rpc('mark_notification_read', {
        p_notification_id: notificationId,
      }),
    );
  };

  const beginKYCReview: AppState['beginKYCReview'] = async (kycId) => {
    await executeAndRefresh(() =>
      createClient().rpc('begin_kyc_review', { p_kyc_id: kycId }),
    );
  };

  const updateKYCChecklist: AppState['updateKYCChecklist'] = async (
    kycId,
    checklist,
  ) => {
    await executeAndRefresh(() =>
      createClient().rpc('update_kyc_review_checklist', {
        p_kyc_id: kycId,
        p_document_quality: checklist.documentQuality,
        p_data_consistency: checklist.dataConsistency,
        p_selfie_match: checklist.selfieMatch,
        p_adulthood: checklist.adulthood,
        p_fatca: checklist.fatca,
        p_pep: checklist.pep,
        p_internal_comments: checklist.internalComments,
      }),
    );
  };

  const requestKYCInformation: AppState['requestKYCInformation'] = async (
    kycId,
    requestedItems,
    reasonCode,
    note,
    dueAt,
  ) => {
    await executeAndRefresh(() =>
      createClient().rpc(
        'request_kyc_information',
        rpcArgsWithKnownNulls<'request_kyc_information'>({
          p_kyc_id: kycId,
          p_requested_items: requestedItems,
          p_reason_code: reasonCode,
          p_note: note,
          p_due_at: dueAt || null,
        }),
      ),
    );
  };

  const approveKYCApplication: AppState['approveKYCApplication'] = async (
    kycId,
    note,
  ) => {
    await executeAndRefresh(() =>
      createClient().rpc(
        'decide_kyc_application',
        rpcArgsWithKnownNulls<'decide_kyc_application'>({
          p_kyc_id: kycId,
          p_decision: 'approved',
          p_reason_code: null,
          p_note: note?.trim() || 'Identité approuvée après contrôle humain.',
        }),
      ),
    );
  };

  const rejectKYCApplication: AppState['rejectKYCApplication'] = async (
    kycId,
    reason,
    reasonCode = 'other',
  ) => {
    await executeAndRefresh(() =>
      createClient().rpc('decide_kyc_application', {
        p_kyc_id: kycId,
        p_decision: 'rejected',
        p_reason_code: reasonCode,
        p_note: reason,
      }),
    );
  };

  const updateAccountBalance: AppState['updateAccountBalance'] = async (
    accountId,
    newAmount,
    reason = 'Mise à jour du solde après traitement interne par le personnel bancaire.',
  ) => {
    const account = accounts.find((candidate) => candidate.id === accountId);
    if (!account) throw new Error('Compte introuvable.');
    if (!Number.isFinite(newAmount) || newAmount < 0) {
      throw new Error('Le solde ne peut pas être négatif.');
    }
    const factor = 10 ** currencyExponent(account.currency);
    const targetMinor = Math.round(newAmount * factor);
    if (targetMinor === Math.round(account.balance * factor)) return;

    await executeAndRefresh(() =>
      createClient().rpc('branch_manager_adjust_balance', {
        p_account_id: accountId,
        p_target_amount_minor: targetMinor,
        p_value_date: new Date().toISOString(),
        p_reason: reason,
        p_idempotency_key: crypto.randomUUID(),
      }),
    );
  };

  const declareBankAccount: AppState['declareBankAccount'] = async (account) => {
    if (!account.iban.trim() || !account.bic.trim()) {
      throw new Error('L’IBAN et le BIC sont obligatoires.');
    }
    if (!Number.isFinite(account.openingBalance) || account.openingBalance < 0) {
      throw new Error('Le solde d’ouverture doit être positif ou nul.');
    }

    await executeAndRefresh(() =>
      createClient().rpc('branch_manager_declare_account', {
        p_owner_id: account.ownerId,
        p_label: account.label.trim(),
        p_account_type: 'current',
        p_currency: account.currency,
        p_iban: account.iban.trim(),
        p_bic: account.bic.trim(),
        p_account_holder_name: account.accountHolderName.trim(),
        p_institution_name: account.institutionName.trim(),
        p_branch_name: account.branchName.trim(),
        p_branch_code: account.branchCode.trim(),
        p_opening_balance_minor:
          account.openingBalance === 0
            ? 0
            : toMinorUnits(account.openingBalance, account.currency),
        p_opened_at: account.openedAt,
        p_is_demo: Boolean(account.isDemo),
        p_reason: account.reason.trim(),
        p_idempotency_key: crypto.randomUUID(),
      }),
    );
  };

  const updateAccountNumberPrefix: AppState['updateAccountNumberPrefix'] = async (
    prefix,
  ) => {
    const normalizedPrefix = prefix.trim();
    if (!/^\d{5,9}$/.test(normalizedPrefix)) {
      throw new Error('Le préfixe doit contenir entre 5 et 9 chiffres.');
    }

    const { data, error } = await createClient().rpc(
      'set_account_number_prefix',
      { p_prefix: normalizedPrefix },
    );
    if (error) throw error;
    const configuration = Array.isArray(data) ? data[0] : data;
    if (!configuration) {
      throw new Error('La configuration enregistrée est introuvable.');
    }
    setAccountNumberConfiguration({
      prefix: configuration.prefix,
      prefixLength: configuration.prefix_length,
      capacity: configuration.capacity,
      updatedAt: configuration.updated_at,
    });
  };

  const updateLoanProductSettings: AppState['updateLoanProductSettings'] = async (
    settings,
  ) => {
    if (
      !Number.isFinite(settings.minimumAmount) ||
      !Number.isFinite(settings.maximumAmount) ||
      settings.minimumAmount <= 0 ||
      settings.minimumAmount >= settings.maximumAmount
    ) {
      throw new Error('Les montants minimum et maximum sont invalides.');
    }
    if (
      !Number.isInteger(settings.minimumDurationMonths) ||
      !Number.isInteger(settings.maximumDurationMonths) ||
      !Number.isInteger(settings.durationStepMonths) ||
      settings.minimumDurationMonths <= 0 ||
      settings.maximumDurationMonths < settings.minimumDurationMonths ||
      settings.durationStepMonths <= 0 ||
      (settings.maximumDurationMonths - settings.minimumDurationMonths) %
        settings.durationStepMonths !==
        0
    ) {
      throw new Error('Les durées et leur pas sont invalides.');
    }
    if (
      !Number.isFinite(settings.fixedAnnualRate) ||
      settings.fixedAnnualRate < 0 ||
      settings.fixedAnnualRate > 1
    ) {
      throw new Error('Le TAEG doit être compris entre 0 % et 100 %.');
    }

    const normalizedPrefix = settings.referencePrefix.trim();
    if (!/^[A-Za-z0-9_-]{1,24}$/.test(normalizedPrefix)) {
      throw new Error(
        'Le préfixe doit contenir 1 à 24 lettres, chiffres, tirets ou tirets bas.',
      );
    }

    setLastError(null);
    const { error } = await createClient().rpc('update_loan_product_settings', {
      p_currency: settings.currency,
      p_minimum_amount_minor: toMinorUnits(settings.minimumAmount, settings.currency),
      p_maximum_amount_minor: toMinorUnits(settings.maximumAmount, settings.currency),
      p_minimum_duration_months: settings.minimumDurationMonths,
      p_maximum_duration_months: settings.maximumDurationMonths,
      p_duration_step_months: settings.durationStepMonths,
      p_fixed_annual_rate: settings.fixedAnnualRate,
      p_reference_prefix: normalizedPrefix,
      p_is_active: settings.isActive,
    });
    if (error) {
      const message = 'La configuration du prêt n’a pas pu être enregistrée.';
      setLastError(message);
      throw new Error(message);
    }
    await refreshData();
  };


  const updateTransferControlFees: AppState['updateTransferControlFees'] = async (
    fees,
  ) => {
    if (
      !Number.isFinite(fees.dualReviewFee) || fees.dualReviewFee < 0 ||
      !Number.isFinite(fees.escalationFee) || fees.escalationFee < 0 ||
      !Number.isFinite(fees.complianceFee) || fees.complianceFee < 0 ||
      !Number.isFinite(fees.finalAuthorizationFee) || fees.finalAuthorizationFee < 0
    ) {
      throw new Error('Les montants des frais doivent être des nombres positifs ou nuls.');
    }

    setLastError(null);
    const { error } = await (createClient() as any).rpc('update_transfer_control_fees', {
      p_currency: fees.currency,
      p_dual_review_fee_minor: toMinorUnits(fees.dualReviewFee, fees.currency),
      p_escalation_fee_minor: toMinorUnits(fees.escalationFee, fees.currency),
      p_compliance_fee_minor: toMinorUnits(fees.complianceFee, fees.currency),
      p_final_authorization_fee_minor: toMinorUnits(
        fees.finalAuthorizationFee,
        fees.currency,
      ),
      p_dual_review_fee_mode: fees.dualReviewFeeMode ?? 'fixed',
      p_dual_review_fee_rate: fees.dualReviewFeeRate ?? 1.0,
      p_escalation_fee_mode: fees.escalationFeeMode ?? 'fixed',
      p_escalation_fee_rate: fees.escalationFeeRate ?? 1.5,
      p_compliance_fee_mode: fees.complianceFeeMode ?? 'fixed',
      p_compliance_fee_rate: fees.complianceFeeRate ?? 2.0,
      p_final_authorization_fee_mode: fees.finalAuthorizationFeeMode ?? 'fixed',
      p_final_authorization_fee_rate: fees.finalAuthorizationFeeRate ?? 2.5,
    });

    if (error) {
      setTransferControlFees((prev) =>
        prev.map((item) =>
          item.currency === fees.currency
            ? { ...item, ...fees, updatedAt: new Date().toISOString() }
            : item,
        ),
      );
    } else {
      await refreshData();
    }
  };

  const issueOfficialDocument: AppState['issueOfficialDocument'] = async (
    document,
  ) => {
    const idempotencyKey = crypto.randomUUID();
    const body = JSON.stringify(document);
    const issue = () =>
      fetch('/api/official-documents', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Idempotency-Key': idempotencyKey,
        },
        body,
      });
    let response: Response;
    try {
      response = await issue();
    } catch {
      response = await issue();
    }
    const payload = (await response.json()) as { error?: string };
    if (!response.ok) {
      throw new Error(payload.error ?? 'Émission du document impossible.');
    }
    await refreshData();
  };

  const value: AppState = {
    language,
    setLanguage,
    role,
    currentUserDisplayName,
    activeTab,
    setActiveTab,
    baseCurrency,
    currency,
    setCurrency,
    rates,
    setRates,
    isMaskedBalance,
    toggleMaskBalance: () => setIsMaskedBalance((masked) => !masked),
    isLoading,
    lastError,
    refreshData,
    accountNumberConfiguration,
    updateAccountNumberPrefix,
    loanProductSettings,
    updateLoanProductSettings,
    transferControlFees,
    updateTransferControlFees,
    accounts,
    transactions,
    officialDocuments,
    pendingTransfers,
    loans,
    notifications,
    activityLogs,
    kycApplications,
    isTransferModalOpen,
    setIsTransferModalOpen,
    isLoanModalOpen,
    setIsLoanModalOpen,
    isNotificationsDrawerOpen,
    setIsNotificationsDrawerOpen,
    isContactModalOpen,
    setIsContactModalOpen,
    isStatementsModalOpen,
    setIsStatementsModalOpen,
    selectedLoanForReview,
    setSelectedLoanForReview,
    addTransfer,
    addLoanApplication,
    approveTransfer,
    reviewTransferCheck,
    finalizeTransfer,
    rejectTransfer,
    approveLoan,
    disburseLoan,
    rejectLoan,
    markNotificationAsRead,
    beginKYCReview,
    updateKYCChecklist,
    requestKYCInformation,
    approveKYCApplication,
    rejectKYCApplication,
    updateAccountBalance,
    declareBankAccount,
    issueOfficialDocument,
  };

  return <AppContext.Provider value={value}>{children}</AppContext.Provider>;
}

export function useAppStore() {
  const context = useContext(AppContext);
  if (!context) throw new Error('useAppStore doit être utilisé dans AppProvider.');
  return context;
}
