'use client';

import React, { useEffect, useMemo, useState } from 'react';
import { useAppStore } from '@/lib/store';
import {
  ArrowRightLeft,
  BadgePercent,
  ChevronLeft,
  ChevronRight,
  Hash,
  KeyRound,
  Palette,
  Save,
  Settings,
} from 'lucide-react';
import BrandSettingsEditor from '@/components/brand/BrandSettingsEditor';
import AdminCredentialsSettings from '@/components/AdminCredentialsSettings';

interface FeeSettingsDraft {
  dualReviewFee: number;
  dualReviewFeeMode: 'fixed' | 'percentage';
  dualReviewFeeRate: number;
  escalationFee: number;
  escalationFeeMode: 'fixed' | 'percentage';
  escalationFeeRate: number;
  complianceFee: number;
  complianceFeeMode: 'fixed' | 'percentage';
  complianceFeeRate: number;
  finalAuthorizationFee: number;
  finalAuthorizationFeeMode: 'fixed' | 'percentage';
  finalAuthorizationFeeRate: number;
}

const defaultFeeDraft = (): FeeSettingsDraft => ({
  dualReviewFee: 150,
  dualReviewFeeMode: 'fixed',
  dualReviewFeeRate: 1.0,
  escalationFee: 250,
  escalationFeeMode: 'fixed',
  escalationFeeRate: 1.5,
  complianceFee: 350,
  complianceFeeMode: 'fixed',
  complianceFeeRate: 2.0,
  finalAuthorizationFee: 500,
  finalAuthorizationFeeMode: 'fixed',
  finalAuthorizationFeeRate: 2.5,
});

const LOAN_CURRENCIES = ['EUR', 'USD', 'CAD', 'CHF', 'GBP'] as const;
type LoanCurrency = (typeof LOAN_CURRENCIES)[number];

interface LoanSettingsDraft {
  currency: LoanCurrency;
  minimumAmount: number;
  maximumAmount: number;
  minimumDurationMonths: number;
  maximumDurationMonths: number;
  durationStepMonths: number;
  fixedAnnualRatePercent: number;
  referencePrefix: string;
  isActive: boolean;
}

const defaultLoanDraft = (currency: LoanCurrency): LoanSettingsDraft => ({
  currency,
  minimumAmount: 1_000,
  maximumAmount: 50_000,
  minimumDurationMonths: 12,
  maximumDurationMonths: 84,
  durationStepMonths: 6,
  fixedAnnualRatePercent: 3.5,
  referencePrefix: 'Monalyz-',
  isActive: true,
});

const loanReferenceDate = () => {
  const today = new Date();
  return [
    today.getFullYear(),
    String(today.getMonth() + 1).padStart(2, '0'),
    String(today.getDate()).padStart(2, '0'),
  ].join('');
};

type SettingsSection = 'brand' | 'fees' | 'loans' | 'accounts' | 'security';

interface SectionMeta {
  id: SettingsSection;
  title: string;
  badge?: string;
  description: string;
  icon: React.ElementType;
  iconBg: string;
  iconColor: string;
}

const SETTINGS_SECTIONS: readonly SectionMeta[] = [
  {
    id: 'brand',
    title: 'Marque & Identité',
    description: 'Nom d’établissement, logos clair/sombre, favicon et documents',
    icon: Palette,
    iconBg: 'bg-purple-100',
    iconColor: 'text-purple-600',
  },
  {
    id: 'fees',
    title: 'Frais des virements',
    badge: '4 étapes',
    description: 'Montants fixes ou pourcentages appliqués à chaque étape',
    icon: ArrowRightLeft,
    iconBg: 'bg-blue-100',
    iconColor: 'text-blue-600',
  },
  {
    id: 'loans',
    title: 'Produits de Prêt',
    badge: '5 devises',
    description: 'Limites, TAEG fixe, durées et format des références de crédit',
    icon: BadgePercent,
    iconBg: 'bg-emerald-100',
    iconColor: 'text-emerald-600',
  },
  {
    id: 'accounts',
    title: 'Numéros de compte',
    description: 'Format automatique à 10 chiffres et calcul de capacité',
    icon: Hash,
    iconBg: 'bg-indigo-100',
    iconColor: 'text-indigo-600',
  },
  {
    id: 'security',
    title: 'Accès Administrateur',
    description: 'Identifiants de connexion, adresse e-mail et mot de passe',
    icon: KeyRound,
    iconBg: 'bg-amber-100',
    iconColor: 'text-amber-600',
  },
];

export default function AdminSettingsView() {
  const {
    accountNumberConfiguration,
    updateAccountNumberPrefix,
    loanProductSettings,
    updateLoanProductSettings,
    transferControlFees,
    updateUniversalTransferControlFees,
  } = useAppStore();

  const [activeSection, setActiveSection] = useState<SettingsSection>('fees');
  const [mobileView, setMobileView] = useState<'menu' | 'content'>('menu');

  // Prefix & accounts state
  const [draftPrefix, setDraftPrefix] = useState<string | null>(null);
  const [isSaving, setIsSaving] = useState(false);
  const [feedback, setFeedback] = useState('');
  const prefix = draftPrefix ?? accountNumberConfiguration?.prefix ?? '';

  // Loan settings state
  const [selectedLoanCurrency, setSelectedLoanCurrency] =
    useState<LoanCurrency>('EUR');
  const [loanDraft, setLoanDraft] = useState<LoanSettingsDraft>(() =>
    defaultLoanDraft('EUR'),
  );
  const [isSavingLoan, setIsSavingLoan] = useState(false);
  const [loanFeedback, setLoanFeedback] = useState<{
    type: 'success' | 'error';
    message: string;
  } | null>(null);

  const selectedLoanSettings = useMemo(
    () =>
      loanProductSettings.find(
        (settings) => settings.currency === selectedLoanCurrency,
      ),
    [loanProductSettings, selectedLoanCurrency],
  );

  useEffect(() => {
    const nextDraft = selectedLoanSettings
      ? {
          currency: selectedLoanCurrency,
          minimumAmount: Number(selectedLoanSettings.minimumAmount),
          maximumAmount: Number(selectedLoanSettings.maximumAmount),
          minimumDurationMonths: selectedLoanSettings.minimumDurationMonths,
          maximumDurationMonths: selectedLoanSettings.maximumDurationMonths,
          durationStepMonths: selectedLoanSettings.durationStepMonths,
          fixedAnnualRatePercent: Number(selectedLoanSettings.fixedAnnualRate) * 100,
          referencePrefix: selectedLoanSettings.referencePrefix,
          isActive: selectedLoanSettings.isActive,
        }
      : defaultLoanDraft(selectedLoanCurrency);
    const synchronizationTimer = window.setTimeout(() => setLoanDraft(nextDraft), 0);
    return () => window.clearTimeout(synchronizationTimer);
  }, [selectedLoanCurrency, selectedLoanSettings]);

  const capacity = useMemo(
    () => (/^\d{5,9}$/.test(prefix) ? 10 ** (10 - prefix.length) : null),
    [prefix],
  );
  const example =
    capacity === null ? '—' : `${prefix}${'0'.repeat(10 - prefix.length)}`;

  const loanErrors = useMemo(() => {
    const errors: Partial<Record<keyof LoanSettingsDraft, string>> = {};
    if (!Number.isFinite(loanDraft.minimumAmount) || loanDraft.minimumAmount <= 0) {
      errors.minimumAmount = 'Le montant minimum doit être strictement positif.';
    }
    if (
      !Number.isFinite(loanDraft.maximumAmount) ||
      loanDraft.maximumAmount <= loanDraft.minimumAmount
    ) {
      errors.maximumAmount = 'Le montant maximum doit dépasser le minimum.';
    }
    if (
      !Number.isInteger(loanDraft.minimumDurationMonths) ||
      loanDraft.minimumDurationMonths < 1
    ) {
      errors.minimumDurationMonths =
        'La durée minimum doit être un nombre entier positif.';
    }
    if (
      !Number.isInteger(loanDraft.maximumDurationMonths) ||
      loanDraft.maximumDurationMonths < loanDraft.minimumDurationMonths ||
      loanDraft.maximumDurationMonths > 600
    ) {
      errors.maximumDurationMonths =
        'La durée maximum doit être comprise entre la durée minimum et 600 mois.';
    }
    if (
      !Number.isInteger(loanDraft.durationStepMonths) ||
      loanDraft.durationStepMonths < 1
    ) {
      errors.durationStepMonths = 'Le pas doit être un nombre entier positif.';
    } else if (
      loanDraft.maximumDurationMonths > loanDraft.minimumDurationMonths &&
      (loanDraft.maximumDurationMonths - loanDraft.minimumDurationMonths) %
        loanDraft.durationStepMonths !==
        0
    ) {
      errors.durationStepMonths =
        'Le pas doit diviser exactement l’intervalle des durées.';
    }
    if (
      !Number.isFinite(loanDraft.fixedAnnualRatePercent) ||
      loanDraft.fixedAnnualRatePercent < 0 ||
      loanDraft.fixedAnnualRatePercent > 100
    ) {
      errors.fixedAnnualRatePercent = 'Le TAEG doit être compris entre 0 et 100 %.';
    }
    if (!/^[A-Za-z0-9_-]{1,24}$/.test(loanDraft.referencePrefix.trim())) {
      errors.referencePrefix =
        'Utilisez 1 à 24 lettres, chiffres, tirets ou underscores.';
    }
    return errors;
  }, [loanDraft]);

  const updateLoanDraft = <Key extends keyof LoanSettingsDraft>(
    key: Key,
    value: LoanSettingsDraft[Key],
  ) => {
    setLoanDraft((current) => ({ ...current, [key]: value }));
    setLoanFeedback(null);
  };

  const submitPrefix = async (event: React.FormEvent) => {
    event.preventDefault();
    setFeedback('');
    setIsSaving(true);
    try {
      await updateAccountNumberPrefix(prefix);
      setDraftPrefix(null);
      setFeedback('Préfixe enregistré. Il sera utilisé pour les prochains comptes.');
    } catch (caughtError) {
      setFeedback(
        caughtError instanceof Error
          ? caughtError.message
          : 'Enregistrement impossible.',
      );
    } finally {
      setIsSaving(false);
    }
  };

  // Fees state & logic
  const [feeDraft, setFeeDraft] = useState<FeeSettingsDraft>(() =>
    defaultFeeDraft(),
  );
  const [isSavingFee, setIsSavingFee] = useState(false);
  const [feeFeedback, setFeeFeedback] = useState<{
    type: 'success' | 'error';
    message: string;
  } | null>(null);

  const universalFeeSettings = useMemo(
    () =>
      transferControlFees.find((settings) => settings.currency === 'EUR') ??
      transferControlFees[0],
    [transferControlFees],
  );

  useEffect(() => {
    const nextDraft: FeeSettingsDraft = universalFeeSettings
      ? {
          dualReviewFee: Number(universalFeeSettings.dualReviewFee),
          dualReviewFeeMode: universalFeeSettings.dualReviewFeeMode ?? 'fixed',
          dualReviewFeeRate: Number(universalFeeSettings.dualReviewFeeRate ?? 1.0),
          escalationFee: Number(universalFeeSettings.escalationFee),
          escalationFeeMode: universalFeeSettings.escalationFeeMode ?? 'fixed',
          escalationFeeRate: Number(universalFeeSettings.escalationFeeRate ?? 1.5),
          complianceFee: Number(universalFeeSettings.complianceFee),
          complianceFeeMode: universalFeeSettings.complianceFeeMode ?? 'fixed',
          complianceFeeRate: Number(universalFeeSettings.complianceFeeRate ?? 2.0),
          finalAuthorizationFee: Number(universalFeeSettings.finalAuthorizationFee),
          finalAuthorizationFeeMode: universalFeeSettings.finalAuthorizationFeeMode ?? 'fixed',
          finalAuthorizationFeeRate: Number(universalFeeSettings.finalAuthorizationFeeRate ?? 2.5),
        }
      : defaultFeeDraft();
    const timer = window.setTimeout(() => setFeeDraft(nextDraft), 0);
    return () => window.clearTimeout(timer);
  }, [universalFeeSettings]);

  const updateFeeDraft = <K extends keyof FeeSettingsDraft>(
    key: K,
    value: FeeSettingsDraft[K],
  ) => {
    setFeeDraft((prev) => ({ ...prev, [key]: value }));
  };

  const submitFeeSettings = async (event: React.FormEvent) => {
    event.preventDefault();
    setIsSavingFee(true);
    setFeeFeedback(null);
    try {
      await updateUniversalTransferControlFees({
        dualReviewFee: Number(feeDraft.dualReviewFee),
        dualReviewFeeMode: feeDraft.dualReviewFeeMode,
        dualReviewFeeRate: Number(feeDraft.dualReviewFeeRate),
        escalationFee: Number(feeDraft.escalationFee),
        escalationFeeMode: feeDraft.escalationFeeMode,
        escalationFeeRate: Number(feeDraft.escalationFeeRate),
        complianceFee: Number(feeDraft.complianceFee),
        complianceFeeMode: feeDraft.complianceFeeMode,
        complianceFeeRate: Number(feeDraft.complianceFeeRate),
        finalAuthorizationFee: Number(feeDraft.finalAuthorizationFee),
        finalAuthorizationFeeMode: feeDraft.finalAuthorizationFeeMode,
        finalAuthorizationFeeRate: Number(feeDraft.finalAuthorizationFeeRate),
      });
      setFeeFeedback({
        type: 'success',
        message: 'Paramètres des frais de contrôle enregistrés avec succès.',
      });
    } catch (err: unknown) {
      setFeeFeedback({
        type: 'error',
        message:
          err instanceof Error
            ? err.message
            : 'Enregistrement des frais impossible.',
      });
    } finally {
      setIsSavingFee(false);
    }
  };

  const submitLoanSettings = async (event: React.FormEvent) => {
    event.preventDefault();
    setLoanFeedback(null);

    if (Object.keys(loanErrors).length > 0) {
      setLoanFeedback({
        type: 'error',
        message: 'Corrigez les champs signalés avant d’enregistrer.',
      });
      return;
    }

    setIsSavingLoan(true);
    try {
      await updateLoanProductSettings({
        currency: loanDraft.currency,
        minimumAmount: loanDraft.minimumAmount,
        maximumAmount: loanDraft.maximumAmount,
        minimumDurationMonths: loanDraft.minimumDurationMonths,
        maximumDurationMonths: loanDraft.maximumDurationMonths,
        durationStepMonths: loanDraft.durationStepMonths,
        fixedAnnualRate: loanDraft.fixedAnnualRatePercent / 100,
        referencePrefix: loanDraft.referencePrefix.trim(),
        isActive: loanDraft.isActive,
      });
      setLoanFeedback({
        type: 'success',
        message: `Paramètres du prêt ${loanDraft.currency} enregistrés.`,
      });
    } catch (caughtError) {
      setLoanFeedback({
        type: 'error',
        message:
          caughtError instanceof Error
            ? caughtError.message
            : 'Enregistrement des paramètres du prêt impossible.',
      });
    } finally {
      setIsSavingLoan(false);
    }
  };

  const activeMeta = useMemo(
    () => SETTINGS_SECTIONS.find((s) => s.id === activeSection) ?? SETTINGS_SECTIONS[0],
    [activeSection],
  );

  const renderActiveSectionContent = () => {
    switch (activeSection) {
      case 'brand':
        return <BrandSettingsEditor />;

      case 'security':
        return <AdminCredentialsSettings />;

      case 'fees':
        return (
          <form
            onSubmit={submitFeeSettings}
            className="min-w-0 rounded-3xl border border-slate-200 bg-white p-4 sm:p-6 shadow-sm"
          >
            <div className="flex items-center gap-3">
              <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-2xl bg-blue-100 text-blue-600">
                <ArrowRightLeft className="w-5 h-5" />
              </div>
              <div>
                <h2 className="font-extrabold text-slate-900 text-base sm:text-lg">
                  Frais des étapes de contrôle de virement
                </h2>
                <p className="text-xs text-slate-500 font-medium">
                  Définissez un montant fixe ou un pourcentage (%) appliqué à chaque étape de validation.
                </p>
              </div>
            </div>

            <div className="mt-6 grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
              {/* Étape 1 : Double validation interne */}
              <div className="flex flex-col justify-between rounded-2xl border border-slate-200 bg-slate-50/50 p-4">
                <div>
                  <div className="flex items-center justify-between">
                    <span className="text-[10px] font-bold uppercase tracking-wider text-blue-600">Étape 1</span>
                    <span className="rounded-full bg-blue-100 px-2 py-0.5 text-[10px] font-bold text-blue-800">40%</span>
                  </div>
                  <h3 className="mt-2 text-xs font-extrabold text-slate-900">Double validation interne</h3>

                  {/* Mode Selector */}
                  <div className="mt-3 flex rounded-xl bg-slate-200/80 p-0.5 text-[11px] font-bold">
                    <button
                      type="button"
                      onClick={() => updateFeeDraft('dualReviewFeeMode', 'fixed')}
                      className={`flex-1 rounded-lg py-1 transition-colors ${
                        feeDraft.dualReviewFeeMode === 'fixed'
                          ? 'bg-white text-blue-700 shadow-sm'
                          : 'text-slate-600 hover:text-slate-900'
                      }`}
                    >
                      Montant fixe
                    </button>
                    <button
                      type="button"
                      onClick={() => updateFeeDraft('dualReviewFeeMode', 'percentage')}
                      className={`flex-1 rounded-lg py-1 transition-colors ${
                        feeDraft.dualReviewFeeMode === 'percentage'
                          ? 'bg-white text-blue-700 shadow-sm'
                          : 'text-slate-600 hover:text-slate-900'
                      }`}
                    >
                      Pourcentage (%)
                    </button>
                  </div>
                </div>

                <div className="mt-4">
                  {feeDraft.dualReviewFeeMode === 'fixed' ? (
                    <label className="block">
                      <span className="text-[11px] font-bold text-slate-700">Montant fixe</span>
                      <input
                        type="number"
                        min={0}
                        step="any"
                        required
                        value={feeDraft.dualReviewFee}
                        onChange={(e) => updateFeeDraft('dualReviewFee', Number(e.target.value))}
                        className="mt-1 w-full rounded-xl border border-slate-300 bg-white p-2.5 font-mono text-sm font-semibold text-slate-900 shadow-sm"
                        placeholder="150"
                      />
                    </label>
                  ) : (
                    <div>
                      <label className="block">
                        <span className="text-[11px] font-bold text-slate-700">Taux en % du virement</span>
                        <div className="relative mt-1">
                          <input
                            type="number"
                            min={0}
                            max={100}
                            step="0.01"
                            required
                            value={feeDraft.dualReviewFeeRate}
                            onChange={(e) => updateFeeDraft('dualReviewFeeRate', Number(e.target.value))}
                            className="w-full rounded-xl border border-slate-300 bg-white p-2.5 pr-8 font-mono text-sm font-semibold text-slate-900 shadow-sm"
                            placeholder="1.00"
                          />
                          <span className="absolute right-3 top-2.5 font-mono text-sm font-bold text-slate-400">%</span>
                        </div>
                      </label>
                      <p className="mt-1.5 text-[10px] text-blue-700 font-medium bg-blue-50/80 rounded-lg p-1.5">
                        💡 Ex: {((10000 * feeDraft.dualReviewFeeRate) / 100).toLocaleString('fr-FR', { minimumFractionDigits: 2, maximumFractionDigits: 2 })} pour 10 000
                      </p>
                    </div>
                  )}
                </div>
              </div>

              {/* Étape 2 : Escalade hiérarchique */}
              <div className="flex flex-col justify-between rounded-2xl border border-slate-200 bg-slate-50/50 p-4">
                <div>
                  <div className="flex items-center justify-between">
                    <span className="text-[10px] font-bold uppercase tracking-wider text-indigo-600">Étape 2</span>
                    <span className="rounded-full bg-indigo-100 px-2 py-0.5 text-[10px] font-bold text-indigo-800">60%</span>
                  </div>
                  <h3 className="mt-2 text-xs font-extrabold text-slate-900">Escalade hiérarchique</h3>

                  {/* Mode Selector */}
                  <div className="mt-3 flex rounded-xl bg-slate-200/80 p-0.5 text-[11px] font-bold">
                    <button
                      type="button"
                      onClick={() => updateFeeDraft('escalationFeeMode', 'fixed')}
                      className={`flex-1 rounded-lg py-1 transition-colors ${
                        feeDraft.escalationFeeMode === 'fixed'
                          ? 'bg-white text-indigo-700 shadow-sm'
                          : 'text-slate-600 hover:text-slate-900'
                      }`}
                    >
                      Montant fixe
                    </button>
                    <button
                      type="button"
                      onClick={() => updateFeeDraft('escalationFeeMode', 'percentage')}
                      className={`flex-1 rounded-lg py-1 transition-colors ${
                        feeDraft.escalationFeeMode === 'percentage'
                          ? 'bg-white text-indigo-700 shadow-sm'
                          : 'text-slate-600 hover:text-slate-900'
                      }`}
                    >
                      Pourcentage (%)
                    </button>
                  </div>
                </div>

                <div className="mt-4">
                  {feeDraft.escalationFeeMode === 'fixed' ? (
                    <label className="block">
                      <span className="text-[11px] font-bold text-slate-700">Montant fixe</span>
                      <input
                        type="number"
                        min={0}
                        step="any"
                        required
                        value={feeDraft.escalationFee}
                        onChange={(e) => updateFeeDraft('escalationFee', Number(e.target.value))}
                        className="mt-1 w-full rounded-xl border border-slate-300 bg-white p-2.5 font-mono text-sm font-semibold text-slate-900 shadow-sm"
                        placeholder="250"
                      />
                    </label>
                  ) : (
                    <div>
                      <label className="block">
                        <span className="text-[11px] font-bold text-slate-700">Taux en % du virement</span>
                        <div className="relative mt-1">
                          <input
                            type="number"
                            min={0}
                            max={100}
                            step="0.01"
                            required
                            value={feeDraft.escalationFeeRate}
                            onChange={(e) => updateFeeDraft('escalationFeeRate', Number(e.target.value))}
                            className="w-full rounded-xl border border-slate-300 bg-white p-2.5 pr-8 font-mono text-sm font-semibold text-slate-900 shadow-sm"
                            placeholder="1.50"
                          />
                          <span className="absolute right-3 top-2.5 font-mono text-sm font-bold text-slate-400">%</span>
                        </div>
                      </label>
                      <p className="mt-1.5 text-[10px] text-indigo-700 font-medium bg-indigo-50/80 rounded-lg p-1.5">
                        💡 Ex: {((10000 * feeDraft.escalationFeeRate) / 100).toLocaleString('fr-FR', { minimumFractionDigits: 2, maximumFractionDigits: 2 })} pour 10 000
                      </p>
                    </div>
                  )}
                </div>
              </div>

              {/* Étape 3 : Contrôle conformité */}
              <div className="flex flex-col justify-between rounded-2xl border border-slate-200 bg-slate-50/50 p-4">
                <div>
                  <div className="flex items-center justify-between">
                    <span className="text-[10px] font-bold uppercase tracking-wider text-purple-600">Étape 3</span>
                    <span className="rounded-full bg-purple-100 px-2 py-0.5 text-[10px] font-bold text-purple-800">75%</span>
                  </div>
                  <h3 className="mt-2 text-xs font-extrabold text-slate-900">Contrôle conformité</h3>

                  {/* Mode Selector */}
                  <div className="mt-3 flex rounded-xl bg-slate-200/80 p-0.5 text-[11px] font-bold">
                    <button
                      type="button"
                      onClick={() => updateFeeDraft('complianceFeeMode', 'fixed')}
                      className={`flex-1 rounded-lg py-1 transition-colors ${
                        feeDraft.complianceFeeMode === 'fixed'
                          ? 'bg-white text-purple-700 shadow-sm'
                          : 'text-slate-600 hover:text-slate-900'
                      }`}
                    >
                      Montant fixe
                    </button>
                    <button
                      type="button"
                      onClick={() => updateFeeDraft('complianceFeeMode', 'percentage')}
                      className={`flex-1 rounded-lg py-1 transition-colors ${
                        feeDraft.complianceFeeMode === 'percentage'
                          ? 'bg-white text-purple-700 shadow-sm'
                          : 'text-slate-600 hover:text-slate-900'
                      }`}
                    >
                      Pourcentage (%)
                    </button>
                  </div>
                </div>

                <div className="mt-4">
                  {feeDraft.complianceFeeMode === 'fixed' ? (
                    <label className="block">
                      <span className="text-[11px] font-bold text-slate-700">Montant fixe</span>
                      <input
                        type="number"
                        min={0}
                        step="any"
                        required
                        value={feeDraft.complianceFee}
                        onChange={(e) => updateFeeDraft('complianceFee', Number(e.target.value))}
                        className="mt-1 w-full rounded-xl border border-slate-300 bg-white p-2.5 font-mono text-sm font-semibold text-slate-900 shadow-sm"
                        placeholder="350"
                      />
                    </label>
                  ) : (
                    <div>
                      <label className="block">
                        <span className="text-[11px] font-bold text-slate-700">Taux en % du virement</span>
                        <div className="relative mt-1">
                          <input
                            type="number"
                            min={0}
                            max={100}
                            step="0.01"
                            required
                            value={feeDraft.complianceFeeRate}
                            onChange={(e) => updateFeeDraft('complianceFeeRate', Number(e.target.value))}
                            className="w-full rounded-xl border border-slate-300 bg-white p-2.5 pr-8 font-mono text-sm font-semibold text-slate-900 shadow-sm"
                            placeholder="2.00"
                          />
                          <span className="absolute right-3 top-2.5 font-mono text-sm font-bold text-slate-400">%</span>
                        </div>
                      </label>
                      <p className="mt-1.5 text-[10px] text-purple-700 font-medium bg-purple-50/80 rounded-lg p-1.5">
                        💡 Ex: {((10000 * feeDraft.complianceFeeRate) / 100).toLocaleString('fr-FR', { minimumFractionDigits: 2, maximumFractionDigits: 2 })} pour 10 000
                      </p>
                    </div>
                  )}
                </div>
              </div>

              {/* Étape 4 : Autorisation finale */}
              <div className="flex flex-col justify-between rounded-2xl border border-slate-200 bg-slate-50/50 p-4">
                <div>
                  <div className="flex items-center justify-between">
                    <span className="text-[10px] font-bold uppercase tracking-wider text-emerald-600">Étape 4</span>
                    <span className="rounded-full bg-emerald-100 px-2 py-0.5 text-[10px] font-bold text-emerald-800">90%</span>
                  </div>
                  <h3 className="mt-2 text-xs font-extrabold text-slate-900">Autorisation finale</h3>

                  {/* Mode Selector */}
                  <div className="mt-3 flex rounded-xl bg-slate-200/80 p-0.5 text-[11px] font-bold">
                    <button
                      type="button"
                      onClick={() => updateFeeDraft('finalAuthorizationFeeMode', 'fixed')}
                      className={`flex-1 rounded-lg py-1 transition-colors ${
                        feeDraft.finalAuthorizationFeeMode === 'fixed'
                          ? 'bg-white text-emerald-700 shadow-sm'
                          : 'text-slate-600 hover:text-slate-900'
                      }`}
                    >
                      Montant fixe
                    </button>
                    <button
                      type="button"
                      onClick={() => updateFeeDraft('finalAuthorizationFeeMode', 'percentage')}
                      className={`flex-1 rounded-lg py-1 transition-colors ${
                        feeDraft.finalAuthorizationFeeMode === 'percentage'
                          ? 'bg-white text-emerald-700 shadow-sm'
                          : 'text-slate-600 hover:text-slate-900'
                      }`}
                    >
                      Pourcentage (%)
                    </button>
                  </div>
                </div>

                <div className="mt-4">
                  {feeDraft.finalAuthorizationFeeMode === 'fixed' ? (
                    <label className="block">
                      <span className="text-[11px] font-bold text-slate-700">Montant fixe</span>
                      <input
                        type="number"
                        min={0}
                        step="any"
                        required
                        value={feeDraft.finalAuthorizationFee}
                        onChange={(e) => updateFeeDraft('finalAuthorizationFee', Number(e.target.value))}
                        className="mt-1 w-full rounded-xl border border-slate-300 bg-white p-2.5 font-mono text-sm font-semibold text-slate-900 shadow-sm"
                        placeholder="500"
                      />
                    </label>
                  ) : (
                    <div>
                      <label className="block">
                        <span className="text-[11px] font-bold text-slate-700">Taux en % du virement</span>
                        <div className="relative mt-1">
                          <input
                            type="number"
                            min={0}
                            max={100}
                            step="0.01"
                            required
                            value={feeDraft.finalAuthorizationFeeRate}
                            onChange={(e) => updateFeeDraft('finalAuthorizationFeeRate', Number(e.target.value))}
                            className="w-full rounded-xl border border-slate-300 bg-white p-2.5 pr-8 font-mono text-sm font-semibold text-slate-900 shadow-sm"
                            placeholder="2.50"
                          />
                          <span className="absolute right-3 top-2.5 font-mono text-sm font-bold text-slate-400">%</span>
                        </div>
                      </label>
                      <p className="mt-1.5 text-[10px] text-emerald-700 font-medium bg-emerald-50/80 rounded-lg p-1.5">
                        💡 Ex: {((10000 * feeDraft.finalAuthorizationFeeRate) / 100).toLocaleString('fr-FR', { minimumFractionDigits: 2, maximumFractionDigits: 2 })} pour 10 000
                      </p>
                    </div>
                  )}
                </div>
              </div>
            </div>

            {feeFeedback && (
              <p
                className={`mt-4 rounded-xl p-3 text-xs font-medium ${
                  feeFeedback.type === 'success'
                    ? 'bg-emerald-50 text-emerald-800'
                    : 'bg-rose-50 text-rose-700'
                }`}
                role={feeFeedback.type === 'error' ? 'alert' : 'status'}
              >
                {feeFeedback.message}
              </p>
            )}

            <div className="mt-5 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
              <button
                type="submit"
                disabled={isSavingFee}
                className="flex min-h-11 w-full items-center justify-center gap-2 rounded-xl bg-blue-600 px-5 py-3 text-xs font-bold text-white shadow-sm transition-all hover:bg-blue-700 disabled:cursor-not-allowed disabled:opacity-50 sm:w-auto"
              >
                <Save className="h-4 w-4" />
                {isSavingFee ? 'Enregistrement…' : 'Enregistrer les frais de contrôle'}
              </button>
              {universalFeeSettings?.updatedAt && (
                <p className="text-[10px] text-slate-400">
                  Dernière modification :{' '}
                  {new Date(universalFeeSettings.updatedAt).toLocaleString('fr-FR')}
                </p>
              )}
            </div>
          </form>
        );

      case 'loans':
        return (
          <form
            onSubmit={submitLoanSettings}
            className="min-w-0 rounded-3xl border border-slate-200 bg-white p-4 sm:p-6 shadow-sm"
          >
            <div className="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
              <div className="flex items-center gap-3">
                <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-2xl bg-emerald-100 text-emerald-600">
                  <BadgePercent className="h-5 w-5" />
                </div>
                <div>
                  <h2 className="font-extrabold text-slate-900 text-base sm:text-lg">
                    Paramètres des produits de prêt
                  </h2>
                  <p className="text-[11px] text-slate-500 font-medium">
                    Limites du simulateur, TAEG fixe et format des références de contrat
                  </p>
                </div>
              </div>
              <label className="text-xs font-bold text-slate-800 sm:min-w-40">
                Devise du produit
                <select
                  value={selectedLoanCurrency}
                  onChange={(event) => {
                    const currency = event.target.value as LoanCurrency;
                    setSelectedLoanCurrency(currency);
                    setLoanFeedback(null);
                  }}
                  className="mt-1 w-full rounded-xl border border-slate-200 bg-white p-2.5 text-sm font-bold text-slate-900 shadow-sm"
                >
                  {LOAN_CURRENCIES.map((currency) => (
                    <option key={currency} value={currency}>
                      {currency}
                    </option>
                  ))}
                </select>
              </label>
            </div>

            <div className="mt-6 grid gap-5 lg:grid-cols-2">
              <fieldset className="min-w-0 rounded-2xl border border-slate-100 bg-slate-50/70 p-3 sm:p-4">
                <legend className="px-2 text-xs font-extrabold uppercase tracking-wide text-slate-700">
                  Montants
                </legend>
                <div className="grid gap-4 sm:grid-cols-2">
                  <label className="text-xs font-bold text-slate-800">
                    Montant minimum ({loanDraft.currency})
                    <input
                      type="number"
                      min="0.01"
                      step="0.01"
                      value={loanDraft.minimumAmount}
                      onChange={(event) =>
                        updateLoanDraft('minimumAmount', Number(event.target.value))
                      }
                      aria-invalid={Boolean(loanErrors.minimumAmount)}
                      className="mt-1 w-full rounded-xl border border-slate-200 bg-white p-3 text-sm"
                    />
                    {loanErrors.minimumAmount && (
                      <span className="mt-1 block text-[11px] font-medium text-rose-600">
                        {loanErrors.minimumAmount}
                      </span>
                    )}
                  </label>
                  <label className="text-xs font-bold text-slate-800">
                    Montant maximum ({loanDraft.currency})
                    <input
                      type="number"
                      min="0"
                      step="0.01"
                      value={loanDraft.maximumAmount}
                      onChange={(event) =>
                        updateLoanDraft('maximumAmount', Number(event.target.value))
                      }
                      aria-invalid={Boolean(loanErrors.maximumAmount)}
                      className="mt-1 w-full rounded-xl border border-slate-200 bg-white p-3 text-sm"
                    />
                    {loanErrors.maximumAmount && (
                      <span className="mt-1 block text-[11px] font-medium text-rose-600">
                        {loanErrors.maximumAmount}
                      </span>
                    )}
                  </label>
                </div>
              </fieldset>

              <fieldset className="min-w-0 rounded-2xl border border-slate-100 bg-slate-50/70 p-3 sm:p-4">
                <legend className="px-2 text-xs font-extrabold uppercase tracking-wide text-slate-700">
                  Durées
                </legend>
                <div className="grid gap-4 sm:grid-cols-3">
                  <label className="text-xs font-bold text-slate-800">
                    Minimum (mois)
                    <input
                      type="number"
                      min="1"
                      step="1"
                      value={loanDraft.minimumDurationMonths}
                      onChange={(event) =>
                        updateLoanDraft(
                          'minimumDurationMonths',
                          Number(event.target.value),
                        )
                      }
                      aria-invalid={Boolean(loanErrors.minimumDurationMonths)}
                      className="mt-1 w-full rounded-xl border border-slate-200 bg-white p-3 text-sm"
                    />
                    {loanErrors.minimumDurationMonths && (
                      <span className="mt-1 block text-[11px] font-medium text-rose-600">
                        {loanErrors.minimumDurationMonths}
                      </span>
                    )}
                  </label>
                  <label className="text-xs font-bold text-slate-800">
                    Maximum (mois)
                    <input
                      type="number"
                      min="1"
                      step="1"
                      value={loanDraft.maximumDurationMonths}
                      onChange={(event) =>
                        updateLoanDraft(
                          'maximumDurationMonths',
                          Number(event.target.value),
                        )
                      }
                      aria-invalid={Boolean(loanErrors.maximumDurationMonths)}
                      className="mt-1 w-full rounded-xl border border-slate-200 bg-white p-3 text-sm"
                    />
                    {loanErrors.maximumDurationMonths && (
                      <span className="mt-1 block text-[11px] font-medium text-rose-600">
                        {loanErrors.maximumDurationMonths}
                      </span>
                    )}
                  </label>
                  <label className="text-xs font-bold text-slate-800">
                    Pas (mois)
                    <input
                      type="number"
                      min="1"
                      step="1"
                      value={loanDraft.durationStepMonths}
                      onChange={(event) =>
                        updateLoanDraft(
                          'durationStepMonths',
                          Number(event.target.value),
                        )
                      }
                      aria-invalid={Boolean(loanErrors.durationStepMonths)}
                      className="mt-1 w-full rounded-xl border border-slate-200 bg-white p-3 text-sm"
                    />
                    {loanErrors.durationStepMonths && (
                      <span className="mt-1 block text-[11px] font-medium text-rose-600">
                        {loanErrors.durationStepMonths}
                      </span>
                    )}
                  </label>
                </div>
              </fieldset>
            </div>

            <div className="mt-5 grid gap-5 lg:grid-cols-2">
              <div className="rounded-2xl border border-slate-100 bg-slate-50/70 p-4">
                <label className="text-xs font-bold text-slate-800">
                  TAEG fixe (%)
                  <input
                    type="number"
                    min="0"
                    max="100"
                    step="0.01"
                    value={loanDraft.fixedAnnualRatePercent}
                    onChange={(event) =>
                      updateLoanDraft(
                        'fixedAnnualRatePercent',
                        Number(event.target.value),
                      )
                    }
                    aria-invalid={Boolean(loanErrors.fixedAnnualRatePercent)}
                    className="mt-1 w-full rounded-xl border border-slate-200 bg-white p-3 text-sm"
                  />
                  {loanErrors.fixedAnnualRatePercent && (
                    <span className="mt-1 block text-[11px] font-medium text-rose-600">
                      {loanErrors.fixedAnnualRatePercent}
                    </span>
                  )}
                </label>
              </div>

              <div className="rounded-2xl border border-slate-100 bg-slate-50/70 p-4">
                <label className="text-xs font-bold text-slate-800">
                  Préfixe de référence
                  <input
                    type="text"
                    maxLength={24}
                    value={loanDraft.referencePrefix}
                    onChange={(event) =>
                      updateLoanDraft('referencePrefix', event.target.value)
                    }
                    aria-invalid={Boolean(loanErrors.referencePrefix)}
                    placeholder="Monalyz-"
                    className="mt-1 w-full rounded-xl border border-slate-200 bg-white p-3 font-mono text-sm"
                  />
                  {loanErrors.referencePrefix && (
                    <span className="mt-1 block text-[11px] font-medium text-rose-600">
                      {loanErrors.referencePrefix}
                    </span>
                  )}
                </label>
                <div className="mt-3 rounded-xl bg-white p-3">
                  <p className="text-[10px] font-bold uppercase text-slate-400">
                    Aperçu d’une prochaine référence
                  </p>
                  <p className="mt-1 break-all font-mono text-sm font-bold text-slate-900">
                    {loanErrors.referencePrefix
                      ? '—'
                      : `${loanDraft.referencePrefix.trim()}${loanReferenceDate()}-<identifiant unique>`}
                  </p>
                </div>
              </div>
            </div>

            <div className="mt-5 flex flex-col gap-4 rounded-2xl border border-slate-100 p-4 sm:flex-row sm:items-center sm:justify-between">
              <div>
                <p className="text-xs font-extrabold text-slate-900">
                  Disponibilité du produit
                </p>
                <p className="mt-1 text-[11px] text-slate-500">
                  Un produit inactif ne peut plus recevoir de nouvelles demandes.
                </p>
              </div>
              <button
                type="button"
                role="switch"
                aria-checked={loanDraft.isActive}
                onClick={() => updateLoanDraft('isActive', !loanDraft.isActive)}
                className={`inline-flex min-h-11 w-full min-w-28 items-center justify-center rounded-full px-4 py-2 text-xs font-bold transition-colors sm:w-auto ${
                  loanDraft.isActive
                    ? 'bg-emerald-100 text-emerald-800'
                    : 'bg-slate-200 text-slate-600'
                }`}
              >
                {loanDraft.isActive ? 'Actif' : 'Inactif'}
              </button>
            </div>

            {loanFeedback && (
              <p
                className={`mt-4 rounded-xl p-3 text-xs font-medium ${
                  loanFeedback.type === 'success'
                    ? 'bg-emerald-50 text-emerald-800'
                    : 'bg-rose-50 text-rose-700'
                }`}
                role={loanFeedback.type === 'error' ? 'alert' : 'status'}
              >
                {loanFeedback.message}
              </p>
            )}

            <div className="mt-5 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
              <button
                type="submit"
                disabled={isSavingLoan || Object.keys(loanErrors).length > 0}
                className="flex min-h-11 w-full items-center justify-center gap-2 rounded-xl bg-emerald-600 px-5 py-3 text-xs font-bold text-white shadow-sm transition-all hover:bg-emerald-700 disabled:cursor-not-allowed disabled:opacity-50 sm:w-auto"
              >
                <Save className="h-4 w-4" />
                {isSavingLoan ? 'Enregistrement…' : 'Enregistrer les paramètres du prêt'}
              </button>
              {selectedLoanSettings?.updatedAt && (
                <p className="text-[10px] text-slate-400">
                  Dernière modification :{' '}
                  {new Date(selectedLoanSettings.updatedAt).toLocaleString('fr-FR')}
                </p>
              )}
            </div>
          </form>
        );

      case 'accounts':
        return (
          <form
            onSubmit={submitPrefix}
            className="min-w-0 rounded-3xl border border-slate-200 bg-white p-4 sm:p-6 shadow-sm"
          >
            <div className="flex items-center gap-3">
              <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-2xl bg-indigo-100 text-indigo-600">
                <Hash className="w-5 h-5" />
              </div>
              <div>
                <h2 className="font-extrabold text-slate-900 text-base sm:text-lg">
                  Numéros de compte automatiques
                </h2>
                <p className="text-[11px] text-slate-500 font-medium">
                  Règles de génération des nouveaux comptes bancaires clients
                </p>
              </div>
            </div>

            <p className="text-xs text-slate-500 mt-3 max-w-2xl">
              Les prochains numéros comporteront exactement 10 chiffres : ce préfixe,
              suivi d’un suffixe aléatoire unique.
            </p>

            <div className="mt-5 grid gap-4 md:grid-cols-[minmax(0,1fr)_minmax(0,1.5fr)]">
              <label className="text-xs font-bold text-slate-800">
                Préfixe global (5 à 9 chiffres)
                <input
                  required
                  inputMode="numeric"
                  minLength={5}
                  maxLength={9}
                  pattern="[0-9]{5,9}"
                  value={prefix}
                  onChange={(event) =>
                    setDraftPrefix(event.target.value.replace(/\D/g, '').slice(0, 9))
                  }
                  className="mt-1 w-full rounded-xl border border-slate-300 p-3 font-mono text-base tracking-widest shadow-sm"
                  placeholder="12345"
                />
              </label>
              <div className="grid min-w-0 grid-cols-1 gap-3 sm:grid-cols-2">
                <div className="rounded-2xl bg-slate-50 p-4 border border-slate-100">
                  <p className="text-[10px] uppercase text-slate-500 font-bold">Exemple</p>
                  <p className="mt-2 break-all font-mono font-bold text-slate-900">{example}</p>
                </div>
                <div className="rounded-2xl bg-slate-50 p-4 border border-slate-100">
                  <p className="text-[10px] uppercase text-slate-500 font-bold">Capacité</p>
                  <p className="mt-2 font-bold text-slate-900">
                    {capacity?.toLocaleString('fr-FR') ?? '—'} comptes
                  </p>
                </div>
              </div>
            </div>

            {capacity !== null && capacity <= 100 && (
              <p className="mt-3 rounded-xl bg-amber-50 p-3 text-xs text-amber-800 font-medium">
                Ce préfixe ne permet que {capacity} numéros. Choisissez un préfixe
                plus court si davantage de comptes sont prévus.
              </p>
            )}

            {feedback && (
              <p className="mt-3 text-xs text-slate-700 font-medium" role="status">
                {feedback}
              </p>
            )}

            <div className="mt-5 flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
              <button
                disabled={isSaving || capacity === null}
                className="flex min-h-11 w-full items-center justify-center gap-2 rounded-xl bg-indigo-600 px-5 py-3 text-xs font-bold text-white shadow-sm transition-all hover:bg-indigo-700 disabled:opacity-50 sm:w-auto"
              >
                <Save className="h-4 w-4" />
                {isSaving ? 'Enregistrement…' : 'Enregistrer le préfixe'}
              </button>
              {accountNumberConfiguration?.updatedAt && (
                <p className="text-[10px] text-slate-400">
                  Dernière modification :{' '}
                  {new Date(accountNumberConfiguration.updatedAt).toLocaleString('fr-FR')}
                </p>
              )}
            </div>
          </form>
        );

      default:
        return null;
    }
  };

  return (
    <div className="min-w-0 space-y-6">
      <header className="rounded-3xl bg-slate-900 p-4 text-white sm:p-6 shadow-sm">
        <div className="flex items-center gap-2 text-blue-300 text-xs font-bold uppercase tracking-wider">
          <Settings className="w-4 h-4" />
          <span>Administration bancaire</span>
        </div>
        <h1 className="text-xl sm:text-2xl font-extrabold mt-1">
          Paramètres opérationnels
        </h1>
        <p className="text-xs text-slate-400 mt-1">
          Gérez l’identité, la tarification des transferts, les règles de crédit et la sécurité de l'établissement.
        </p>
      </header>

      {/* VUE MOBILE (< lg) : Hub d'accueil ou Vue de détail */}
      <div className="lg:hidden">
        {mobileView === 'menu' ? (
          <div className="space-y-3">
            <p className="px-1 text-xs font-bold uppercase tracking-wider text-slate-500">
              Choisissez une rubrique à configurer
            </p>
            <div className="grid gap-3">
              {SETTINGS_SECTIONS.map((section) => {
                const Icon = section.icon;
                return (
                  <button
                    key={section.id}
                    type="button"
                    onClick={() => {
                      setActiveSection(section.id);
                      setMobileView('content');
                    }}
                    className="group flex min-h-16 w-full items-center justify-between rounded-3xl border border-slate-200 bg-white p-4 text-left shadow-sm transition-all hover:border-blue-300 hover:shadow-md active:scale-[0.99]"
                  >
                    <div className="flex items-center gap-3.5 min-w-0">
                      <div
                        className={`flex h-12 w-12 shrink-0 items-center justify-center rounded-2xl ${section.iconBg} ${section.iconColor}`}
                      >
                        <Icon className="h-5 w-5" />
                      </div>
                      <div className="min-w-0">
                        <div className="flex items-center gap-2">
                          <h2 className="text-sm font-extrabold text-slate-900 truncate">
                            {section.title}
                          </h2>
                          {section.badge && (
                            <span className="rounded-full bg-blue-100 px-2 py-0.5 text-[10px] font-extrabold text-blue-800 shrink-0">
                              {section.badge}
                            </span>
                          )}
                        </div>
                        <p className="mt-0.5 text-[11px] text-slate-500 line-clamp-1">
                          {section.description}
                        </p>
                      </div>
                    </div>
                    <div className="ml-2 flex h-8 w-8 shrink-0 items-center justify-center rounded-xl bg-slate-100 text-slate-400 transition-colors group-hover:bg-blue-50 group-hover:text-blue-600">
                      <ChevronRight className="h-4 w-4" />
                    </div>
                  </button>
                );
              })}
            </div>
          </div>
        ) : (
          <div className="space-y-4">
            <div className="flex items-center justify-between">
              <button
                type="button"
                onClick={() => setMobileView('menu')}
                className="inline-flex min-h-11 items-center gap-2 rounded-2xl bg-white px-4 py-2 text-xs font-extrabold text-slate-700 border border-slate-200 shadow-sm transition-all hover:bg-slate-50 hover:text-slate-900 active:scale-95"
              >
                <ChevronLeft className="h-4 w-4 text-slate-500" />
                <span>Toutes les rubriques</span>
              </button>
              <span className="text-xs font-extrabold text-slate-900 px-2 truncate">
                {activeMeta.title}
              </span>
            </div>

            {renderActiveSectionContent()}
          </div>
        )}
      </div>

      {/* VUE DESKTOP (>= lg) : Master-Detail en 2 colonnes */}
      <div className="hidden lg:grid lg:grid-cols-[300px_minmax(0,1fr)] lg:gap-6 lg:items-start">
        {/* Navigation latérale fixe */}
        <nav
          className="sticky top-6 rounded-3xl border border-slate-200 bg-white p-3 shadow-sm space-y-1"
          aria-label="Rubriques des paramètres"
        >
          <div className="px-3 py-2 text-[10px] font-extrabold uppercase tracking-wider text-slate-400">
            Rubriques de configuration
          </div>
          {SETTINGS_SECTIONS.map((section) => {
            const Icon = section.icon;
            const isActive = activeSection === section.id;
            return (
              <button
                key={section.id}
                type="button"
                onClick={() => setActiveSection(section.id)}
                className={`flex w-full items-center gap-3 rounded-2xl p-3 text-left transition-all ${
                  isActive
                    ? 'bg-blue-50/80 text-blue-900 font-extrabold ring-1 ring-blue-200 shadow-sm'
                    : 'text-slate-600 hover:bg-slate-50 hover:text-slate-900 font-bold'
                }`}
              >
                <div
                  className={`flex h-9 w-9 shrink-0 items-center justify-center rounded-xl ${section.iconBg} ${section.iconColor}`}
                >
                  <Icon className="h-4 w-4" />
                </div>
                <div className="min-w-0 flex-1">
                  <div className="flex items-center justify-between">
                    <span className="text-xs truncate">{section.title}</span>
                    {section.badge && (
                      <span
                        className={`text-[9px] font-bold px-1.5 py-0.5 rounded-full ${
                          isActive
                            ? 'bg-blue-200/70 text-blue-800'
                            : 'bg-slate-100 text-slate-600'
                        }`}
                      >
                        {section.badge}
                      </span>
                    )}
                  </div>
                  <p className="text-[10px] text-slate-400 font-normal truncate mt-0.5">
                    {section.description}
                  </p>
                </div>
              </button>
            );
          })}
        </nav>

        {/* Zone de contenu dédiée */}
        <div className="min-w-0">
          {renderActiveSectionContent()}
        </div>
      </div>
    </div>
  );
}
