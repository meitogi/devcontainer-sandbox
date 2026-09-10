/**
 * tokens skill — pricing lookup with alias → dynamic JSON → hardcoded cascade.
 *
 * Layer order (session 3):
 *   1. `${CLAUDE_HOME}/tokens/model-aliases.json` — unknown model → canonical key
 *   2. `${CLAUDE_HOME}/tokens/pricing.json`       — dynamic (written by refresh-pricing.sh)
 *   3. hardcoded {@link PRICING} dict below       — last-line fallback
 *
 * Both files are read once, memoized in-module, and degrade silently on
 * missing / corrupt content. Consumers only need to call {@link priceFor}
 * or {@link isKnown}.
 *
 * @typedef {Object} PricePoint
 * @property {number} in           USD per 1M input tokens
 * @property {number} cache_read   USD per 1M cache-read tokens
 * @property {number} cache_create USD per 1M cache-write / cache-create tokens
 * @property {number} out          USD per 1M output tokens
 *
 * @typedef {Object} TokenCounts
 * @property {number} in
 * @property {number} cache_read
 * @property {number} cache_create
 * @property {number} out
 *
 * @typedef {Object} PricingFileInfo
 * @property {string}      path       absolute path to pricing.json
 * @property {boolean}     exists     true iff the file was readable
 * @property {?string}     fetched_at ISO timestamp from the file, or null on missing / unparseable
 * @property {?number}     ageDays    now − fetched_at in days, or null when fetched_at is null
 */

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

/**
 * Hardcoded fallback price table, mirror of `lib/capture.py` PRICING_FALLBACK.
 * Values are USD per 1M tokens. Updated only when both this file and the
 * Python mirror are edited together (see the `refresh-pricing.sh` HARDCODED
 * block for the third copy).
 * @type {Object<string, PricePoint>}
 */
const PRICING = {
  'claude-opus-4-7':   { in: 5.00,  cache_read: 0.50, cache_create: 10.00, out: 25.00 },
  'claude-opus-4-6':   { in: 5.00,  cache_read: 0.50, cache_create: 10.00, out: 25.00 },
  'claude-opus-4-5':   { in: 5.00,  cache_read: 0.50, cache_create: 10.00, out: 25.00 },
  'claude-opus-4-1':   { in: 15.00, cache_read: 1.50, cache_create: 30.00, out: 75.00 },
  'claude-sonnet-4-6': { in: 3.00,  cache_read: 0.30, cache_create: 6.00,  out: 15.00 },
  'claude-sonnet-4-5': { in: 3.00,  cache_read: 0.30, cache_create: 6.00,  out: 15.00 },
  'claude-sonnet-4':   { in: 3.00,  cache_read: 0.30, cache_create: 6.00,  out: 15.00 },
  'claude-haiku-4-5':  { in: 1.00,  cache_read: 0.10, cache_create: 2.00,  out: 5.00 },
  'claude-haiku-3-5':  { in: 0.80,  cache_read: 0.08, cache_create: 1.60,  out: 4.00 },
  'claude-haiku-3':    { in: 0.25,  cache_read: 0.03, cache_create: 0.50,  out: 1.25 },
};
/** Model key returned when no cascade layer produces a match. */
const FALLBACK_MODEL = 'claude-opus-4-7';

/** @returns {string} `$CLAUDE_HOME` if set, else `~/.claude`. */
function claudeHome() {
  return process.env.CLAUDE_HOME || path.join(os.homedir(), '.claude');
}
/** @returns {string} absolute path to the dynamic pricing snapshot. */
function pricingPath()  { return path.join(claudeHome(), 'tokens', 'pricing.json'); }
/** @returns {string} absolute path to the model → canonical-key alias map. */
function aliasesPath()  { return path.join(claudeHome(), 'tokens', 'model-aliases.json'); }

let _aliases = null;
let _dynamic = null;
let _fallbackNoticeShown = false;

/**
 * Load `model-aliases.json` once and memoize. Missing / unparseable → `{}`.
 * @returns {Object<string, string>} model-id → canonical-key map
 */
function loadAliases() {
  if (_aliases !== null) return _aliases;
  _aliases = {};
  try {
    const raw = fs.readFileSync(aliasesPath(), 'utf8');
    const parsed = JSON.parse(raw);
    if (parsed && typeof parsed === 'object') _aliases = parsed;
  } catch { /* silent — missing / unparseable degrades to empty */ }
  return _aliases;
}

/**
 * Load `pricing.json` once and memoize. Missing / unparseable → `{prices:null, fetched_at:null}`.
 * @returns {{prices: ?Object<string, PricePoint>, fetched_at: ?string}}
 */
function loadDynamic() {
  if (_dynamic !== null) return _dynamic;
  _dynamic = { prices: null, fetched_at: null };
  try {
    const raw = fs.readFileSync(pricingPath(), 'utf8');
    const parsed = JSON.parse(raw);
    if (parsed && parsed.prices && typeof parsed.prices === 'object') {
      _dynamic.prices = parsed.prices;
      _dynamic.fetched_at = parsed.fetched_at || null;
    }
  } catch { /* silent — missing / unparseable falls through to hardcoded */ }
  return _dynamic;
}

/**
 * Resolve the price point for a model ID using the full cascade.
 * Emits one stderr line the first time a lookup falls to {@link FALLBACK_MODEL}.
 * @param {string} model  Anthropic model ID (e.g. `claude-opus-4-7`)
 * @returns {PricePoint}
 */
function priceFor(model) {
  if (!model) return PRICING[FALLBACK_MODEL];
  const aliases = loadAliases();
  const resolved = aliases[model] || model;
  const dyn = loadDynamic();
  if (dyn.prices && dyn.prices[resolved]) return dyn.prices[resolved];
  for (const key of Object.keys(PRICING)) {
    if (resolved.startsWith(key)) return PRICING[key];
  }
  if (!_fallbackNoticeShown) {
    _fallbackNoticeShown = true;
    process.stderr.write(`warn: no pricing entry for '${model}' — using ${FALLBACK_MODEL} fallback. Run refresh-pricing.sh --reconcile.\n`);
  }
  return PRICING[FALLBACK_MODEL];
}

/**
 * Multiply a token count by a price point.
 * @param {TokenCounts} tokens
 * @param {PricePoint}  prices
 * @returns {number} USD cost
 */
function costUsd(tokens, prices) {
  return (
    tokens.in * prices.in
    + tokens.cache_read * prices.cache_read
    + tokens.cache_create * prices.cache_create
    + tokens.out * prices.out
  ) / 1_000_000;
}

/**
 * Union of every known model key across all three cascade layers.
 * Used by `recap.js` to detect genuinely unknown models before warning.
 * @returns {Set<string>}
 */
function knownModelIds() {
  const aliases = loadAliases();
  const dyn = loadDynamic();
  const s = new Set(Object.keys(PRICING));
  if (dyn.prices) for (const k of Object.keys(dyn.prices)) s.add(k);
  for (const k of Object.keys(aliases)) s.add(k);
  return s;
}

/**
 * Check whether a model resolves to a known price entry (alias, dynamic
 * exact, or hardcoded prefix match) — WITHOUT emitting the fallback notice
 * that {@link priceFor} would.
 * @param {string} model
 * @returns {boolean}
 */
function isKnown(model) {
  if (!model) return false;
  const aliases = loadAliases();
  const resolved = aliases[model] || model;
  const dyn = loadDynamic();
  if (dyn.prices && dyn.prices[resolved]) return true;
  for (const key of Object.keys(PRICING)) {
    if (resolved.startsWith(key)) return true;
  }
  return false;
}

/**
 * Introspect the on-disk `pricing.json`. Used by `recap.js` startup warn.
 * @returns {PricingFileInfo}
 */
function pricingFileInfo() {
  const p = pricingPath();
  let exists = false, fetched_at = null, ageDays = null;
  try {
    const raw = fs.readFileSync(p, 'utf8');
    exists = true;
    try {
      const parsed = JSON.parse(raw);
      fetched_at = parsed.fetched_at || null;
    } catch { /* corrupt — reported as exists but no fetched_at */ }
    if (fetched_at) {
      const t = Date.parse(fetched_at);
      if (!Number.isNaN(t)) ageDays = (Date.now() - t) / 86400000;
    }
  } catch { /* missing */ }
  return { path: p, exists, fetched_at, ageDays };
}

/** Reset memoized loaders. Test-only. @returns {void} */
function _resetCache() { _aliases = null; _dynamic = null; _fallbackNoticeShown = false; }

module.exports = {
  PRICING, FALLBACK_MODEL,
  priceFor, costUsd,
  knownModelIds, isKnown, pricingFileInfo,
  _resetCache,
};

if (require.main === module) {
  const assert = require('node:assert/strict');
  // Baseline: no CLAUDE_HOME override → aliases + dynamic likely empty.
  const p = priceFor('claude-opus-4-7');
  assert.equal(p.in, 5.00);
  assert.equal(p.out, 25.00);
  assert.equal(priceFor('claude-opus-4-7-20260201').in, 5.00, 'prefix match');
  assert.equal(priceFor('').in, PRICING[FALLBACK_MODEL].in, 'empty → fallback');
  const info = pricingFileInfo();
  assert.equal(typeof info.exists, 'boolean');
  assert.equal(typeof info.path, 'string');
  const known = knownModelIds();
  assert.ok(known.has('claude-opus-4-7'));
  assert.equal(isKnown('claude-opus-4-7'), true);
  assert.equal(isKnown('claude-opus-4-7-20260201'), true, 'prefix known');
  assert.equal(isKnown('claude-totally-unknown-99'), false);
  console.log('lib/pricing.js: 8/8 ok');
}
