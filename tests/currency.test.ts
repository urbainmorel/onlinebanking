import assert from 'node:assert/strict';
import test from 'node:test';
import {
  createFallbackCurrencyRates,
  FRANKFURTER_PROVIDER,
  FRANKFURTER_QUOTE_CURRENCIES,
  parseExchangeRateSnapshot,
  parseFrankfurterV2Rates,
  STATIC_FALLBACK_PROVIDER,
  sumConvertedAmounts,
  convertAmount,
  convertAnyAmount,
} from '../lib/currency';
import type { CurrencyRates } from '../lib/types';

const frankfurterPayload = () =>
  FRANKFURTER_QUOTE_CURRENCIES.map((quote, index) => ({
    date: index === 0 ? '2026-08-07' : '2026-08-08',
    base: 'EUR',
    quote,
    rate: index + 2,
  }));

test('Frankfurter rows become a complete, dated EUR snapshot', () => {
  const snapshot = parseFrankfurterV2Rates(frankfurterPayload());

  assert.equal(snapshot.base, 'EUR');
  assert.equal(snapshot.rates.EUR, 1);
  assert.equal(snapshot.provider, FRANKFURTER_PROVIDER);
  assert.equal(snapshot.date, '2026-08-08');
  assert.equal(snapshot.rateDates.USD, '2026-08-07');
  assert.equal(snapshot.rateDates.EUR, '2026-08-08');
  assert.equal(snapshot.fallback, false);
  assert.equal(Object.keys(snapshot.rates).length, 21);
  assert.deepEqual(parseExchangeRateSnapshot(snapshot), snapshot);
});

test('Frankfurter validation rejects incomplete, duplicate, or invalid rows', () => {
  const complete = frankfurterPayload();
  assert.throws(() => parseFrankfurterV2Rates(complete.slice(1)), /incomplete/i);
  assert.throws(
    () =>
      parseFrankfurterV2Rates([
        ...complete.slice(0, -1),
        { ...complete[0] },
      ]),
    /duplicate/i,
  );
  assert.throws(
    () =>
      parseFrankfurterV2Rates(
        complete.map((row, index) => (index === 0 ? { ...row, rate: 0 } : row)),
      ),
    /invalid rate/i,
  );
  assert.throws(
    () =>
      parseFrankfurterV2Rates(
        complete.map((row, index) =>
          index === 0 ? { ...row, date: '2026-02-31' } : row,
        ),
      ),
    /invalid rate date/i,
  );
});

test('fallback snapshots are explicit and strictly validated', () => {
  const snapshot = createFallbackCurrencyRates('Upstream unavailable.');

  assert.equal(snapshot.provider, STATIC_FALLBACK_PROVIDER);
  assert.equal(snapshot.fallback, true);
  assert.equal(snapshot.fallbackReason, 'Upstream unavailable.');
  assert.deepEqual(parseExchangeRateSnapshot(snapshot), snapshot);

  const unexpectedRate = {
    ...snapshot,
    rates: { ...snapshot.rates, ABC: 1 },
  };
  assert.throws(
    () => parseExchangeRateSnapshot(unexpectedRate),
    /every configured currency/i,
  );
});

test('currency conversions stay EUR-based and never invent a missing rate', () => {
  const rates: CurrencyRates = {
    base: 'EUR',
    rates: { EUR: 1, USD: 2, CAD: 4 },
    updatedAt: '2026-08-08T00:00:00.000Z',
  };

  assert.equal(convertAmount(5, 'USD', rates), 10);
  assert.equal(convertAnyAmount(4, 'CAD', 'USD', rates), 2);
  assert.equal(convertAnyAmount(10, 'usd', 'cad', rates), 20);
  assert.equal(
    sumConvertedAmounts(
      [
        { amount: 4, currency: 'CAD' },
        { amount: 3, currency: 'EUR' },
      ],
      'USD',
      rates,
    ),
    8,
  );

  assert.throws(() => convertAmount(1, 'ABC', rates), /no valid EUR exchange rate/i);
  assert.throws(
    () => convertAnyAmount(1, 'USD', 'GBP', rates),
    /no valid EUR exchange rate/i,
  );
  assert.throws(
    () =>
      convertAnyAmount(1, 'EUR', 'USD', {
        ...rates,
        base: 'USD',
      }),
    /must use EUR/i,
  );
  assert.throws(() => convertAmount(Number.NaN, 'EUR', rates), /finite/i);
});
