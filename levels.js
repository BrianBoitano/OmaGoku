.pragma library

// Progression: XP, the curve, every payout ledger, and the save boundary they live at.
//
// Pure on purpose, like transform.js and dragonballs.js. This module owns the numbers that
// can quietly cost a pet weeks of its life -- a reopened payout limit, a level that moved
// under an unchanged save, a counter that came back from disk as a string -- so all of it
// has to be testable without a QML object graph.
//
// Two rules run through everything here:
//
//   STORE XP, DERIVE LEVEL. `level` is never persisted. Both Critical defects this project
//   has had came from two numbers on disk that were supposed to agree.
//
//   AUTHORITY AND ADMISSION LEDGERS FAIL CLOSED; STATISTICS FAIL OPEN. Zeroing a malformed
//   cooldown hands out every payout it was holding back. Zeroing a malformed counter loses
//   a number in the lineage record.

var SCHEMA_V = 1
var CURVE_V = 1
var MAX_LEVEL = 100
var MAX_XP = 100000000
var MAX_TS = 4102444800000        // 2100-01-01, well inside a double
var MAX_CARE_SUM = 1e9
var MAX_CARE_COUNT = 10000000
var MAX_COUNTER = 1000000
var MAX_STREAK = 100000
var CARE_WINDOW_MAX = 12          // 12 awards x 5 XP = the 60/hour cap
var ANNOUNCED_MAX = 15

var CARE_XP = 5
var CARE_KIND_MS = 600000         // one award per kind per ten minutes
var CARE_HOUR_MS = 3600000
var CARE_HOUR_XP = 60
var STREAK_XP = 25
var STREAK_CAP_DAY = 10
var MAINT_COOL_MS = 12 * 3600000
var OVER9000_COOL_MS = 6 * 3600000

var CARE_KINDS = ["feed", "wash", "pet"]
var COOL_KEYS = ["over9000", "disk", "failed", "updates"]
var LATCH_KEYS = ["updates", "failed", "disk", "over9000"]
var DAILY_SOURCES = ["active", "ki", "care", "maint", "hunt", "over9000"]

// Per-source daily caps. These are what make the ceiling in the design doc an actual bound:
// cooldowns shape a source, they do not bound a sum, and ki alone pays 8,640 a day at rung 3.
var DAILY_CAP = {
    active: 780,
    ki: 1500,
    care: 240,
    maint: 500,
    hunt: 1700,
    over9000: 1000
}

// v0 is the contract with a pet that already exists; v1 is what a pet hatched from here on
// grows on. The version also decides whether the level gate applies at all -- see levelCapFor.
var PACING = [
    { baby: 5,  child: 70,  teen: 550,  adult: 1510 },
    { baby: 15, child: 240, teen: 1440, adult: 5760 }
]

// --- the curve --------------------------------------------------------------

// XP to REACH level N. (N - 1), not N: level 1 must cost nothing, or a fresh pet loads at
// level 0. Computed once into a frozen table so a lookup is an integer scan and never a
// floating-point inverse.
var THRESHOLDS = (function () {
    var t = [0]
    for (var n = 1; n <= MAX_LEVEL; n++) t.push(Math.round(60 * Math.pow(n - 1, 1.85)))
    return t
})()

function levelFor(xp) {
    var v = (typeof xp === "number" && isFinite(xp) && xp > 0) ? xp : 0
    for (var n = MAX_LEVEL; n >= 1; n--) if (v >= THRESHOLDS[n]) return n
    return 1
}

function xpIntoLevel(xp) {
    var v = (typeof xp === "number" && isFinite(xp) && xp > 0) ? xp : 0
    return v - THRESHOLDS[levelFor(v)]
}

function xpToNextLevel(xp) {
    var n = levelFor(xp)
    if (n >= MAX_LEVEL) return null
    var v = (typeof xp === "number" && isFinite(xp) && xp > 0) ? xp : 0
    return THRESHOLDS[n + 1] - v
}

// --- validation helpers -----------------------------------------------------

// Typed number only. The general num() loader in Service coerces "5000" and accepts 1.5;
// XP is a counter, not a measurement.
function safeInt(v, max) {
    return (typeof v === "number" && isFinite(v) && Math.floor(v) === v
            && v >= 0 && v <= max) ? v : null
}

// The save is read back with `head -c`, which counts BYTES. A .length check passes a
// multibyte preserved subtree that then writes a file over the cap, and an over-cap file
// resets the pet to an egg on the next load.
function utf8Bytes(s) {
    if (typeof s !== "string") return 0
    var n = 0
    for (var i = 0; i < s.length; i++) {
        var c = s.charCodeAt(i)
        if (c < 0x80) n += 1
        else if (c < 0x800) n += 2
        else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) { n += 4; i++ }
        else n += 3
    }
    return n
}

function isPlainObject(v) {
    return v !== null && typeof v === "object" && !(v instanceof Array)
}

// --- what levels buy --------------------------------------------------------

function rateMultiplier(level) {
    var n = (typeof level === "number" && isFinite(level)) ? level : 1
    return Math.max(0.5, Math.round((1 - 0.01 * (n - 1)) * 100) / 100)
}

function levelCapIndex(level) {
    var n = (typeof level === "number" && isFinite(level)) ? level : 1
    if (n >= 40) return 3
    if (n >= 20) return 2
    if (n >= 8) return 1
    return 0
}

// An INDEX or null, and the two directions are not symmetric on purpose. null means
// UNCAPPED here, so a non-live subtree fails CLOSED to 0 -- the inverse of ceilingOverride,
// where null means "no override" and failing to null is the conservative answer.
//
// A pacing-0 pet is never gated. Every pet alive when this shipped migrates at level 1, and
// gating it would demote an honest Ultra Instinct to Base for weeks while it re-earned a
// rung the machine was already at. Seeding fake migration XP to hide that would be
// fabricating a measurement.
function levelCapFor(state) {
    if (!state || state.mode !== "live" || !state.progress) return 0
    if (state.progress.pacing === 0) return null
    return levelCapIndex(levelFor(state.progress.xp))
}

function multiplierFor(state) {
    if (!state || state.mode !== "live" || !state.progress) return 1
    return rateMultiplier(levelFor(state.progress.xp))
}

function pacingTable(state) {
    var i = (state && state.mode === "live" && state.progress
             && state.progress.pacing === 1) ? 1 : 0
    return PACING[i]
}

// --- the gap-aware latches --------------------------------------------------
//
// Budget.latchCross preserves its state across an unknown measurement, which is right for a
// toast and wrong for a payout: bad -> unknown -> good would pay for a recovery nobody
// observed, and a probe outage across a reboot would mint XP on every source at once.

function emptyLatch() { return { primed: false, armed: false, continuous: false } }

// Continuity is a WITHIN-RUN property. It is persisted only so a mid-run gap survives an
// unrelated field's validation, and it always cold-starts closed: otherwise the first probe
// after a shell restart counts as adjacent to the last sample before it, which is exactly
// the process gap the flag exists to notice.
function loadLatch(rs) {
    if (!isPlainObject(rs)) return emptyLatch()
    if (typeof rs.primed !== "boolean" || typeof rs.armed !== "boolean") return emptyLatch()
    return { primed: rs.primed, armed: rs.armed, continuous: false }
}

function validLatch(rs) {
    return isPlainObject(rs) && typeof rs.primed === "boolean"
        && typeof rs.armed === "boolean"
        && (rs.continuous === undefined || typeof rs.continuous === "boolean")
}

function stepLatch(rs, value, armWhen, fireWhen) {
    var st = isPlainObject(rs)
        ? { primed: rs.primed === true, armed: rs.armed === true,
            continuous: rs.continuous === true }
        : emptyLatch()
    if (typeof value !== "number" || !isFinite(value))
        return { fire: false,
                 state: { primed: st.primed, armed: st.armed, continuous: false } }
    if (!st.primed || !st.continuous)
        return { fire: false,
                 state: { primed: true, armed: armWhen(value), continuous: true } }
    if (st.armed && fireWhen(value))
        return { fire: true, state: { primed: true, armed: false, continuous: true } }
    if (!st.armed && armWhen(value))
        return { fire: false, state: { primed: true, armed: true, continuous: true } }
    return { fire: false, state: st }
}

// Fires when a measurement FALLS: a disk emptying, a unit count reaching zero. Budget's
// latches only fire on the rising edge, which is the opposite event.
function fallLatch(rs, value, fireBelow, armAtOrAbove) {
    return stepLatch(rs, value,
                     function (v) { return v >= armAtOrAbove },
                     function (v) { return v < fireBelow })
}

// The rising edge, for over-9000 XP. Deliberately a SECOND latch: the Wave-1 notification
// keeps its own unknown-preserving one, because silencing the machine alert whenever
// progression is frozen would be a Wave-1 regression caused by a Phase-1 feature.
function riseLatch(rs, value, high, low) {
    return stepLatch(rs, value,
                     function (v) { return v < low },
                     function (v) { return v >= high })
}

// --- civil days -------------------------------------------------------------

// Days from the civil calendar, not from a duration. A DST day is 23 or 25 hours long and
// "exactly one day later" has to survive that, so the streak compares ordinals.
function dayOrdinal(y, m, d) {
    var yy = m <= 2 ? y - 1 : y
    var era = Math.floor((yy >= 0 ? yy : yy - 399) / 400)
    var yoe = yy - era * 400
    var doy = Math.floor((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
    var doe = yoe * 365 + Math.floor(yoe / 4) - Math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
}

function localDayOrdinal(date) {
    return dayOrdinal(date.getFullYear(), date.getMonth() + 1, date.getDate())
}

// --- minting and loading ----------------------------------------------------

function randomId(rand) {
    var r = rand || Math.random
    var out = ""
    while (out.length < 32) out += Math.floor(r() * 0x100000000).toString(16)
    return out.substring(0, 32)
}

function emptyDaily() {
    var by = {}
    for (var i = 0; i < DAILY_SOURCES.length; i++) by[DAILY_SOURCES[i]] = 0
    return { day: null, bySource: by }
}

// A pet begins at exactly one of two mutually exclusive points: load-time migration of a
// save that predates progression (claimedPet), or the egg-to-baby transition.
//
// bornAt is Date.now() at the hatch, or null. It is never hatchedAtMs: that is stamped when
// a POD appears and can precede line selection and hatching by days. A legacy pet gets null
// because its birth was never recorded, and no plausibility bound can invent it -- a wrong
// clock produces plausible wrong values, which is why it is untrusted in the first place.
function mint(opts) {
    var o = opts || {}
    var claimed = o.claimedPet === true
    return {
        v: SCHEMA_V,
        petId: randomId(o.rand),
        curve: CURVE_V,
        pacing: claimed ? 0 : 1,
        bornAt: (!claimed && o.clockReady === true && safeInt(o.nowMs, MAX_TS) !== null)
            ? o.nowMs : null,
        xp: 0,
        announced: [],
        peakRawKiRung: 0,
        ballsLifetime: 0,
        wishes: 0,
        care: { sumAll: 0, countAll: 0 },
        gate: { window: [], last: {} },
        streak: { lastAwardedDay: null, count: 0 },
        cool: {},
        daily: emptyDaily(),
        latch: {}
    }
}

function preserved(mode, raw) { return { mode: mode, progress: null, raw: raw } }

// Total. Never throws, never reports a save problem, never touches a biography field: a save
// that resets a real pet to an egg over a bad XP integer is a worse bug than a lost level.
function load(raw, opts) {
    var o = opts || {}
    if (raw === undefined || raw === null)
        return { mode: "absent", progress: null, raw: null }
    if (!isPlainObject(raw)) return preserved("corrupt", raw)
    // A version or curve this build does not know is a save from a build we do not know.
    // Preserved, not zeroed: an older shell must not permanently destroy a newer one's
    // progression on its next ordinary save.
    if (raw.v !== SCHEMA_V) return preserved("frozen", raw)
    if (raw.curve !== CURVE_V) return preserved("frozen", raw)

    // --- authority and admission ledgers: any failure freezes the subtree
    var xp = safeInt(raw.xp, MAX_XP)
    if (xp === null) return preserved("corrupt", raw)
    if (raw.pacing !== 0 && raw.pacing !== 1) return preserved("corrupt", raw)
    if (typeof raw.petId !== "string" || !/^[0-9a-f]{32}$/.test(raw.petId))
        return preserved("corrupt", raw)

    var gate = readGate(raw.gate)
    if (gate === null) return preserved("corrupt", raw)
    var cool = readCool(raw.cool)
    if (cool === null) return preserved("corrupt", raw)
    var daily = readDaily(raw.daily)
    if (daily === null) return preserved("corrupt", raw)
    var streak = readStreak(raw.streak)
    if (streak === null) return preserved("corrupt", raw)
    var latch = readLatch(raw.latch)
    if (latch === null) return preserved("corrupt", raw)

    // --- statistics: a failure zeroes the field and the subtree stays live. Freezing a
    // whole pet's progression over a bad counter is the larger harm; the cost here is one
    // wrong number in the lineage record.
    var peak = safeInt(raw.peakRawKiRung, 3)
    var balls = safeInt(raw.ballsLifetime, MAX_COUNTER)
    var wishes = safeInt(raw.wishes, MAX_COUNTER)
    var care = readCare(raw.care)
    var bornAt = safeInt(raw.bornAt, MAX_TS)

    return {
        mode: "live",
        raw: raw,
        progress: {
            v: SCHEMA_V,
            petId: raw.petId,
            curve: CURVE_V,
            pacing: raw.pacing,
            bornAt: bornAt,
            xp: xp,
            announced: readAnnounced(raw.announced, o.moveIds),
            peakRawKiRung: peak === null ? 0 : peak,
            ballsLifetime: balls === null ? 0 : balls,
            wishes: wishes === null ? 0 : wishes,
            care: care,
            gate: gate,
            streak: streak,
            cool: cool,
            daily: daily,
            latch: latch
        }
    }
}

function readGate(g) {
    if (g === undefined) return { window: [], last: {} }
    if (!isPlainObject(g)) return null
    if (!(g.window instanceof Array) || g.window.length > CARE_WINDOW_MAX) return null
    var win = []
    for (var i = 0; i < g.window.length; i++) {
        var t = safeInt(g.window[i], MAX_TS)
        if (t === null) return null
        win.push(t)
    }
    if (!isPlainObject(g.last)) return null
    var last = {}
    for (var k = 0; k < CARE_KINDS.length; k++) {
        var v = g.last[CARE_KINDS[k]]
        if (v === undefined) continue
        var ts = safeInt(v, MAX_TS)
        if (ts === null) return null
        last[CARE_KINDS[k]] = ts
    }
    return { window: win, last: last }
}

function readCool(c) {
    if (c === undefined) return {}
    if (!isPlainObject(c)) return null
    var out = {}
    for (var i = 0; i < COOL_KEYS.length; i++) {
        var v = c[COOL_KEYS[i]]
        if (v === undefined) continue
        var ts = safeInt(v, MAX_TS)
        if (ts === null) return null
        out[COOL_KEYS[i]] = ts
    }
    return out
}

function readDaily(d) {
    if (d === undefined) return emptyDaily()
    if (!isPlainObject(d)) return null
    if (d.day !== null && (typeof d.day !== "number" || !isFinite(d.day)
                           || Math.floor(d.day) !== d.day)) return null
    if (!isPlainObject(d.bySource)) return null
    var by = {}
    for (var i = 0; i < DAILY_SOURCES.length; i++) {
        var s = DAILY_SOURCES[i]
        var v = d.bySource[s]
        if (v === undefined) { by[s] = 0; continue }
        var n = safeInt(v, MAX_XP)
        if (n === null) return null
        by[s] = n
    }
    return { day: d.day, bySource: by }
}

function readStreak(s) {
    if (s === undefined) return { lastAwardedDay: null, count: 0 }
    if (!isPlainObject(s)) return null
    if (s.lastAwardedDay !== null
        && (typeof s.lastAwardedDay !== "number" || !isFinite(s.lastAwardedDay)
            || Math.floor(s.lastAwardedDay) !== s.lastAwardedDay)) return null
    var c = safeInt(s.count, MAX_STREAK)
    if (c === null) return null
    return { lastAwardedDay: s.lastAwardedDay, count: c }
}

function readLatch(l) {
    if (l === undefined) return {}
    if (!isPlainObject(l)) return null
    var out = {}
    for (var i = 0; i < LATCH_KEYS.length; i++) {
        var v = l[LATCH_KEYS[i]]
        if (v === undefined) continue
        if (!validLatch(v)) return null
        out[LATCH_KEYS[i]] = loadLatch(v)
    }
    return out
}

function readCare(c) {
    if (!isPlainObject(c)) return { sumAll: 0, countAll: 0 }
    var sum = safeInt(c.sumAll, MAX_CARE_SUM)
    var count = safeInt(c.countAll, MAX_CARE_COUNT)
    // Atomic: half a pair is a state that never existed.
    if (sum === null || count === null) return { sumAll: 0, countAll: 0 }
    return { sumAll: sum, countAll: count }
}

function readAnnounced(a, moveIds) {
    if (!(a instanceof Array)) return []
    var out = []
    for (var i = 0; i < a.length && out.length < ANNOUNCED_MAX; i++) {
        var id = a[i]
        if (typeof id !== "string" || id.length === 0 || id.length > 32) continue
        if (moveIds instanceof Array && moveIds.indexOf(id) < 0) continue
        if (out.indexOf(id) < 0) out.push(id)
    }
    return out
}

// Accepts a load result or a bare progress object. A preserved subtree is written back as
// it arrived: preservation is SEMANTIC, since the document is re-serialised on write and
// lexical form cannot survive a parse.
function toSave(x) {
    if (x === null || x === undefined) return null
    if (isPlainObject(x) && typeof x.mode === "string") {
        if (x.mode === "absent") return null
        if (x.mode === "live") return toSave(x.progress)
        return x.raw
    }
    return {
        v: x.v, petId: x.petId, curve: x.curve, pacing: x.pacing, bornAt: x.bornAt,
        xp: x.xp, announced: x.announced, peakRawKiRung: x.peakRawKiRung,
        ballsLifetime: x.ballsLifetime, wishes: x.wishes,
        care: { sumAll: x.care.sumAll, countAll: x.care.countAll },
        gate: { window: x.gate.window, last: x.gate.last },
        streak: { lastAwardedDay: x.streak.lastAwardedDay, count: x.streak.count },
        cool: x.cool, daily: x.daily, latch: x.latch
    }
}

function clone(p) { return JSON.parse(JSON.stringify(toSave(p))) }

// --- the ledgers ------------------------------------------------------------

// Truncate at the cap rather than dropping the award: a partial payout is honest about what
// was measured, and a dropped one loses the whole event.
function applyDaily(progress, source, amount, ordinal) {
    var p = clone(progress)
    var cap = DAILY_CAP[source]
    if (cap === undefined) return { progress: p, amount: 0 }
    // A new day resets the allowance. A clock that moved BACKWARDS does not, or a rollback
    // would mint a fresh day's worth on demand.
    if (p.daily.day === null || ordinal > p.daily.day) {
        p.daily = emptyDaily()
        p.daily.day = ordinal
    }
    var used = p.daily.bySource[source] || 0
    var granted = Math.max(0, Math.min(amount, cap - used))
    p.daily.bySource[source] = used + granted
    return { progress: p, amount: granted }
}

function applyStreak(progress, ordinal) {
    var p = clone(progress)
    var last = p.streak.lastAwardedDay
    if (last !== null && ordinal <= last)
        return { progress: p, amount: 0 }        // same day, or the clock went backwards
    p.streak.count = (last !== null && ordinal === last + 1) ? p.streak.count + 1 : 1
    p.streak.lastAwardedDay = ordinal
    return { progress: p,
             amount: STREAK_XP * Math.min(p.streak.count, STREAK_CAP_DAY) }
}

// One award per kind per ten minutes, under a rolling 60 XP/hour cap that persists, so
// restarting the shell does not hand the cap back.
function awardCare(progress, kind, nowMs, ordinal) {
    var p = clone(progress)
    if (CARE_KINDS.indexOf(kind) < 0) return { progress: p, amount: 0 }
    var last = p.gate.last[kind]
    // A future stamp suppresses without being rewritten: a clock that is behind catches up.
    if (typeof last === "number" && (nowMs < last || nowMs - last < CARE_KIND_MS))
        return { progress: p, amount: 0 }
    var win = []
    for (var i = 0; i < p.gate.window.length; i++) {
        var t = p.gate.window[i]
        if (t <= nowMs && nowMs - t < CARE_HOUR_MS) win.push(t)
    }
    p.gate.window = win
    if (win.length * CARE_XP >= CARE_HOUR_XP) return { progress: p, amount: 0 }
    var d = applyDaily(p, "care", CARE_XP, ordinal)
    if (d.amount <= 0) return { progress: d.progress, amount: 0 }
    p = d.progress
    p.gate.window.push(nowMs)
    p.gate.last[kind] = nowMs
    return { progress: p, amount: d.amount }
}

// A source's own cooldown, judged independently of whether any toast was sent.
function coolReady(progress, key, nowMs) {
    var last = progress.cool ? progress.cool[key] : undefined
    if (typeof last !== "number") return true
    if (nowMs < last) return false            // future stamp: suppress, do not rewrite
    var span = (key === "over9000") ? OVER9000_COOL_MS : MAINT_COOL_MS
    return nowMs - last >= span
}

// --- the award reducer ------------------------------------------------------
//
// Mutation only. It never notifies, never plays a sound and never writes a file: quiet mode,
// a disabled feature and the notification cap change what the user SEES, never what the pet
// EARNS. One event in, one progress out, so a call site is one reducer call and one write.

function award(progress, event, ctx) {
    var p = clone(progress)
    var awards = []
    var c = ctx || {}
    var e = event || {}

    function pay(source, amount) {
        if (!(amount > 0)) return
        var r = applyDaily(p, source, amount, c.dayOrdinal)
        p = r.progress
        if (r.amount > 0) {
            p.xp = Math.min(MAX_XP, p.xp + r.amount)
            awards.push({ source: source, amount: r.amount })
        }
    }

    if (e.kind === "heartbeat") {
        // The active minute pauses with needs during night rest. The ki rung does not: the
        // machine really is working, and the pet's power being the machine's power is the
        // whole thesis.
        if (e.resting !== true) pay("active", 1)
        if (e.kiStatus === "ok") {
            var rung = safeInt(e.rawKiIndex, 3)
            if (rung !== null) {
                if (rung > 0) pay("ki", 2 * rung)
                if (rung > p.peakRawKiRung) p.peakRawKiRung = rung
            }
        }
        // Lifetime care shares ONE captured sample and ONE predicate with the stage-care
        // sample in the heartbeat, so the two aggregates cannot drift apart.
        if (e.sample === true && typeof e.sampled === "number" && isFinite(e.sampled)) {
            p.care.countAll = Math.min(MAX_CARE_COUNT, p.care.countAll + 1)
            p.care.sumAll = Math.min(MAX_CARE_SUM, p.care.sumAll + e.sampled)
        }
        return { progress: p, awards: awards }
    }

    if (e.kind === "ball") { pay("hunt", 100); return { progress: p, awards: awards } }
    if (e.kind === "summon") { pay("hunt", 1000); return { progress: p, awards: awards } }
    if (e.kind === "over9000") {
        if (!coolReady(p, "over9000", c.nowMs)) return { progress: p, awards: awards }
        p.cool.over9000 = c.nowMs
        pay("over9000", 250)
        return { progress: p, awards: awards }
    }
    if (e.kind === "maint") {
        var key = e.source                       // "disk" | "failed" | "updates"
        if (COOL_KEYS.indexOf(key) < 0 || key === "over9000")
            return { progress: p, awards: awards }
        if (!coolReady(p, key, c.nowMs)) return { progress: p, awards: awards }
        p.cool[key] = c.nowMs
        pay("maint", key === "updates" ? 200 : 150)
        return { progress: p, awards: awards }
    }
    return { progress: p, awards: awards }
}
