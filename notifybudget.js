.pragma library

// The notification pipeline's two pure layers.
//
// Layer 1, source reducers (latchCross, countLatch, rungRise, boolEdge): each owns its
// source's latch state, sees the raw measurement, and says whether a candidate fires.
// A reducer fed an unknown measurement removes nothing here -- it PRESERVES its latch,
// so an outage that recovers high cannot mint a fresh notification.
//
// Layer 2, the budget (decide): sees only typed candidates {source, cls}, never a
// measurement. It owns the rolling cap, the spacing rule, per-source cooldowns and
// chatter's subordination. Drop means drop; nothing queues or replays.
//
// State persists to omagoku-notify.json. On load, every time-bearing field is validated
// INDEPENDENTLY: malformed or implausibly-future values cold-start that one field, while
// merely old values are normal (expired sends prune, an elapsed cooldown has elapsed).

var VERSION = 1
var CAP = 4
// Non-care traffic may occupy at most 3 of the 4 slots, so a care notification always has
// room. Reserving the slot for "any non-ambient event" was not enough: an over-9000 alert
// or a probe crossing would take it and still block the pet saying it is starving.
var NON_CARE_CAP = 3
var CLASSES = ["care", "event", "ambient", "chatter"]
var WINDOW_MS = 3600000
var MIN_INTERVAL_MS = 120000
var FUTURE_SKEW_MS = 60000
var CHATTER_MIN_MS = 60 * 60000
var CHATTER_SPAN_MS = 120 * 60000
var COOLDOWN_MS = {
    over9000: 6 * 3600000,
    transformation: 10 * 60000,
    hardLanding: 30 * 60000
}
// Lifecycle one-shots skip the minimum interval (rebirth promptly followed by
// "signature locked" is a legitimate sequence) but still count toward the cap.
var SPACING_EXEMPT = { evolution: true, rebirth: true, lineSelection: true }

function emptyState() {
    return {
        version: VERSION,
        // Entries are {t, cls}. A wave-1 file holds bare numbers; loadState migrates them.
        sends: [],
        lastSent: {},
        reducers: {},
        chatter: { nextEligible: 0, bag: null }
    }
}

function validTime(v, nowMs) {
    return typeof v === "number" && isFinite(v) && v >= 0
        && v <= nowMs + FUTURE_SKEW_MS
}

function drawNextChatter(nowMs, rand) {
    var r = (typeof rand === "function") ? Number(rand()) : 0
    if (!isFinite(r) || r < 0 || r > 1) r = 0
    return nowMs + CHATTER_MIN_MS + r * CHATTER_SPAN_MS
}

// Cold-start priming for chatter: the first delay is drawn, not zero, so a restart can
// neither shorten a drawn delay nor fire chatter immediately.
function primeChatter(state, nowMs, rand) {
    var st = state || emptyState()
    if (!st.chatter || typeof st.chatter !== "object") st.chatter = { bag: null }
    st.chatter.nextEligible = drawNextChatter(nowMs, rand)
    return st
}

function loadState(text, nowMs) {
    var st = emptyState()
    var d
    try { d = JSON.parse(text) } catch (e) { return st }
    if (!d || typeof d !== "object") return st

    if (Array.isArray(d.sends)) {
        for (var i = 0; i < d.sends.length; i++) {
            var e = d.sends[i]
            // A wave-1 file stored bare timestamps. Those sends really happened, so they
            // migrate to class "event" rather than being discarded -- dropping one to make
            // room for the care reservation would undercount real notifications. The
            // reservation simply begins to bind once they age out of the rolling hour.
            if (typeof e === "number") {
                if (validTime(e, nowMs) && nowMs - e < WINDOW_MS)
                    st.sends.push({ t: e, cls: "event" })
                continue
            }
            if (!e || typeof e !== "object") continue
            if (!validTime(e.t, nowMs) || nowMs - e.t >= WINDOW_MS) continue
            // An unknown or missing class is demoted to the LEAST privileged one, so a
            // corrupt file can never manufacture care priority.
            st.sends.push({ t: e.t, cls: CLASSES.indexOf(e.cls) >= 0 ? e.cls : "ambient" })
        }
        st.sends.sort(function (a, b) { return a.t - b.t })
    }
    if (d.lastSent && typeof d.lastSent === "object") {
        for (var src in d.lastSent)
            if (validTime(d.lastSent[src], nowMs)) st.lastSent[src] = d.lastSent[src]
    }
    if (d.reducers && typeof d.reducers === "object") {
        // Reducer shapes are re-validated by each reducer on first use; garbage in a
        // slot simply primes that source silently.
        for (var key in d.reducers)
            if (d.reducers[key] && typeof d.reducers[key] === "object")
                st.reducers[key] = d.reducers[key]
    }
    if (d.chatter && typeof d.chatter === "object") {
        var ne = d.chatter.nextEligible
        if (typeof ne === "number" && isFinite(ne) && ne >= 0
            && ne <= nowMs + CHATTER_MIN_MS + CHATTER_SPAN_MS)
            st.chatter.nextEligible = ne
        if (d.chatter.bag && typeof d.chatter.bag === "object")
            st.chatter.bag = d.chatter.bag
    }
    return st
}

function decide(state, candidate, nowMs, rand) {
    var st = state || emptyState()
    var source = candidate && candidate.source ? String(candidate.source) : "unknown"
    var cls = candidate && candidate.cls ? candidate.cls : "event"

    // Save corruption is operationally important: it bypasses everything and is not
    // even bookkept, so it can never crowd out or be crowded out.
    if (cls === "exempt") return { send: true, reason: "exempt", state: st }

    var sends = []
    for (var i = 0; i < st.sends.length; i++) {
        var e = st.sends[i]
        if (nowMs - e.t < WINDOW_MS && e.t <= nowMs + FUTURE_SKEW_MS) sends.push(e)
    }
    st.sends = sends

    var cd = COOLDOWN_MS[source]
    if (cd !== undefined && typeof st.lastSent[source] === "number"
        && nowMs - st.lastSent[source] < cd)
        return { send: false, reason: "cooldown", state: st }

    if (cls === "chatter") {
        var ne = (st.chatter && typeof st.chatter.nextEligible === "number"
                  && isFinite(st.chatter.nextEligible)) ? st.chatter.nextEligible : 0
        if (nowMs < ne) return { send: false, reason: "chatter-cooldown", state: st }
        // Subordinate: chatter may only spend the window's slack, never the capacity an
        // evolution or a dawn event needs. `ambient` shares ONLY this occupancy rule and
        // never touches chatter's eligibility or its shuffle bag.
        if (st.sends.length > 1) return { send: false, reason: "subordinate", state: st }
    }

    if (cls === "care") {
        // Care yields only to care. Checking merely "was the most recent send non-care"
        // would let a spacing-exempt lifecycle event slip between two care sends and hand
        // the second one a free pass past care-to-care spacing.
        var lastCare = -1
        for (var c = 0; c < st.sends.length; c++)
            if (st.sends[c].cls === "care" && st.sends[c].t > lastCare) lastCare = st.sends[c].t
        if (lastCare >= 0 && nowMs - lastCare < MIN_INTERVAL_MS)
            return { send: false, reason: "spacing", state: st }
    } else {
        if (SPACING_EXEMPT[source] !== true && st.sends.length > 0
            && nowMs - st.sends[st.sends.length - 1].t < MIN_INTERVAL_MS)
            return { send: false, reason: "spacing", state: st }
        var nonCare = 0
        for (var n = 0; n < st.sends.length; n++) if (st.sends[n].cls !== "care") nonCare++
        if (nonCare >= NON_CARE_CAP) return { send: false, reason: "cap", state: st }
    }

    if (st.sends.length >= CAP) return { send: false, reason: "cap", state: st }

    st.sends.push({ t: nowMs, cls: cls })
    st.lastSent[source] = nowMs
    if (cls === "chatter") st.chatter.nextEligible = drawNextChatter(nowMs, rand)
    return { send: true, reason: "sent", state: st }
}

// --- source reducers ---------------------------------------------------------

// Upward-crossing latch with a re-arm band and silent priming. Used by over-9000
// (9000/8000), the disk probe (90/85) and need-critical (90/60).
function latchCross(rs, value, high, low) {
    var st = (rs && rs.primed === true && typeof rs.armed === "boolean")
        ? { primed: true, armed: rs.armed } : { primed: false, armed: false }
    var v = Number(value)
    if (value === undefined || value === null || !isFinite(v))
        return { fire: false, state: st }
    if (!st.primed) return { fire: false, state: { primed: true, armed: v < high } }
    if (st.armed && v >= high) return { fire: true, state: { primed: true, armed: false } }
    if (!st.armed && v < low) return { fire: false, state: { primed: true, armed: true } }
    return { fire: false, state: st }
}

// Zero-to-some latch for the failed-units count; re-arms only at a measured zero.
function countLatch(rs, count) {
    var st = (rs && rs.primed === true && typeof rs.armed === "boolean")
        ? { primed: true, armed: rs.armed } : { primed: false, armed: false }
    var c = Number(count)
    if (count === undefined || count === null || !isFinite(c))
        return { fire: false, state: st }
    if (!st.primed) return { fire: false, state: { primed: true, armed: c === 0 } }
    if (st.armed && c > 0) return { fire: true, state: { primed: true, armed: false } }
    if (!st.armed && c === 0) return { fire: false, state: { primed: true, armed: true } }
    return { fire: false, state: st }
}

// Transformation detection: a rise of the EFFECTIVE ki rung held for 60 s. Watching the
// effective rung (not the displayed form) means dawn unmasking an existing rung is not a
// transformation, and `ok: false` re-primes so source recovery announces nothing.
function rungRise(rs, rung, ok, nowMs) {
    var st = { stable: null, pending: null }
    if (rs && typeof rs === "object") {
        if (typeof rs.stable === "number" && isFinite(rs.stable)) st.stable = rs.stable
        if (rs.pending && typeof rs.pending === "object"
            && typeof rs.pending.value === "number"
            && typeof rs.pending.sinceMs === "number"
            && isFinite(rs.pending.sinceMs) && rs.pending.sinceMs <= nowMs)
            st.pending = { value: rs.pending.value, sinceMs: rs.pending.sinceMs }
    }
    if (ok !== true) return { fire: false, state: { stable: null, pending: null } }
    var r = Number(rung)
    if (!isFinite(r)) return { fire: false, state: st }
    if (st.stable === null) return { fire: false, state: { stable: r, pending: null } }
    if (r <= st.stable) return { fire: false, state: { stable: r, pending: null } }
    if (!st.pending || st.pending.value !== r)
        return { fire: false,
                 state: { stable: st.stable, pending: { value: r, sinceMs: nowMs } } }
    if (nowMs - st.pending.sinceMs >= 60000)
        return { fire: true, state: { stable: r, pending: null } }
    return { fire: false, state: st }
}

// Rising/falling edge with silent priming, for moonrise and dawn: restarting mid-moon-
// night must not re-announce the moon.
function boolEdge(rs, active) {
    var a = active === true
    if (!(rs && rs.primed === true && typeof rs.was === "boolean"))
        return { rose: false, fell: false, state: { primed: true, was: a } }
    return { rose: !rs.was && a, fell: rs.was && !a, state: { primed: true, was: a } }
}

// Chatter's shuffle bag: no line repeats until the whole set is exhausted, and the first
// draw of a fresh bag is swapped away from the previous cycle's last line.
function bagDraw(rs, count, rand) {
    var n = Math.max(1, Math.floor(Number(count) || 1))
    var st = (rs && Array.isArray(rs.order) && rs.order.length === n
              && typeof rs.pos === "number" && rs.pos >= 0)
        ? { order: rs.order.slice(), pos: rs.pos, last: rs.last } : null
    if (!st || st.pos >= n) {
        var last = st ? st.last : (rs && typeof rs.last === "number" ? rs.last : undefined)
        var order = []
        for (var i = 0; i < n; i++) order.push(i)
        for (var j = n - 1; j > 0; j--) {
            var r = Math.floor(Number(typeof rand === "function" ? rand() : 0) * (j + 1))
            if (!isFinite(r) || r < 0 || r > j) r = 0
            var tmp = order[j]; order[j] = order[r]; order[r] = tmp
        }
        if (n > 1 && order[0] === last) {
            var t2 = order[0]; order[0] = order[1]; order[1] = t2
        }
        st = { order: order, pos: 0, last: last }
    }
    var index = st.order[st.pos]
    return { index: index, state: { order: st.order, pos: st.pos + 1, last: index } }
}
