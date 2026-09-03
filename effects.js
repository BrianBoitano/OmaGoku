.pragma library

// The effect lane: aura flares, and from Phase 1 the signature moves too. Deliberately NOT
// the notification budget -- 4/hour and 120 s spacing are calibrated for a persistent
// interrupting toast, while a 10 s flare's irritation is about motion and contiguity.
// Letting a flare spend a notification slot would also invert the priority the arbiter
// encodes when it keeps capacity for events.
//
// THE ENVELOPE. Service writes this state nested under `effects` inside the notify document
// (`flushNotifyState`), and until Phase 1 this module read `lastAdmittedAt` from the document
// ROOT -- so `validPair(undefined, undefined)` was false, every load returned an empty state,
// and the flare's ten-minute spacing never once survived a shell restart. The round-trip test
// now feeds back the exact document Service writes, which is the thing nothing did before.

var FLARE_MS = 10000
var SPACING_MS = 600000
var FUTURE_SKEW_MS = 60000
var MOVE_COOLDOWN_MS = 3600000
var AMBIENT_MIN_MS = 45 * 60000
var AMBIENT_MAX_MS = 90 * 60000
var MAX_TS = 4102444800000
var SCHEMA_V = 1

function emptyState() { return { v: SCHEMA_V, mode: "live", moves: {} } }

function isPlainObject(v) {
    return v !== null && typeof v === "object" && !(v instanceof Array)
}

function validTs(v) {
    return (typeof v === "number" && isFinite(v) && Math.floor(v) === v
            && v >= 0 && v <= MAX_TS) ? v : null
}

// In-flight is DERIVED from an expiring stamp, never stored as a boolean: a bare
// inFlight:true persisted just before a shell crash would suppress every effect forever
// with no event able to clear it. Expiry does the recovery by itself.
function inFlight(state, nowMs) {
    return !!(state && typeof state.admittedUntil === "number" && nowMs < state.admittedUntil)
}

function disabled(state) { return !!(state && state.mode === "disabled") }

function spacingOwed(state, nowMs) {
    return typeof state.lastAdmittedAt === "number"
        && nowMs - state.lastAdmittedAt < SPACING_MS
}

function withAdmission(state, nowMs, untilMs) {
    var st = { v: SCHEMA_V, mode: "live", moves: {} }
    for (var k in state.moves) st.moves[k] = state.moves[k]
    if (typeof state.nextAmbientAt === "number") st.nextAmbientAt = state.nextAmbientAt
    st.lastAdmittedAt = nowMs
    st.admittedUntil = untilMs
    return st
}

function admit(state, nowMs, reducedMotion) {
    var st = state || emptyState()
    if (disabled(st)) return { ok: false, reason: "disabled", state: st }
    if (reducedMotion === true) return { ok: false, reason: "reduced-motion", state: st }
    if (inFlight(st, nowMs)) return { ok: false, reason: "in-flight", state: st }
    if (spacingOwed(st, nowMs)) return { ok: false, reason: "spacing", state: st }
    return { ok: true, reason: "admitted",
             state: withAdmission(st, nowMs, nowMs + FLARE_MS) }
}

// A move shares the lane's in-flight window and its ten-minute spacing with the flare, and
// adds its own per-move hourly cooldown on top. `durationMs` is the geometry's lifetime, so
// admission and animation expire on the SAME number rather than two that can disagree.
//
// Reduced motion returns ok with `static`: suppressing motion is not suppressing the feature.
function admitMove(state, nowMs, reducedMotion, moveId, durationMs, opts) {
    var st = state || emptyState()
    var o = opts || {}
    if (disabled(st)) return { ok: false, reason: "disabled", state: st }
    // No wall-clock admission may be stamped before the 90-second gate opens.
    if (o.clockReady !== true) return { ok: false, reason: "clock", state: st }
    if (inFlight(st, nowMs)) return { ok: false, reason: "in-flight", state: st }
    if (spacingOwed(st, nowMs)) return { ok: false, reason: "spacing", state: st }
    var last = st.moves ? st.moves[moveId] : undefined
    // A future stamp suppresses without being rewritten: a clock that is behind catches up.
    if (typeof last === "number" && (nowMs < last || nowMs - last < MOVE_COOLDOWN_MS))
        return { ok: false, reason: "move-cooldown", state: st }
    var next = withAdmission(st, nowMs, nowMs + durationMs)
    next.moves[moveId] = nowMs
    return { ok: true, reason: "admitted", static: reducedMotion === true, state: next }
}

// The ambient deadline advances after every DUE ATTEMPT, admitted or not. Committing it only
// on success means an overdue attempt retries on every tick, which is a queued move wearing
// an ambient hat.
function drawAmbient(state, nowMs, rand) {
    var r = (rand || Math.random)()
    var st = { v: SCHEMA_V, mode: "live", moves: {} }
    for (var k in (state && state.moves) || {}) st.moves[k] = state.moves[k]
    if (state && typeof state.lastAdmittedAt === "number") st.lastAdmittedAt = state.lastAdmittedAt
    if (state && typeof state.admittedUntil === "number") st.admittedUntil = state.admittedUntil
    st.nextAmbientAt = nowMs + AMBIENT_MIN_MS + Math.round(r * (AMBIENT_MAX_MS - AMBIENT_MIN_MS))
    return st
}

function ambientDue(state, nowMs) {
    if (!state || typeof state.nextAmbientAt !== "number") return false
    return nowMs >= state.nextAmbientAt
}

function validPair(a, b, nowMs) {
    if (validTs(a) === null || validTs(b) === null) return false
    if (a > nowMs + FUTURE_SKEW_MS) return false
    return a <= b && b <= a + FLARE_MS
}

// The corrupt penalty starts from the TRUSTED clock, not from load time: establishing a
// wall-clock admission on the boot clock is exactly what the clock gate forbids.
function armAfterClock(state, nowMs) {
    if (!state || state.mode !== "disabled" || state.raw !== undefined) return state
    return { v: SCHEMA_V, mode: "live", moves: {},
             lastAdmittedAt: nowMs, admittedUntil: nowMs }
}

function toSave(state) {
    if (!state) return {}
    if (state.mode === "disabled") return state.raw !== undefined ? state.raw : {}
    var out = { v: SCHEMA_V, moves: state.moves || {} }
    if (typeof state.lastAdmittedAt === "number") out.lastAdmittedAt = state.lastAdmittedAt
    if (typeof state.admittedUntil === "number") out.admittedUntil = state.admittedUntil
    if (typeof state.nextAmbientAt === "number") out.nextAmbientAt = state.nextAmbientAt
    return out
}

// `disabledState(raw)` with a raw preserves an envelope this build does not understand and
// turns the lane OFF, rather than running cold-start against authority it cannot read.
function disabledState(raw) {
    var st = { v: SCHEMA_V, mode: "disabled", moves: {} }
    if (raw !== undefined) st.raw = raw
    return st
}

function loadState(text, nowMs, opts) {
    var o = opts || {}
    var d
    try { d = JSON.parse(text) } catch (e) { return disabledState(undefined) }
    if (!isPlainObject(d)) return disabledState(undefined)
    var env = d.effects
    // No envelope at all is a normal cold start, not a fault.
    if (env === undefined || env === null) return emptyState()
    if (!isPlainObject(env)) return disabledState(undefined)
    // A version this build does not know: preserved, and the lane stays off until code that
    // understands it runs. Repeated restarts must not keep bypassing its authority.
    if (env.v !== undefined && env.v !== SCHEMA_V) return disabledState(env)

    var st = emptyState()
    // The two stamps are validated TOGETHER and cold-start together: a half-trusted pair is
    // how a corrupt future timestamp mutes the lane indefinitely.
    if (validPair(env.lastAdmittedAt, env.admittedUntil, nowMs)) {
        st.lastAdmittedAt = env.lastAdmittedAt
        st.admittedUntil = env.admittedUntil
    }
    var na = validTs(env.nextAmbientAt)
    if (na !== null) st.nextAmbientAt = na
    // Each cooldown validates INDEPENDENTLY against the roster: dropping the whole map on one
    // bad key turns a single clock anomaly into a burst of admissions.
    if (isPlainObject(env.moves)) {
        for (var id in env.moves) {
            if (o.moveIds instanceof Array && o.moveIds.indexOf(id) < 0) continue
            var t = validTs(env.moves[id])
            if (t !== null) st.moves[id] = t
        }
    }
    return st
}
