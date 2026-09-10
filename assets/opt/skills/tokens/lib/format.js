/**
 * tokens skill — SI-compact number formatter for the recap table.
 *
 * Rule: 3 significant digits, trim trailing zeros, ≤ 4 chars total.
 * The USD variant appends `$` and enables 3-sig-fig rendering for values
 * under 1000 (≤ 5 chars). Reclassifies AFTER rounding so `999999` renders
 * `1M`, not `1000K` — the tier bump respects the 4-char cap.
 */

/** Suffix per tier (thousand, million, billion, trillion). */
const SUFFIXES = ['', 'K', 'M', 'B', 'T'];

/**
 * Choose decimal count that keeps 3 significant digits after tier scaling.
 * @param {number} scaled  value already divided into its tier
 * @returns {0|1|2}
 */
function decimalsFor(scaled) {
  if (scaled >= 100) return 0;
  if (scaled >= 10) return 1;
  return 2;
}

/**
 * Compute (scaled, dec, rounded) for a given absolute value + tier.
 * @param {number} abs   `Math.abs(n)`
 * @param {number} tier  index into {@link SUFFIXES}
 * @returns {{scaled: number, dec: 0|1|2, rounded: number}}
 */
function format3sig(abs, tier) {
  const scaled = abs / Math.pow(1000, tier);
  const dec = decimalsFor(scaled);
  const rounded = Number(scaled.toFixed(dec));
  return { scaled, dec, rounded };
}

/**
 * SI-compact render of any real number. Handles negatives, zero, cross-tier
 * rounding (`999999 → 1M` not `1000K`).
 *
 * @param {number} n
 * @param {Object} [opts]
 * @param {boolean} [opts.sigFigsBelowK=false]
 *        When true, values under 1000 render with 3 sig figs (e.g.
 *        `1.23` not `1`). Enabled by {@link compactUSD}.
 * @returns {string}  ≤ 4 chars (or ≤ 5 with the trailing `$` via compactUSD)
 */
function compact(n, { sigFigsBelowK = false } = {}) {
  if (n === 0) return '0';
  const neg = n < 0;
  const abs = Math.abs(n);
  const sign = neg ? '-' : '';

  if (abs < 1000 && !sigFigsBelowK) {
    return sign + String(Math.round(abs));
  }

  let tier = abs < 1000 ? 0 : Math.min(Math.floor(Math.log10(abs) / 3), SUFFIXES.length - 1);
  let { dec, rounded } = format3sig(abs, tier);

  if (rounded >= 1000 && tier < SUFFIXES.length - 1) {
    tier += 1;
    ({ dec, rounded } = format3sig(abs, tier));
  }

  let s = rounded.toFixed(dec);
  if (s.includes('.')) s = s.replace(/0+$/, '').replace(/\.$/, '');
  return sign + s + SUFFIXES[tier];
}

/**
 * SI-compact USD render. Same rules as {@link compact} but with 3-sig-fig
 * rendering below 1000 and a trailing `$`.
 * @param {number} n
 * @returns {string}
 */
function compactUSD(n) {
  return compact(n, { sigFigsBelowK: true }) + '$';
}

module.exports = { compact, compactUSD };

if (require.main === module) {
  const assert = require('node:assert/strict');
  const cases = [
    [0, '0'],
    [12, '12'],
    [999, '999'],
    [1000, '1K'],
    [1234, '1.23K'],
    [12345, '12.3K'],
    [123456, '123K'],
    [999999, '1M'],
    [1234567, '1.23M'],
    [12345678, '12.3M'],
    [999999999, '1B'],
    [1234567890, '1.23B'],
  ];
  for (const [input, expected] of cases) {
    assert.equal(compact(input), expected, `compact(${input})`);
  }
  const usdCases = [
    [0, '0$'],
    [1.23, '1.23$'],
    [12345, '12.3K$'],
    [999999, '1M$'],
  ];
  for (const [input, expected] of usdCases) {
    assert.equal(compactUSD(input), expected, `compactUSD(${input})`);
  }
  console.log(`lib/format.js: ${cases.length + usdCases.length}/${cases.length + usdCases.length} ok`);
}
