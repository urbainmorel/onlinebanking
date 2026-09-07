'use client';

import React, { useState, useEffect } from 'react';
import { useAppStore } from '@/lib/store';
import { translations } from '@/lib/i18n';
import { bankingMessages } from '@/lib/banking-i18n';
import type { Language, TransferType } from '@/lib/types';
import { convertAnyAmount, formatDirectCurrency } from '@/lib/currency';
import { formatLocalizedDateTime } from '@/lib/language';
import {
  accountTypeLabel,
  extraUserMessages,
  interpolate,
  localizedAppError,
} from '@/lib/user-i18n';
import {
  X,
  Send,
  CheckCircle2,
  ArrowLeft,
  ArrowRight,
} from 'lucide-react';
import { motion, AnimatePresence } from 'motion/react';
import { useBranded } from '@/components/brand/BrandProvider';
import { Dialog, DialogBackdrop, DialogPanel } from '@/components/ui/Dialog';

const LATAM_COUNTRIES: Record<string, Record<Language, string>> = {
  BRL: { fr: 'Brésil', en: 'Brazil', de: 'Brasilien', es: 'Brasil', it: 'Brasile', nl: 'Brazilië' },
  MXN: { fr: 'Mexique', en: 'Mexico', de: 'Mexiko', es: 'México', it: 'Messico', nl: 'Mexico' },
  ARS: { fr: 'Argentine', en: 'Argentina', de: 'Argentinien', es: 'Argentina', it: 'Argentina', nl: 'Argentinië' },
  COP: { fr: 'Colombie', en: 'Colombia', de: 'Kolumbien', es: 'Colombia', it: 'Colombia', nl: 'Colombia' },
  CLP: { fr: 'Chili', en: 'Chile', de: 'Chile', es: 'Chile', it: 'Cile', nl: 'Chili' },
  PEN: { fr: 'Pérou', en: 'Peru', de: 'Peru', es: 'Perú', it: 'Perù', nl: 'Peru' },
  UYU: { fr: 'Uruguay', en: 'Uruguay', de: 'Uruguay', es: 'Uruguay', it: 'Uruguay', nl: 'Uruguay' },
  CRC: { fr: 'Costa Rica', en: 'Costa Rica', de: 'Costa Rica', es: 'Costa Rica', it: 'Costa Rica', nl: 'Costa Rica' },
  PAB: { fr: 'Panama', en: 'Panama', de: 'Panama', es: 'Panamá', it: 'Panama', nl: 'Panama' },
  DOP: { fr: 'Rép. Dominicaine', en: 'Dominican Rep.', de: 'Dom. Republik', es: 'Rep. Dominicana', it: 'Rep. Dominicana', nl: 'Dom. Republiek' },
  USD: { fr: 'Équateur', en: 'Ecuador', de: 'Ecuador', es: 'Ecuador', it: 'Ecuador', nl: 'Ecuador' },
};

const AFRICA_COUNTRIES: Record<string, Record<Language, string>> = {
  XOF: { fr: 'Sénégal / UEMOA', en: 'Senegal / WAEMU', de: 'Senegal / WAEMU', es: 'Senegal / UEMOA', it: 'Senegal / UEMOA', nl: 'Senegal / UEMOA' },
  MAD: { fr: 'Maroc', en: 'Morocco', de: 'Marokko', es: 'Marruecos', it: 'Marocco', nl: 'Marokko' },
  ZAR: { fr: 'Afrique du Sud', en: 'South Africa', de: 'Südafrika', es: 'Sudáfrica', it: 'Sudafrica', nl: 'Zuid-Afrika' },
  EGP: { fr: 'Égypte', en: 'Egypt', de: 'Ägypten', es: 'Egipto', it: 'Egitto', nl: 'Egypte' },
  NGN: { fr: 'Nigeria', en: 'Nigeria', de: 'Nigeria', es: 'Nigeria', it: 'Nigeria', nl: 'Nigeria' },
};

export default function WireTransferModal() {
  const {
    language,
    rates,
    accounts,
    isTransferModalOpen,
    setIsTransferModalOpen,
    addTransfer,
  } = useAppStore();

  const t = useBranded(translations[language] || translations.fr);
  const banking = useBranded(bankingMessages[language]);
  const copy = useBranded(extraUserMessages[language]);
  const transferCopy = copy.transferModal;
  const required = (field: keyof typeof transferCopy.fields) =>
    interpolate(transferCopy.required, { field: transferCopy.fields[field] });

  const [step, setStep] = useState(1);
  const [transferType, setTransferType] = useState<TransferType>('canada');
  const [sourceAccountId, setSourceAccountId] = useState<string>(accounts[0]?.id || 'acc_1');
  const [recipientName, setRecipientName] = useState('');
  const [amountInput, setAmountInput] = useState('1000');
  const [motive, setMotive] = useState('');

  // Canada fields
  const [transitNumber, setTransitNumber] = useState('');
  const [institutionNumber, setInstitutionNumber] = useState('');
  const [accountNumber, setAccountNumber] = useState('');
  const [interacEmail, setInteracEmail] = useState('');

  // Eurozone fields
  const [iban, setIban] = useState('');
  const [bicSwift, setBICSwift] = useState('');

  // USA fields
  const [routingNumber, setRoutingNumber] = useState('');
  const [wireMethod, setWireMethod] = useState<'ach' | 'domestic'>('ach');

  // Swiss fields
  const [swissIban, setSwissIban] = useState('');
  const [clearingNumber, setClearingNumber] = useState('');

  const [isSuccess, setIsSuccess] = useState(false);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [submitError, setSubmitError] = useState('');
  const [errors, setErrors] = useState<Record<string, string>>({});

  const [targetCurrOverride, setTargetCurrOverride] = useState<string | null>(null);

  const clearError = (field: string) => {
    setErrors((prev) => {
      const copy = { ...prev };
      delete copy[field];
      return copy;
    });
  };

  const getTargetCurrency = (type: TransferType): string => {
    if (type === 'canada') return 'CAD';
    if (type === 'eurozone') return 'EUR';
    if (type === 'usa') return 'USD';
    if (type === 'swiss') return 'CHF';
    if (type === 'uk') return 'GBP';
    if (type === 'latam') return targetCurrOverride || 'BRL';
    if (type === 'africa') return targetCurrOverride || 'XOF';
    return 'EUR';
  };

  const targetCurr = getTargetCurrency(transferType);
  const numericAmount = parseFloat(amountInput) || 0;
  const sourceAccount = accounts.find((a) => a.id === sourceAccountId) || accounts[0];

  // Convert amount from source account currency to target currency using convertAnyAmount
  const convertedTargetAmount = sourceAccount
    ? convertAnyAmount(numericAmount, sourceAccount.currency, targetCurr, rates)
    : 0;

  const handleNextStep = () => {
    const newErrors: Record<string, string> = {};
    if (step === 1) {
      if (!recipientName.trim()) {
        newErrors.recipientName = required('recipientName');
      }
    } else if (step === 2) {
      if (transferType === 'eurozone') {
        if (!iban.trim()) {
          newErrors.iban = required('iban');
        }
        if (!bicSwift.trim()) {
          newErrors.bicSwift = required('bicSwift');
        }
      } else if (transferType === 'usa') {
        if (!routingNumber.trim()) {
          newErrors.routingNumber = required('routingNumber');
        }
        if (!accountNumber.trim()) {
          newErrors.accountNumber = required('accountNumber');
        }
      } else if (transferType === 'swiss') {
        if (!swissIban.trim()) {
          newErrors.swissIban = required('swissIban');
        }
        if (!clearingNumber.trim()) {
          newErrors.clearingNumber = required('clearingNumber');
        }
      } else if (transferType === 'uk') {
        if (!routingNumber.trim()) {
          newErrors.routingNumber = required('sortCode');
        }
        if (!accountNumber.trim()) {
          newErrors.accountNumber = required('accountNumber');
        }
      } else if (transferType === 'latam') {
        if (!accountNumber.trim()) {
          newErrors.accountNumber = required('accountOrClabe');
        }
        if (!iban.trim()) {
          newErrors.iban = required('bankName');
        }
      } else if (transferType === 'africa') {
        if (!accountNumber.trim()) {
          newErrors.accountNumber = required('accountOrRib');
        }
        if (!bicSwift.trim()) {
          newErrors.bicSwift = required('bankCode');
        }
      } else if (transferType === 'canada') {
        const hasTransit = !!transitNumber.trim();
        const hasInst = !!institutionNumber.trim();
        const hasAcc = !!accountNumber.trim();
        const hasInterac = !!interacEmail.trim();

        const isDirectDepositAttempt = hasTransit || hasInst || hasAcc;
        const isInteracAttempt = hasInterac;

        if (!isDirectDepositAttempt && !isInteracAttempt) {
          newErrors.canadaSelection = transferCopy.canadaSelection;
          newErrors.interacEmail = ' ';
          newErrors.transitNumber = ' ';
          newErrors.institutionNumber = ' ';
          newErrors.accountNumber = ' ';
        } else if (isDirectDepositAttempt) {
          if (!transitNumber.trim()) {
            newErrors.transitNumber = required('transitNumber');
          }
          if (!institutionNumber.trim()) {
            newErrors.institutionNumber = required('institutionNumber');
          }
          if (!accountNumber.trim()) {
            newErrors.accountNumber = required('accountNumber');
          }
        } else if (isInteracAttempt) {
          if (!interacEmail.trim()) {
            newErrors.interacEmail = required('interacEmail');
          } else if (!interacEmail.includes('@')) {
            newErrors.interacEmail = transferCopy.invalidEmail;
          }
        }
      }
    }

    if (Object.keys(newErrors).length > 0) {
      setErrors(newErrors);
      return;
    }

    setErrors({});
    setStep((prev) => Math.min(prev + 1, 3));
  };

  const handlePrevStep = () => {
    setErrors({});
    setStep((prev) => Math.max(prev - 1, 1));
  };

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    if (step < 3) {
      handleNextStep();
      return;
    }

    const newErrors: Record<string, string> = {};
    if (!recipientName.trim()) {
      newErrors.recipientName = required('recipientName');
    }
    if (numericAmount <= 0) {
      newErrors.amountInput = transferCopy.positiveAmount;
    }

    const availableBalance = sourceAccount?.availableBalance ?? sourceAccount?.balance ?? 0;
    if (numericAmount > availableBalance) {
      newErrors.amountInput = `${t.amountToSend}: ${formatDirectCurrency(
        numericAmount,
        sourceAccount?.currency,
        language,
      )}. ${banking.accounts.availableBalance}: ${formatDirectCurrency(
        availableBalance,
        sourceAccount?.currency,
        language,
      )}.`;
    }

    if (Object.keys(newErrors).length > 0) {
      setErrors(newErrors);
      return;
    }

    setErrors({});

    let recipientAccountStr = '';
    if (transferType === 'canada') {
      recipientAccountStr = interacEmail
        ? `Interac: ${interacEmail}`
        : `Inst: ${institutionNumber} | Transit: ${transitNumber} | Acc: ${accountNumber}`;
    } else if (transferType === 'eurozone') {
      recipientAccountStr = iban;
    } else if (transferType === 'usa') {
      recipientAccountStr = `ABA: ${routingNumber} | Acc: ${accountNumber}`;
    } else if (transferType === 'swiss') {
      recipientAccountStr = swissIban;
    } else if (transferType === 'uk') {
      recipientAccountStr = `Sort: ${routingNumber} | Acc: ${accountNumber}`;
    } else if (transferType === 'latam') {
      recipientAccountStr = `Compte/ID: ${accountNumber} | Banque: ${iban}`;
    } else if (transferType === 'africa') {
      recipientAccountStr = `RIB/Acc: ${accountNumber} | BIC: ${bicSwift}`;
    }

    try {
      setIsSubmitting(true);
      setSubmitError('');
      await addTransfer({
        sourceAccountId,
        recipientName,
        recipientAccount: recipientAccountStr,
        transferType,
        amount: numericAmount,
        currency: sourceAccount?.currency,
        convertedAmount: convertedTargetAmount,
        targetCurrency: targetCurr,
        details: {
          institutionNumber,
          transitNumber,
          routingNumber,
          interacEmail,
          bicSwift,
          clearingNumber,
          motive,
        },
      });
      setIsSuccess(true);

      setTimeout(() => {
        setIsSuccess(false);
        setIsTransferModalOpen(false);
        setRecipientName('');
        setStep(1);
      }, 2500);
    } catch {
      setSubmitError(localizedAppError(language, 'SAVE_FAILED'));
    } finally {
      setIsSubmitting(false);
    }
  };

  if (!isTransferModalOpen) return null;

  const stepNames = [transferCopy.stepRecipient, transferCopy.stepDetails, transferCopy.stepAmount];

  return (
    <AnimatePresence>
      <Dialog
        open={isTransferModalOpen}
        onClose={() => setIsTransferModalOpen(false)}
        ariaLabelledBy="wire-transfer-modal-title"
      >
        <DialogBackdrop className="fixed inset-0 z-50 flex items-end justify-center overflow-hidden bg-black/60 pl-[env(safe-area-inset-left)] pr-[env(safe-area-inset-right)] pt-[env(safe-area-inset-top)] backdrop-blur-sm sm:items-center sm:px-4 sm:pb-4 sm:pt-[max(1rem,env(safe-area-inset-top))]">
          <DialogPanel
            as={motion.div}
            initial={{ opacity: 0, scale: 0.95 }}
            animate={{ opacity: 1, scale: 1 }}
            exit={{ opacity: 0, scale: 0.95 }}
            className="relative flex max-h-dvh min-h-0 w-full min-w-0 max-w-2xl flex-col overflow-hidden rounded-t-3xl border border-slate-200 bg-white shadow-2xl sm:max-h-[calc(100dvh-2rem)] sm:rounded-3xl"
          >
          {/* Header */}
          <div className="flex shrink-0 items-center justify-between gap-3 border-b border-slate-800 bg-slate-900 p-4 text-white sm:p-6">
            <div className="flex min-w-0 items-center space-x-3">
              <div className="flex h-10 w-10 shrink-0 items-center justify-center rounded-2xl border border-blue-400/30 bg-blue-500/20 text-blue-400">
                <Send className="w-5 h-5" />
              </div>
              <div className="min-w-0">
                <h3
                  id="wire-transfer-modal-title"
                  className="break-words text-base font-extrabold sm:text-lg"
                >
                  {t.newTransferTitle}
                </h3>
                <p className="break-words text-[11px] text-slate-400 sm:text-xs">
                  {transferCopy.subtitle}
                </p>
              </div>
            </div>
            <button
              type="button"
              onClick={() => setIsTransferModalOpen(false)}
              id="close-transfer-modal-btn"
              className="flex min-h-11 min-w-11 shrink-0 items-center justify-center rounded-xl p-2 text-slate-400 transition hover:bg-white/10 hover:text-white"
              aria-label={copy.common.close}
            >
              <X className="w-5 h-5" />
            </button>
          </div>

          {!isSuccess && (
            /* Steps tracker */
            <div className="grid shrink-0 grid-cols-3 gap-1 border-b border-slate-100 bg-slate-50 px-4 py-3 sm:flex sm:items-center sm:justify-between sm:px-6 sm:py-4">
              {stepNames.map((name, index) => {
                const stepNum = index + 1;
                const isActive = step === stepNum;
                const isCompleted = step > stepNum;
                return (
                  <React.Fragment key={stepNum}>
                    <div className="flex min-w-0 flex-col items-center gap-1 text-center sm:flex-row sm:space-x-2 sm:text-left">
                      <span
                        className={`flex h-6 w-6 shrink-0 items-center justify-center rounded-full text-[11px] font-bold transition-colors ${
                          isCompleted
                            ? 'bg-blue-600 text-white'
                            : isActive
                            ? 'bg-slate-900 text-white'
                            : 'bg-slate-200 text-slate-500'
                        }`}
                      >
                        {isCompleted ? '✓' : stepNum}
                      </span>
                      <span
                        className={`min-w-0 break-words text-[10px] font-bold leading-tight transition-colors sm:text-xs ${
                          isActive ? 'text-slate-900' : 'text-slate-400'
                        }`}
                      >
                        {name}
                      </span>
                    </div>
                    {index < stepNames.length - 1 && (
                      <div className="flex-1 mx-4 h-0.5 bg-slate-200 transition-colors hidden sm:block" />
                    )}
                  </React.Fragment>
                );
              })}
            </div>
          )}

          {isSuccess ? (
            <div className="min-h-0 flex-1 space-y-4 overflow-y-auto overscroll-contain p-4 pb-[max(1rem,env(safe-area-inset-bottom))] text-center sm:p-12">
              <div className="w-16 h-16 bg-emerald-50 text-emerald-600 border border-emerald-200 rounded-full flex items-center justify-center mx-auto">
                <CheckCircle2 className="w-10 h-10" />
              </div>
              <h3 className="break-words text-xl font-extrabold text-slate-900">{t.transferSuccessMsg}</h3>
              <p className="mx-auto max-w-md break-words text-xs text-slate-600 sm:text-sm">
                {banking.common.internalOperationsNotice}{' '}
                {banking.transfers.progressHint}
              </p>
            </div>
          ) : (
            <form onSubmit={handleSubmit} className="flex min-h-0 flex-1 flex-col text-xs sm:text-sm">
              <div className="min-h-0 flex-1 space-y-6 overflow-y-auto overscroll-contain p-4 sm:p-6">
              {(submitError || Object.values(errors).some((err) => err && err.trim() !== '')) && (
                <div className="bg-rose-50 text-rose-800 border border-rose-200/60 p-3.5 rounded-2xl flex items-start space-x-2.5" id="wire-error-banner">
                  <span className="text-base">⚠️</span>
                  <div className="min-w-0 break-words text-xs">
                    <p className="font-bold">
                      {transferCopy.errorIntro}
                    </p>
                    <ul className="list-disc list-inside mt-1 font-medium space-y-0.5">
                      {submitError && <li>{submitError}</li>}
                      {Object.values(errors).filter((err) => err && err.trim() !== '').map((err, idx) => (
                        <li key={idx}>{err}</li>
                      ))}
                    </ul>
                  </div>
                </div>
              )}
              <AnimatePresence mode="wait">
                {step === 1 && (
                  <motion.div
                    key="step1"
                    initial={{ opacity: 0, x: 10 }}
                    animate={{ opacity: 1, x: 0 }}
                    exit={{ opacity: 0, x: -10 }}
                    transition={{ duration: 0.15 }}
                    className="space-y-5"
                  >
                    {/* Destination Selector */}
                    <div className="space-y-1.5">
                      <label className="block font-bold text-slate-800">{t.destinationType}</label>
                      <select
                        value={transferType}
                        onChange={(e) => {
                          setTransferType(e.target.value as TransferType);
                          setTargetCurrOverride(null);
                          setErrors({});
                        }}
                        id="select-transfer-destination"
                        className="w-full px-3.5 py-3 rounded-2xl border border-slate-200 bg-slate-50 text-slate-900 font-bold focus:ring-2 focus:ring-blue-500 outline-none transition-all cursor-pointer text-sm"
                      >
                        <option value="canada">🇨🇦 {transferCopy.destinationCanada}</option>
                        <option value="eurozone">🇪🇺 {transferCopy.destinationEurozone}</option>
                        <option value="usa">🇺🇸 {transferCopy.destinationUsa}</option>
                        <option value="swiss">🇨🇭 {transferCopy.destinationSwiss}</option>
                        <option value="uk">🇬🇧 {transferCopy.destinationUk}</option>
                        <option value="latam">🌎 {transferCopy.destinationLatam}</option>
                        <option value="africa">🌍 {transferCopy.destinationAfrica}</option>
                      </select>
                    </div>

                    {/* Source Account & Recipient Name */}
                    <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
                      <div>
                        <label className="block font-bold text-slate-800 mb-1">{t.sourceAccount}</label>
                        <select
                          value={sourceAccountId}
                          onChange={(e) => setSourceAccountId(e.target.value)}
                          id="wire-source-account-select"
                          className="w-full px-3.5 py-2.5 rounded-xl border border-slate-200 bg-slate-50 text-slate-900 font-bold focus:ring-2 focus:ring-blue-500 outline-none"
                        >
                          {accounts.map((acc) => (
                            <option key={acc.id} value={acc.id} className="bg-white text-slate-900">
                              {accountTypeLabel(language, acc.accountType)} — {banking.accounts.availableBalance}:{' '}
                              {formatDirectCurrency(
                                acc.availableBalance ?? acc.balance,
                                acc.currency,
                                language,
                              )}
                            </option>
                          ))}
                        </select>
                      </div>

                      <div>
                        <label className="block font-bold text-slate-800 mb-1">{t.recipientName} *</label>
                        <input
                          type="text"
                          required
                          placeholder={transferCopy.recipientPlaceholder}
                          value={recipientName}
                          onChange={(e) => {
                            setRecipientName(e.target.value);
                            clearError('recipientName');
                          }}
                          id="wire-recipient-name-input"
                          className={`w-full px-3.5 py-2.5 rounded-xl border bg-slate-50 text-slate-900 placeholder-slate-400 font-bold focus:ring-2 outline-none transition-colors ${
                            errors.recipientName
                              ? 'border-rose-500 focus:ring-rose-500/20 bg-rose-50/10'
                              : 'border-slate-200 focus:ring-blue-500'
                          }`}
                        />
                        {errors.recipientName && (
                          <p className="text-rose-600 text-xs mt-1.5 font-bold flex items-center" id="error-recipientName">
                            <span className="mr-1">⚠️</span> {errors.recipientName}
                          </p>
                        )}
                      </div>
                    </div>
                  </motion.div>
                )}

                {step === 2 && (
                  <motion.div
                    key="step2"
                    initial={{ opacity: 0, x: 10 }}
                    animate={{ opacity: 1, x: 0 }}
                    exit={{ opacity: 0, x: -10 }}
                    transition={{ duration: 0.15 }}
                    className="space-y-4"
                  >
                    {/* Dynamic Country-Specific Form Fields */}
                    <div className="bg-slate-50 p-4 rounded-2xl border border-slate-200/80 space-y-3">
                      {transferType === 'canada' && (
                        <div className="space-y-3">
                          {errors.canadaSelection && (
                            <p className="text-rose-600 text-xs font-bold bg-rose-50 p-2 rounded-lg border border-rose-100 flex items-center">
                              <span className="mr-1.5">⚠️</span> {errors.canadaSelection}
                            </p>
                          )}
                          <div className="grid grid-cols-1 gap-3 min-[360px]:grid-cols-2 sm:grid-cols-3">
                            <div>
                              <label className="block text-xs font-bold text-slate-700 mb-1">{t.transitNumber} *</label>
                              <input
                                type="text"
                                maxLength={5}
                                value={transitNumber}
                                placeholder="12345"
                                onChange={(e) => {
                                  setTransitNumber(e.target.value.replace(/\D/g, ''));
                                  clearError('transitNumber');
                                  clearError('canadaSelection');
                                }}
                                className={`w-full px-3 py-2 rounded-xl border bg-white text-slate-900 font-mono text-xs focus:ring-2 outline-none transition-colors ${
                                  errors.transitNumber
                                    ? 'border-rose-500 focus:ring-rose-500/20 bg-rose-50/10'
                                    : 'border-slate-200 focus:ring-blue-500'
                                }`}
                              />
                              {errors.transitNumber && errors.transitNumber.trim() !== '' && (
                                <p className="text-rose-600 text-[10px] mt-1 font-bold">⚠️ {errors.transitNumber}</p>
                              )}
                            </div>
                            <div>
                              <label className="block text-xs font-bold text-slate-700 mb-1">{t.institutionNumber} *</label>
                              <input
                                type="text"
                                maxLength={3}
                                value={institutionNumber}
                                placeholder="003"
                                onChange={(e) => {
                                  setInstitutionNumber(e.target.value.replace(/\D/g, ''));
                                  clearError('institutionNumber');
                                  clearError('canadaSelection');
                                }}
                                className={`w-full px-3 py-2 rounded-xl border bg-white text-slate-900 font-mono text-xs focus:ring-2 outline-none transition-colors ${
                                  errors.institutionNumber
                                    ? 'border-rose-500 focus:ring-rose-500/20 bg-rose-50/10'
                                    : 'border-slate-200 focus:ring-blue-500'
                                }`}
                              />
                              {errors.institutionNumber && errors.institutionNumber.trim() !== '' && (
                                <p className="text-rose-600 text-[10px] mt-1 font-bold">⚠️ {errors.institutionNumber}</p>
                              )}
                            </div>
                            <div className="min-[360px]:col-span-2 sm:col-span-1">
                              <label className="block text-xs font-bold text-slate-700 mb-1">{t.accountNumber} *</label>
                              <input
                                type="text"
                                value={accountNumber}
                                placeholder="1234567"
                                onChange={(e) => {
                                  setAccountNumber(e.target.value.replace(/\D/g, ''));
                                  clearError('accountNumber');
                                  clearError('canadaSelection');
                                }}
                                className={`w-full px-3 py-2 rounded-xl border bg-white text-slate-900 font-mono text-xs focus:ring-2 outline-none transition-colors ${
                                  errors.accountNumber
                                    ? 'border-rose-500 focus:ring-rose-500/20 bg-rose-50/10'
                                    : 'border-slate-200 focus:ring-blue-500'
                                }`}
                              />
                              {errors.accountNumber && errors.accountNumber.trim() !== '' && (
                                <p className="text-rose-600 text-[10px] mt-1 font-bold">⚠️ {errors.accountNumber}</p>
                              )}
                            </div>
                          </div>
                          <div className="relative flex py-1 items-center">
                            <div className="flex-grow border-t border-slate-200"></div>
                          <span className="flex-shrink mx-4 text-slate-400 text-[10px] font-bold uppercase">{copy.common.or}</span>
                            <div className="flex-grow border-t border-slate-200"></div>
                          </div>
                          <div>
                            <label className="block text-xs font-bold text-slate-700 mb-1">{t.interacEmail} *</label>
                            <input
                              type="email"
                              placeholder="virement.interac@exemple.ca"
                              value={interacEmail}
                              onChange={(e) => {
                                  setInteracEmail(e.target.value);
                                  clearError('interacEmail');
                                  clearError('canadaSelection');
                                }}
                              className={`w-full px-3 py-2 rounded-xl border bg-white text-slate-900 placeholder-slate-400 text-xs focus:ring-2 outline-none transition-colors ${
                                errors.interacEmail
                                  ? 'border-rose-500 focus:ring-rose-500/20 bg-rose-50/10'
                                  : 'border-slate-200 focus:ring-blue-500'
                              }`}
                            />
                            {errors.interacEmail && errors.interacEmail.trim() !== '' && (
                              <p className="text-rose-600 text-[11px] mt-1 font-bold">⚠️ {errors.interacEmail}</p>
                            )}
                          </div>
                        </div>
                      )}

                      {transferType === 'eurozone' && (
                        <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
                          <div className="sm:col-span-2">
                            <label className="block text-xs font-bold text-slate-700 mb-1">{t.ibanLabel} *</label>
                            <input
                              type="text"
                              value={iban}
                              placeholder="FR76 3000 4012 3456 7890 1234 567"
                              onChange={(e) => {
                                setIban(e.target.value);
                                clearError('iban');
                              }}
                              className={`w-full px-3 py-2 rounded-xl border bg-white text-slate-900 font-mono text-xs focus:ring-2 outline-none transition-colors ${
                                errors.iban
                                  ? 'border-rose-500 focus:ring-rose-500/20 bg-rose-50/10'
                                  : 'border-slate-200 focus:ring-blue-500'
                              }`}
                            />
                            {errors.iban && (
                              <p className="text-rose-600 text-[11px] mt-1 font-bold">⚠️ {errors.iban}</p>
                            )}
                          </div>
                          <div>
                            <label className="block text-xs font-bold text-slate-700 mb-1">{t.bicSwiftLabel} *</label>
                            <input
                              type="text"
                              value={bicSwift}
                              placeholder="BNPAFRPPXXX"
                              onChange={(e) => {
                                setBICSwift(e.target.value);
                                clearError('bicSwift');
                              }}
                              className={`w-full px-3 py-2 rounded-xl border bg-white text-slate-900 font-mono text-xs focus:ring-2 outline-none transition-colors ${
                                errors.bicSwift
                                  ? 'border-rose-500 focus:ring-rose-500/20 bg-rose-50/10'
                                  : 'border-slate-200 focus:ring-blue-500'
                              }`}
                            />
                            {errors.bicSwift && (
                              <p className="text-rose-600 text-[11px] mt-1 font-bold">⚠️ {errors.bicSwift}</p>
                            )}
                          </div>
                        </div>
                      )}

                      {transferType === 'usa' && (
                        <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
                          <div>
                            <label className="block text-xs font-bold text-slate-700 mb-1">{t.routingNumberLabel} *</label>
                            <input
                              type="text"
                              maxLength={9}
                              value={routingNumber}
                              placeholder="123456789"
                              onChange={(e) => {
                                setRoutingNumber(e.target.value.replace(/\D/g, ''));
                                clearError('routingNumber');
                              }}
                              className={`w-full px-3 py-2 rounded-xl border bg-white text-slate-900 font-mono text-xs focus:ring-2 outline-none transition-colors ${
                                errors.routingNumber
                                  ? 'border-rose-500 focus:ring-rose-500/20 bg-rose-50/10'
                                  : 'border-slate-200 focus:ring-blue-500'
                              }`}
                            />
                            {errors.routingNumber && (
                              <p className="text-rose-600 text-[11px] mt-1 font-bold">⚠️ {errors.routingNumber}</p>
                            )}
                          </div>
                          <div>
                            <label className="block text-xs font-bold text-slate-700 mb-1">{t.accountNumber} *</label>
                            <input
                              type="text"
                              value={accountNumber}
                              placeholder="123456789012"
                              onChange={(e) => {
                                setAccountNumber(e.target.value.replace(/\D/g, ''));
                                clearError('accountNumber');
                              }}
                              className={`w-full px-3 py-2 rounded-xl border bg-white text-slate-900 font-mono text-xs focus:ring-2 outline-none transition-colors ${
                                errors.accountNumber
                                  ? 'border-rose-500 focus:ring-rose-500/20 bg-rose-50/10'
                                  : 'border-slate-200 focus:ring-blue-500'
                              }`}
                            />
                            {errors.accountNumber && (
                              <p className="text-rose-600 text-[11px] mt-1 font-bold">⚠️ {errors.accountNumber}</p>
                            )}
                          </div>
                          <div>
                            <label className="block text-xs font-bold text-slate-700 mb-1">{t.transferMethod} *</label>
                            <select
                              value={wireMethod}
                              onChange={(e) => setWireMethod(e.target.value as 'ach' | 'domestic')}
                              className="w-full px-3 py-2 rounded-xl border border-slate-200 bg-white text-slate-900 text-xs focus:ring-2 focus:ring-blue-500 outline-none"
                            >
                              <option value="ach" className="bg-white text-slate-900">{t.wireTypeAch}</option>
                              <option value="domestic" className="bg-white text-slate-900">{t.wireTypeDomestic}</option>
                            </select>
                          </div>
                        </div>
                      )}

                      {transferType === 'swiss' && (
                        <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
                          <div className="sm:col-span-2">
                            <label className="block text-xs font-bold text-slate-700 mb-1">{transferCopy.fields.swissIban} / QR-IBAN *</label>
                            <input
                              type="text"
                              value={swissIban}
                              placeholder="CH93 0023 0230 1234 5678 9"
                              onChange={(e) => {
                                setSwissIban(e.target.value);
                                clearError('swissIban');
                              }}
                              className={`w-full px-3 py-2 rounded-xl border bg-white text-slate-900 font-mono text-xs focus:ring-2 outline-none transition-colors ${
                                errors.swissIban
                                  ? 'border-rose-500 focus:ring-rose-500/20 bg-rose-50/10'
                                  : 'border-slate-200 focus:ring-blue-500'
                              }`}
                            />
                            {errors.swissIban && (
                              <p className="text-rose-600 text-[11px] mt-1 font-bold">⚠️ {errors.swissIban}</p>
                            )}
                          </div>
                          <div>
                            <label className="block text-xs font-bold text-slate-700 mb-1">{transferCopy.fields.clearingNumber} *</label>
                            <input
                              type="text"
                              value={clearingNumber}
                              placeholder="230"
                              onChange={(e) => {
                                setClearingNumber(e.target.value.replace(/\D/g, ''));
                                clearError('clearingNumber');
                              }}
                              className={`w-full px-3 py-2 rounded-xl border bg-white text-slate-900 font-mono text-xs focus:ring-2 outline-none transition-colors ${
                                errors.clearingNumber
                                  ? 'border-rose-500 focus:ring-rose-500/20 bg-rose-50/10'
                                  : 'border-slate-200 focus:ring-blue-500'
                              }`}
                            />
                            {errors.clearingNumber && (
                              <p className="text-rose-600 text-[11px] mt-1 font-bold">⚠️ {errors.clearingNumber}</p>
                            )}
                          </div>
                        </div>
                      )}

                      {transferType === 'uk' && (
                        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
                          <div>
                            <label className="block text-xs font-bold text-slate-700 mb-1">{transferCopy.fields.sortCode} *</label>
                            <input
                              type="text"
                              maxLength={6}
                              placeholder="200415"
                              value={routingNumber}
                              onChange={(e) => {
                                setRoutingNumber(e.target.value.replace(/\D/g, ''));
                                clearError('routingNumber');
                              }}
                              className={`w-full px-3 py-2 rounded-xl border bg-white text-slate-900 font-mono text-xs focus:ring-2 outline-none transition-colors ${
                                errors.routingNumber
                                  ? 'border-rose-500 focus:ring-rose-500/20 bg-rose-50/10'
                                  : 'border-slate-200 focus:ring-blue-500'
                              }`}
                            />
                            {errors.routingNumber && (
                              <p className="text-rose-600 text-[11px] mt-1 font-bold">⚠️ {errors.routingNumber}</p>
                            )}
                          </div>
                          <div>
                            <label className="block text-xs font-bold text-slate-700 mb-1">{transferCopy.fields.accountNumber} *</label>
                            <input
                              type="text"
                              maxLength={8}
                              placeholder="12345678"
                              value={accountNumber}
                              onChange={(e) => {
                                setAccountNumber(e.target.value.replace(/\D/g, ''));
                                clearError('accountNumber');
                              }}
                              className={`w-full px-3 py-2 rounded-xl border bg-white text-slate-900 font-mono text-xs focus:ring-2 outline-none transition-colors ${
                                errors.accountNumber
                                  ? 'border-rose-500 focus:ring-rose-500/20 bg-rose-50/10'
                                  : 'border-slate-200 focus:ring-blue-500'
                              }`}
                            />
                            {errors.accountNumber && (
                              <p className="text-rose-600 text-[11px] mt-1 font-bold">⚠️ {errors.accountNumber}</p>
                            )}
                          </div>
                        </div>
                      )}

                      {transferType === 'latam' && (
                        <div className="space-y-3">
                          <div className="space-y-1">
                            <label className="block text-xs font-bold text-slate-700">{transferCopy.receivingCurrency} *</label>
                            <div className="flex flex-wrap gap-2 pt-1">
                              {[
                                { code: 'BRL', flag: '🇧🇷', label: 'BRL (Brésil)' },
                                { code: 'MXN', flag: '🇲🇽', label: 'MXN (Mexique)' },
                                { code: 'ARS', flag: '🇦🇷', label: 'ARS (Argentine)' },
                                { code: 'COP', flag: '🇨🇴', label: 'COP (Colombie)' },
                                { code: 'CLP', flag: '🇨🇱', label: 'CLP (Chili)' },
                                { code: 'PEN', flag: '🇵🇪', label: 'PEN (Pérou)' },
                                { code: 'UYU', flag: '🇺🇾', label: 'UYU (Uruguay)' },
                                { code: 'CRC', flag: '🇨🇷', label: 'CRC (Costa Rica)' },
                                { code: 'PAB', flag: '🇵🇦', label: 'PAB (Panama)' },
                                { code: 'DOP', flag: '🇩🇴', label: 'DOP (Rép. Dominicaine)' },
                                { code: 'USD', flag: '🇪🇨', label: 'USD (Équateur)' },
                              ].map((item) => (
                                <button
                                  key={`${item.code}-${item.flag}`}
                                  type="button"
                                  onClick={() => setTargetCurrOverride(item.code)}
                                  className={`px-3 py-1.5 rounded-xl text-xs font-bold border transition flex items-center space-x-1.5 ${
                                    targetCurr === item.code
                                      ? 'bg-blue-600 border-blue-500 text-white shadow-sm'
                                      : 'bg-white border-slate-200 text-slate-700 hover:bg-slate-50'
                                  }`}
                                  title={`${item.code} (${LATAM_COUNTRIES[item.code]?.[language] || item.code})`}
                                >
                                  <span>{item.flag}</span>
                                  <span>{item.code}</span>
                                </button>
                              ))}
                            </div>
                          </div>
                          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 pt-1">
                            <div>
                              <label className="block text-xs font-bold text-slate-700 mb-1">{transferCopy.accountOrClabe} *</label>
                              <input
                                type="text"
                                placeholder={transferCopy.accountOrClabePlaceholder}
                                value={accountNumber}
                                onChange={(e) => {
                                  setAccountNumber(e.target.value.replace(/[^a-zA-Z0-9-\s]/g, '').toUpperCase());
                                  clearError('accountNumber');
                                }}
                                className={`w-full px-3 py-2 rounded-xl border bg-white text-slate-900 font-mono text-xs focus:ring-2 outline-none transition-colors ${
                                  errors.accountNumber
                                    ? 'border-rose-500 focus:ring-rose-500/20 bg-rose-50/10'
                                    : 'border-slate-200 focus:ring-blue-500'
                                }`}
                              />
                              {errors.accountNumber && (
                                <p className="text-rose-600 text-[11px] mt-1 font-bold">⚠️ {errors.accountNumber}</p>
                              )}
                            </div>
                            <div>
                              <label className="block text-xs font-bold text-slate-700 mb-1">{transferCopy.recipientInstitution} *</label>
                              <input
                                type="text"
                                placeholder="Banco do Brasil, Banamex, Banco de Chile..."
                                value={iban}
                                onChange={(e) => {
                                  setIban(e.target.value);
                                  clearError('iban');
                                }}
                                className={`w-full px-3 py-2 rounded-xl border bg-white text-slate-900 text-xs focus:ring-2 outline-none transition-colors ${
                                  errors.iban
                                    ? 'border-rose-500 focus:ring-rose-500/20 bg-rose-50/10'
                                    : 'border-slate-200 focus:ring-blue-500'
                                }`}
                              />
                              {errors.iban && (
                                <p className="text-rose-600 text-[11px] mt-1 font-bold">⚠️ {errors.iban}</p>
                              )}
                            </div>
                          </div>
                        </div>
                      )}

                      {transferType === 'africa' && (
                        <div className="space-y-3">
                          <div className="space-y-1">
                            <label className="block text-xs font-bold text-slate-700">{transferCopy.receivingCurrency} *</label>
                            <div className="flex flex-wrap gap-2 pt-1">
                              {[
                                { code: 'XOF', flag: '🇸🇳', label: 'Franc CFA (BCEAO)' },
                                { code: 'MAD', flag: '🇲🇦', label: 'MAD (Maroc)' },
                                { code: 'ZAR', flag: '🇿🇦', label: 'ZAR (Afrique du Sud)' },
                                { code: 'EGP', flag: '🇪🇬', label: 'EGP (Égypte)' },
                                { code: 'NGN', flag: '🇳🇬', label: 'NGN (Nigeria)' },
                              ].map((item) => (
                                <button
                                  key={item.code}
                                  type="button"
                                  onClick={() => setTargetCurrOverride(item.code)}
                                  className={`px-3 py-1.5 rounded-xl text-xs font-bold border transition flex items-center space-x-1.5 ${
                                    targetCurr === item.code
                                      ? 'bg-blue-600 border-blue-500 text-white shadow-sm'
                                      : 'bg-white border-slate-200 text-slate-700 hover:bg-slate-50'
                                  }`}
                                >
                                  <span>{item.flag}</span>
                                  <span>{item.code}</span>
                                </button>
                              ))}
                            </div>
                          </div>
                          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 pt-1">
                            <div>
                              <label className="block text-xs font-bold text-slate-700 mb-1">{transferCopy.accountOrRib} *</label>
                              <input
                                type="text"
                                placeholder={transferCopy.accountOrRibPlaceholder}
                                value={accountNumber}
                                onChange={(e) => {
                                  setAccountNumber(e.target.value.replace(/\D/g, ''));
                                  clearError('accountNumber');
                                }}
                                className={`w-full px-3 py-2 rounded-xl border bg-white text-slate-900 font-mono text-xs focus:ring-2 outline-none transition-colors ${
                                  errors.accountNumber
                                    ? 'border-rose-500 focus:ring-rose-500/20 bg-rose-50/10'
                                    : 'border-slate-200 focus:ring-blue-500'
                                }`}
                              />
                              {errors.accountNumber && (
                                <p className="text-rose-600 text-[11px] mt-1 font-bold">⚠️ {errors.accountNumber}</p>
                              )}
                            </div>
                            <div>
                              <label className="block text-xs font-bold text-slate-700 mb-1">{transferCopy.externalBankCode} *</label>
                              <input
                                type="text"
                                placeholder="SGABSNDAKAR, Attijariwafa"
                                value={bicSwift}
                                onChange={(e) => {
                                  setBICSwift(e.target.value);
                                  clearError('bicSwift');
                                }}
                                className={`w-full px-3 py-2 rounded-xl border bg-white text-slate-900 font-mono text-xs focus:ring-2 outline-none transition-colors ${
                                  errors.bicSwift
                                    ? 'border-rose-500 focus:ring-rose-500/20 bg-rose-50/10'
                                    : 'border-slate-200 focus:ring-blue-500'
                                }`}
                              />
                              {errors.bicSwift && (
                                <p className="text-rose-600 text-[11px] mt-1 font-bold">⚠️ {errors.bicSwift}</p>
                              )}
                            </div>
                          </div>
                        </div>
                      )}
                    </div>

                    <div>
                      <label className="block font-bold text-slate-800 mb-1">{transferCopy.transferMotive}</label>
                      <input
                        type="text"
                        placeholder={transferCopy.motivePlaceholder}
                        value={motive}
                        onChange={(e) => setMotive(e.target.value)}
                        className="w-full px-3.5 py-2.5 rounded-xl border border-slate-200 bg-slate-50 text-slate-900 placeholder-slate-400 font-bold focus:ring-2 focus:ring-blue-500 outline-none"
                      />
                    </div>
                  </motion.div>
                )}

                {step === 3 && (
                  <motion.div
                    key="step3"
                    initial={{ opacity: 0, x: 10 }}
                    animate={{ opacity: 1, x: 0 }}
                    exit={{ opacity: 0, x: -10 }}
                    transition={{ duration: 0.15 }}
                    className="space-y-4"
                  >
                    {/* Amount & Real-Time Exchange Rate Conversion Box */}
                    <div className="bg-blue-900 text-white p-4 rounded-2xl space-y-3 border border-blue-800 shadow-md">
                      <div className="flex items-center justify-end">
                        <span className="max-w-full break-all text-right font-mono text-[10px] font-bold text-emerald-300">
                          {sourceAccount
                            ? `1 ${sourceAccount.currency} = ${convertAnyAmount(
                                1,
                                sourceAccount.currency,
                                targetCurr,
                                rates,
                              ).toFixed(4)} ${targetCurr}`
                            : copy.common.unavailable}
                        </span>
                      </div>

                      <div className="grid grid-cols-1 sm:grid-cols-2 gap-3 items-center">
                        <div>
                          <label className="block text-xs text-blue-100 mb-1 font-bold">{t.amountToSend} ({sourceAccount?.currency})</label>
                          <input
                            type="number"
                            required
                            min="1"
                            value={amountInput}
                            onChange={(e) => {
                              setAmountInput(e.target.value);
                              clearError('amountInput');
                            }}
                            id="wire-amount-input"
                            className={`w-full px-3.5 py-2 rounded-xl bg-white/10 text-white font-extrabold text-lg border outline-none focus:ring-2 transition-colors ${
                              errors.amountInput
                                ? 'border-rose-400 focus:ring-rose-500 bg-rose-950/40 text-rose-100'
                                : 'border-white/20 focus:ring-white'
                            }`}
                          />
                          {errors.amountInput && (
                            <p className="text-rose-200 text-xs mt-1 font-semibold">⚠️ {errors.amountInput}</p>
                          )}
                        </div>

                        <div className="bg-blue-950/80 p-3 rounded-xl border border-blue-700">
                          <p className="text-[11px] text-blue-200 mb-0.5 font-bold">{t.amountToReceive} ({targetCurr})</p>
                          <p className="break-words text-lg font-extrabold text-emerald-300 sm:text-xl">
                            {formatDirectCurrency(convertedTargetAmount, targetCurr, language)}
                          </p>
                        </div>
                      </div>

                      <div className="flex flex-col items-start gap-1 border-t border-blue-800/80 pt-2 text-xs text-blue-100 sm:flex-row sm:items-center sm:justify-between">
                        <span className="break-words">{transferCopy.externalFees}: <strong className="text-amber-200">{transferCopy.externalFeesUnknown}</strong></span>
                        <span className="break-words sm:text-right">{interpolate(transferCopy.rateAsOf, { date: formatLocalizedDateTime(rates.updatedAt, language) })}</span>
                      </div>
                    </div>

                    <div className="space-y-1 rounded-2xl border border-slate-200 bg-slate-50 p-3 text-xs text-slate-600 [&_strong]:break-words">
                      <p className="font-bold text-slate-800">{t.newTransferTitle}</p>
                      <p>{transferCopy.beneficiary}: <strong className="text-slate-900">{recipientName}</strong></p>
                      <p>{t.sourceAccount}: <strong className="text-slate-900">{sourceAccount ? accountTypeLabel(language, sourceAccount.accountType) : copy.common.unavailable}</strong></p>
                      {motive && <p>{transferCopy.motive}: <strong className="text-slate-900">{motive}</strong></p>}
                    </div>
                  </motion.div>
                )}
              </AnimatePresence>
              </div>

              {/* Action Buttons */}
              <div className="flex shrink-0 flex-col-reverse gap-2 border-t border-slate-100 p-4 pb-[max(1rem,env(safe-area-inset-bottom))] sm:flex-row sm:items-center sm:justify-between sm:p-6 sm:pb-[max(1.5rem,env(safe-area-inset-bottom))]">
                {step > 1 ? (
                  <button
                    key="back-btn"
                    type="button"
                    onClick={handlePrevStep}
                    className="flex min-h-11 w-full items-center justify-center space-x-1 rounded-xl border border-slate-200 px-4 py-2.5 text-xs font-bold text-slate-600 transition hover:bg-slate-50 sm:w-auto"
                  >
                    <ArrowLeft className="w-3.5 h-3.5" />
                    <span>{copy.common.back}</span>
                  </button>
                ) : (
                  <button
                    key="close-btn"
                    type="button"
                    onClick={() => setIsTransferModalOpen(false)}
                    className="min-h-11 w-full rounded-xl border border-slate-200 px-4 py-2.5 text-xs font-bold text-slate-500 transition hover:bg-slate-50 sm:w-auto"
                  >
                    {t.close}
                  </button>
                )}

                {step < 3 ? (
                  <button
                    key="next-btn"
                    type="button"
                    onClick={handleNextStep}
                    className="flex min-h-11 w-full items-center justify-center space-x-1 rounded-xl bg-slate-900 px-5 py-2.5 text-xs font-extrabold text-white transition hover:bg-slate-800 sm:w-auto"
                  >
                    <span className="whitespace-normal text-center leading-tight">{copy.common.next}</span>
                    <ArrowRight className="w-3.5 h-3.5" />
                  </button>
                ) : (
                  <button
                    key="submit-btn"
                    type="submit"
                    disabled={isSubmitting}
                    id="submit-wire-transfer-btn"
                    className="flex min-h-11 w-full items-center justify-center space-x-2 rounded-xl bg-blue-600 px-5 py-2.5 text-xs font-extrabold text-white shadow-md transition hover:bg-blue-700 disabled:opacity-50 sm:w-auto"
                  >
                    <Send className="w-4 h-4" />
                    <span className="whitespace-normal text-center leading-tight">{isSubmitting ? copy.common.saving : transferCopy.saveInstruction}</span>
                  </button>
                )}
              </div>
            </form>
          )}
          </DialogPanel>
        </DialogBackdrop>
      </Dialog>
    </AnimatePresence>
  );
}
