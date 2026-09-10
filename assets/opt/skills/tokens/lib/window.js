/**
 * tokens skill — time-window resolvers for the recap CLI.
 *
 * All windows are pure functions returning {@link TimeWindow}. All
 * computation is in UTC — never local time. The Anthropic weekly reset
 * boundary is Saturday 20h UTC.
 *
 * @typedef {Object} TimeWindow
 * @property {number} startEpoch  window start (ms since epoch, inclusive)
 * @property {number} endEpoch    window end   (ms since epoch, exclusive)
 * @property {string} label       human-readable identifier for the header line
 */

/**
 * Window starting at the most recent Saturday 20h UTC and ending at `now`.
 * Handles all 4 edge cases (Sat 19:59, Sat 20:00, Sat 20:01, Sun 00:00).
 * @param {Date} [now=new Date()]
 * @returns {TimeWindow}
 */
function sinceReset(now = new Date()) {
  const nowMs = now.getTime();
  const candidate = new Date(Date.UTC(
    now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), 20, 0, 0, 0
  ));
  const dow = candidate.getUTCDay(); // Sun=0, Mon=1, ..., Sat=6
  if (dow === 6) {
    if (nowMs < candidate.getTime()) {
      candidate.setUTCDate(candidate.getUTCDate() - 7);
    }
  } else {
    candidate.setUTCDate(candidate.getUTCDate() - ((dow + 1) % 7));
  }
  return {
    startEpoch: candidate.getTime(),
    endEpoch: nowMs,
    label: 'since last reset (Sat 20h UTC)',
  };
}

/**
 * Window starting at Monday 00h UTC of the current ISO week and ending at `now`.
 * @param {Date} [now=new Date()]
 * @returns {TimeWindow}
 */
function currentWeek(now = new Date()) {
  const nowMs = now.getTime();
  const candidate = new Date(Date.UTC(
    now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate(), 0, 0, 0, 0
  ));
  const dow = candidate.getUTCDay();
  const backDays = dow === 0 ? 6 : dow - 1; // Sun=6, Mon=0, ..., Sat=5
  candidate.setUTCDate(candidate.getUTCDate() - backDays);
  return {
    startEpoch: candidate.getTime(),
    endEpoch: nowMs,
    label: 'current week (Mon 00h UTC)',
  };
}

/**
 * Window starting at day 1, 00h UTC of the current month and ending at `now`.
 * @param {Date} [now=new Date()]
 * @returns {TimeWindow}
 */
function currentMonth(now = new Date()) {
  const nowMs = now.getTime();
  const start = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1, 0, 0, 0, 0));
  return {
    startEpoch: start.getTime(),
    endEpoch: nowMs,
    label: 'current month',
  };
}

/**
 * Sliding-window window over the last N days or hours.
 * @param {string} spec  e.g. `"7d"`, `"24h"`, `"3h"`
 * @param {Date}   [now=new Date()]
 * @throws {Error} on invalid spec
 * @returns {TimeWindow}
 */
function lastN(spec, now = new Date()) {
  const m = /^(\d+)([dh])$/.exec(spec || '');
  if (!m) throw new Error(`invalid --last spec: ${spec} (expected e.g. 7d, 24h)`);
  const n = parseInt(m[1], 10);
  const unit = m[2];
  const nowMs = now.getTime();
  const ms = unit === 'd' ? n * 86_400_000 : n * 3_600_000;
  return {
    startEpoch: nowMs - ms,
    endEpoch: nowMs,
    label: `last ${n}${unit}`,
  };
}

/**
 * Explicit date range. `toISO` is optional — defaults to `now`.
 * Both bounds are ISO date strings; times default to 00:00:00Z if omitted.
 * @param {string} fromISO
 * @param {?string} toISO
 * @param {Date} [now=new Date()]
 * @throws {Error} on invalid ISO
 * @returns {TimeWindow}
 */
function fromTo(fromISO, toISO, now = new Date()) {
  const start = Date.parse(fromISO);
  if (Number.isNaN(start)) throw new Error(`invalid --from: ${fromISO}`);
  let end;
  if (toISO) {
    end = Date.parse(toISO);
    if (Number.isNaN(end)) throw new Error(`invalid --to: ${toISO}`);
  } else {
    end = now.getTime();
  }
  return {
    startEpoch: start,
    endEpoch: end,
    label: toISO ? `${fromISO} → ${toISO}` : `since ${fromISO}`,
  };
}

/**
 * All-time window: epoch 0 → now.
 * @returns {TimeWindow}
 */
function all() {
  return { startEpoch: 0, endEpoch: Date.now(), label: 'all time' };
}

module.exports = { sinceReset, currentWeek, currentMonth, lastN, fromTo, all };

if (require.main === module) {
  const assert = require('node:assert/strict');
  const iso = (ms) => new Date(ms).toISOString();

  // sinceReset — Sat 20h UTC edges
  {
    const now = new Date('2026-07-11T19:59:00Z'); // Sat 19:59 UTC
    const w = sinceReset(now);
    assert.equal(iso(w.startEpoch), '2026-07-04T20:00:00.000Z', 'Sat 19:59 → previous Sat 20:00');
  }
  {
    const now = new Date('2026-07-11T20:00:00Z'); // Sat 20:00 UTC
    const w = sinceReset(now);
    assert.equal(iso(w.startEpoch), '2026-07-11T20:00:00.000Z', 'Sat 20:00 → this Sat 20:00');
  }
  {
    const now = new Date('2026-07-11T20:01:00Z'); // Sat 20:01 UTC
    const w = sinceReset(now);
    assert.equal(iso(w.startEpoch), '2026-07-11T20:00:00.000Z', 'Sat 20:01 → this Sat 20:00');
  }
  {
    const now = new Date('2026-07-12T00:00:00Z'); // Sun 00:00 UTC
    const w = sinceReset(now);
    assert.equal(iso(w.startEpoch), '2026-07-11T20:00:00.000Z', 'Sun 00:00 → previous Sat 20:00');
  }
  {
    const now = new Date('2026-07-10T14:00:00Z'); // Fri 14:00 UTC
    const w = sinceReset(now);
    assert.equal(iso(w.startEpoch), '2026-07-04T20:00:00.000Z', 'Fri 14:00 → last Sat 20:00');
  }
  {
    const now = new Date('2026-07-06T12:00:00Z'); // Mon 12:00 UTC
    const w = sinceReset(now);
    assert.equal(iso(w.startEpoch), '2026-07-04T20:00:00.000Z', 'Mon 12:00 → last Sat 20:00');
  }

  // currentWeek — Mon 00h UTC
  {
    const now = new Date('2026-07-10T14:00:00Z'); // Fri
    const w = currentWeek(now);
    assert.equal(iso(w.startEpoch), '2026-07-06T00:00:00.000Z', 'Fri → Mon 00:00');
  }
  {
    const now = new Date('2026-07-12T00:00:00Z'); // Sun
    const w = currentWeek(now);
    assert.equal(iso(w.startEpoch), '2026-07-06T00:00:00.000Z', 'Sun → previous Mon 00:00');
  }

  // currentMonth
  {
    const now = new Date('2026-07-10T14:00:00Z');
    const w = currentMonth(now);
    assert.equal(iso(w.startEpoch), '2026-07-01T00:00:00.000Z', 'July → July 1 00:00');
  }

  // lastN
  {
    const now = new Date('2026-07-10T14:00:00Z');
    const w = lastN('7d', now);
    assert.equal(iso(w.startEpoch), '2026-07-03T14:00:00.000Z', 'last 7d');
    assert.equal(w.label, 'last 7d');
  }
  {
    const now = new Date('2026-07-10T14:00:00Z');
    const w = lastN('24h', now);
    assert.equal(iso(w.startEpoch), '2026-07-09T14:00:00.000Z', 'last 24h');
  }

  // fromTo
  {
    const w = fromTo('2026-07-01', '2026-07-05');
    assert.equal(iso(w.startEpoch), '2026-07-01T00:00:00.000Z');
    assert.equal(iso(w.endEpoch), '2026-07-05T00:00:00.000Z');
  }

  // all
  {
    const w = all();
    assert.equal(w.startEpoch, 0);
  }

  console.log('lib/window.js: 13/13 ok');
}
