import type { Currency, CurrencyRates } from './types';
import { languageLocale } from './language';

export const SUPPORTED_CURRENCIES = ['EUR', 'USD', 'CAD', 'CHF', 'GBP'] as const;

export const EXCHANGE_RATE_CURRENCIES = [
  'EUR',
  'USD',
  'CAD',
  'CHF',
  'GBP',
  'MXN',
  'BRL',
  'COP',
  'ARS',
  'CLP',
  'PEN',
  'UYU',
  'CRC',
  'PAB',
  'DOP',
  'XOF',
  'XAF',
  'MAD',
  'ZAR',
  'EGP',
  'NGN',
] as const;

export const FRANKFURTER_PROVIDER = 'Frankfurter v2';
export const STATIC_FALLBACK_PROVIDER = 'Static fallback';

export type ExchangeRateCurrency = (typeof EXCHANGE_RATE_CURRENCIES)[number];
export type ExchangeRateProvider =
  | typeof FRANKFURTER_PROVIDER
  | typeof STATIC_FALLBACK_PROVIDER;

export interface ExchangeRateSnapshot extends CurrencyRates {
  base: 'EUR';
  provider: ExchangeRateProvider;
  date: string;
  rateDates: Record<string, string>;
  fallback: boolean;
  fallbackReason?: string;
}

interface FrankfurterRateRow {
  date: string;
  base: 'EUR';
  quote: ExchangeRateCurrency;
  rate: number;
}

const ISO_DATE_PATTERN = /^(\d{4})-(\d{2})-(\d{2})$/;
const EXCHANGE_RATE_CURRENCY_SET = new Set<string>(EXCHANGE_RATE_CURRENCIES);
const FRANKFURTER_QUOTE_CURRENCY_SET = new Set<string>(
  EXCHANGE_RATE_CURRENCIES.filter((currency) => currency !== 'EUR'),
);

export const FRANKFURTER_QUOTE_CURRENCIES = EXCHANGE_RATE_CURRENCIES.filter(
  (currency): currency is Exclude<ExchangeRateCurrency, 'EUR'> =>
    currency !== 'EUR',
);

export const FRANKFURTER_RATES_URL =
  `https://api.frankfurter.dev/v2/rates?base=EUR&quotes=${
    FRANKFURTER_QUOTE_CURRENCIES.join(',')
  }`;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function isIsoDate(value: unknown): value is string {
  if (typeof value !== 'string') return false;
  const match = ISO_DATE_PATTERN.exec(value);
  if (!match) return false;

  const year = Number(match[1]);
  const month = Number(match[2]);
  const day = Number(match[3]);
  const parsed = new Date(Date.UTC(year, month - 1, day));
  return (
    parsed.getUTCFullYear() === year &&
    parsed.getUTCMonth() === month - 1 &&
    parsed.getUTCDate() === day
  );
}

function isPositiveFiniteNumber(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value) && value > 0;
}

function assertExactCurrencyKeys(
  value: Record<string, unknown>,
  label: string,
) {
  const keys = Object.keys(value);
  if (
    keys.length !== EXCHANGE_RATE_CURRENCIES.length ||
    keys.some((currency) => !EXCHANGE_RATE_CURRENCY_SET.has(currency))
  ) {
    throw new TypeError(`${label} must contain every configured currency exactly once.`);
  }
}

function normalizeCurrencyCode(currency: string, label: string): string {
  if (typeof currency !== 'string') {
    throw new TypeError(`${label} must be a three-letter currency code.`);
  }
  const normalized = currency.trim().toUpperCase();
  if (!/^[A-Z]{3}$/.test(normalized)) {
    throw new TypeError(`${label} must be a three-letter currency code.`);
  }
  return normalized;
}

function assertEuroBasedRates(rates: CurrencyRates) {
  if (rates.base !== 'EUR' || rates.rates.EUR !== 1) {
    throw new RangeError('Exchange-rate snapshots must use EUR as their base currency.');
  }
}

function rateForCurrency(rates: CurrencyRates, currency: string): number {
  assertEuroBasedRates(rates);
  const normalized = normalizeCurrencyCode(currency, 'Currency');
  const rate = rates.rates[normalized];
  if (!isPositiveFiniteNumber(rate)) {
    throw new RangeError(`No valid EUR exchange rate is available for ${normalized}.`);
  }
  return rate;
}

export function isSupportedCurrency(value: unknown): value is Currency {
  return (
    typeof value === 'string' &&
    (SUPPORTED_CURRENCIES as readonly string[]).includes(value)
  );
}

// Explicit emergency fallback. Live conversions normally come from the
// same-origin server route backed by Frankfurter v2.
export const DEFAULT_RATES: ExchangeRateSnapshot = {
  base: 'EUR',
  rates: {
    EUR: 1.0,
    USD: 1.085,
    CAD: 1.482,
    CHF: 0.965,
    GBP: 0.854,
    // Latam
    MXN: 18.25,
    BRL: 5.42,
    COP: 4320.0,
    ARS: 960.0,
    CLP: 1083.93,
    PEN: 3.9,
    UYU: 46.75,
    CRC: 524.68,
    PAB: 1.16,
    DOP: 69.22,
    // Africa
    XOF: 655.95,
    XAF: 655.95,
    MAD: 10.75,
    ZAR: 19.82,
    EGP: 52.45,
    NGN: 1620.0,
  },
  updatedAt: '2026-07-23T00:00:00.000Z',
  provider: STATIC_FALLBACK_PROVIDER,
  date: '2026-07-23',
  rateDates: Object.fromEntries(
    EXCHANGE_RATE_CURRENCIES.map((currency) => [currency, '2026-07-23']),
  ),
  fallback: true,
  fallbackReason:
    'Frankfurter est indisponible ; les taux de secours embarqués sont utilisés.',
};

export function createFallbackCurrencyRates(
  reason = DEFAULT_RATES.fallbackReason,
): ExchangeRateSnapshot {
  const fallbackReason = reason?.trim();
  if (!fallbackReason) {
    throw new TypeError('An explicit fallback reason is required.');
  }

  return {
    ...DEFAULT_RATES,
    rates: { ...DEFAULT_RATES.rates },
    rateDates: { ...DEFAULT_RATES.rateDates },
    fallbackReason,
  };
}

export function parseFrankfurterV2Rates(payload: unknown): ExchangeRateSnapshot {
  if (!Array.isArray(payload)) {
    throw new TypeError('Frankfurter must return an array of rate rows.');
  }
  if (payload.length !== FRANKFURTER_QUOTE_CURRENCIES.length) {
    throw new TypeError('Frankfurter returned an incomplete currency set.');
  }

  const rows = payload as unknown[];
  const rates: Record<string, number> = { EUR: 1 };
  const rateDates: Record<string, string> = {};
  const seenQuotes = new Set<string>();

  for (const candidate of rows) {
    if (!isRecord(candidate)) {
      throw new TypeError('Frankfurter returned an invalid rate row.');
    }
    const { base, date, quote, rate } = candidate;
    if (base !== 'EUR') {
      throw new TypeError('Frankfurter returned a non-EUR base currency.');
    }
    if (
      typeof quote !== 'string' ||
      !FRANKFURTER_QUOTE_CURRENCY_SET.has(quote) ||
      seenQuotes.has(quote)
    ) {
      throw new TypeError('Frankfurter returned an unknown or duplicate quote currency.');
    }
    if (!isIsoDate(date)) {
      throw new TypeError(`Frankfurter returned an invalid rate date for ${quote}.`);
    }
    if (!isPositiveFiniteNumber(rate)) {
      throw new TypeError(`Frankfurter returned an invalid rate for ${quote}.`);
    }

    const row: FrankfurterRateRow = {
      base,
      date,
      quote: quote as ExchangeRateCurrency,
      rate,
    };
    seenQuotes.add(row.quote);
    rates[row.quote] = row.rate;
    rateDates[row.quote] = row.date;
  }

  for (const currency of FRANKFURTER_QUOTE_CURRENCIES) {
    if (!seenQuotes.has(currency)) {
      throw new TypeError(`Frankfurter did not return a rate for ${currency}.`);
    }
  }

  const date = Object.values(rateDates).sort().at(-1);
  if (!date) {
    throw new TypeError('Frankfurter did not return a usable rate date.');
  }
  rateDates.EUR = date;

  return {
    base: 'EUR',
    rates,
    updatedAt: `${date}T00:00:00.000Z`,
    provider: FRANKFURTER_PROVIDER,
    date,
    rateDates,
    fallback: false,
  };
}

export function parseExchangeRateSnapshot(payload: unknown): ExchangeRateSnapshot {
  if (!isRecord(payload)) {
    throw new TypeError('The exchange-rate response must be an object.');
  }
  const {
    base,
    date,
    fallback,
    fallbackReason,
    provider,
    rateDates,
    rates,
    updatedAt,
  } = payload;

  if (base !== 'EUR') {
    throw new TypeError('The exchange-rate response must use EUR as its base.');
  }
  if (!isRecord(rates)) {
    throw new TypeError('The exchange-rate response has no valid rates object.');
  }
  assertExactCurrencyKeys(rates, 'Rates');
  const parsedRates: Record<string, number> = {};
  for (const currency of EXCHANGE_RATE_CURRENCIES) {
    const rate = rates[currency];
    if (!isPositiveFiniteNumber(rate)) {
      throw new TypeError(`The exchange-rate response has an invalid ${currency} rate.`);
    }
    parsedRates[currency] = rate;
  }
  if (parsedRates.EUR !== 1) {
    throw new TypeError('The EUR base rate must equal one.');
  }

  if (!isRecord(rateDates)) {
    throw new TypeError('The exchange-rate response has no valid rate dates.');
  }
  assertExactCurrencyKeys(rateDates, 'Rate dates');
  const parsedRateDates: Record<string, string> = {};
  for (const currency of EXCHANGE_RATE_CURRENCIES) {
    const rateDate = rateDates[currency];
    if (!isIsoDate(rateDate)) {
      throw new TypeError(`The exchange-rate response has an invalid ${currency} date.`);
    }
    parsedRateDates[currency] = rateDate;
  }

  if (!isIsoDate(date) || date !== Object.values(parsedRateDates).sort().at(-1)) {
    throw new TypeError('The exchange-rate response has an inconsistent date.');
  }
  if (
    typeof updatedAt !== 'string' ||
    updatedAt !== `${date}T00:00:00.000Z`
  ) {
    throw new TypeError('The exchange-rate response has an invalid update timestamp.');
  }
  if (typeof fallback !== 'boolean') {
    throw new TypeError('The exchange-rate response must expose its fallback status.');
  }
  const expectedProvider = fallback
    ? STATIC_FALLBACK_PROVIDER
    : FRANKFURTER_PROVIDER;
  if (provider !== expectedProvider) {
    throw new TypeError('The exchange-rate provider does not match its fallback status.');
  }
  if (
    fallback &&
    (typeof fallbackReason !== 'string' || fallbackReason.trim().length === 0)
  ) {
    throw new TypeError('Fallback exchange rates must include an explicit reason.');
  }
  if (!fallback && fallbackReason !== undefined) {
    throw new TypeError('Live exchange rates cannot include a fallback reason.');
  }

  return {
    base,
    rates: parsedRates,
    updatedAt,
    provider: expectedProvider,
    date,
    rateDates: parsedRateDates,
    fallback,
    ...(fallback ? { fallbackReason: fallbackReason as string } : {}),
  };
}

export async function fetchLiveCurrencyRates(): Promise<ExchangeRateSnapshot> {
  try {
    const response = await fetch('/api/exchange-rates', {
      headers: { Accept: 'application/json' },
    });
    if (!response.ok) {
      throw new Error(`Exchange-rate endpoint returned HTTP ${response.status}.`);
    }
    return parseExchangeRateSnapshot(await response.json());
  } catch {
    return createFallbackCurrencyRates(
      'Le service de taux est inaccessible ou a renvoyé une réponse invalide.',
    );
  }
}

export function convertAmount(
  amountInEUR: number,
  targetCurrency: string,
  rates: CurrencyRates = DEFAULT_RATES
): number {
  if (!Number.isFinite(amountInEUR)) {
    throw new TypeError('The amount to convert must be finite.');
  }
  const rate = rateForCurrency(rates, targetCurrency);
  const converted = amountInEUR * rate;
  if (!Number.isFinite(converted)) {
    throw new RangeError('The converted amount is outside the supported numeric range.');
  }
  return converted;
}

export function convertAnyAmount(
  amount: number,
  sourceCurrency: string,
  targetCurrency: string,
  rates: CurrencyRates = DEFAULT_RATES
): number {
  if (!Number.isFinite(amount)) {
    throw new TypeError('The amount to convert must be finite.');
  }
  const rateSrc = rateForCurrency(rates, sourceCurrency);
  const rateTarget = rateForCurrency(rates, targetCurrency);
  // Convert from source currency to EUR base, then from EUR base to target currency
  const amountInEUR = amount / rateSrc;
  const converted = amountInEUR * rateTarget;
  if (!Number.isFinite(converted)) {
    throw new RangeError('The converted amount is outside the supported numeric range.');
  }
  return converted;
}

export function sumConvertedAmounts(
  items: ReadonlyArray<{ amount: number; currency: string }>,
  targetCurrency: string,
  rates: CurrencyRates = DEFAULT_RATES,
): number {
  if (!Array.isArray(items)) {
    throw new TypeError('Converted totals require an array of currency amounts.');
  }
  // Validate the target even when the list is empty.
  rateForCurrency(rates, targetCurrency);

  return items.reduce((total, item, index) => {
    if (!item || typeof item !== 'object') {
      throw new TypeError(`Currency amount at index ${index} is invalid.`);
    }
    const converted = convertAnyAmount(
      item.amount,
      item.currency,
      targetCurrency,
      rates,
    );
    const nextTotal = total + converted;
    if (!Number.isFinite(nextTotal)) {
      throw new RangeError('The converted total is outside the supported numeric range.');
    }
    return nextTotal;
  }, 0);
}

export function formatCurrency(
  amountInEUR: number,
  targetCurrency: Currency = 'EUR',
  rates: CurrencyRates = DEFAULT_RATES,
  locale: string = 'fr-FR'
): string {
  const converted = convertAmount(amountInEUR, targetCurrency, rates);

  return new Intl.NumberFormat(languageLocale(locale), {
    style: 'currency',
    currency: targetCurrency,
    currencyDisplay: 'symbol',
  }).format(converted);
}

export function formatDirectCurrency(
  amount: number,
  currency: string,
  locale: string = 'fr-FR'
): string {
  try {
    return new Intl.NumberFormat(languageLocale(locale), {
      style: 'currency',
      currency,
      currencyDisplay: 'symbol',
    }).format(amount);
  } catch {
    return `${new Intl.NumberFormat(languageLocale(locale)).format(amount)} ${currency}`;
  }
}

export function getDefaultCurrencyByCountry(country: string): Currency {
  const c = (country || '').trim().toLowerCase();
  if (
    c.includes('france') ||
    c.includes('allemagne') ||
    c.includes('espagne') ||
    c.includes('italie') ||
    c.includes('belgique') ||
    c.includes('pays-bas') ||
    c.includes('portugal') ||
    c.includes('autriche') ||
    c.includes('irlande') ||
    c.includes('euro') ||
    c.includes('europe')
  ) {
    return 'EUR';
  }
  if (
    c.includes('suisse') ||
    c.includes('switzerland') ||
    c.includes('chf')
  ) {
    return 'CHF';
  }
  if (
    c.includes('royaume-uni') ||
    c.includes('royaume uni') ||
    c.includes('united kingdom') ||
    c.includes('uk') ||
    c.includes('england') ||
    c.includes('gbp') ||
    c.includes('londres')
  ) {
    return 'GBP';
  }
  if (
    c.includes('canada') ||
    c.includes('cad')
  ) {
    return 'CAD';
  }
  if (
    c.includes('usa') ||
    c.includes('états-unis') ||
    c.includes('etats-unis') ||
    c.includes('united states') ||
    c.includes('america')
  ) {
    return 'USD';
  }
  return 'USD'; // default fallback
}
