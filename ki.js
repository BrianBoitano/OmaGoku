.pragma library

// Everything about deciding whether a ki reading can be trusted, as pure functions.
//
// This is split out of KiSource.qml for one hard reason: Quickshell's QML plugin cannot be
// loaded outside the quickshell binary ("module Quickshell plugin quickshell-coreplugin not
// found"), so a TestCase can never instantiate KiSource. Every rule below is a rule about a
// file the desktop does not control -- staleness, overflow, allowlists, out-of-order reads --
// which is exactly the logic that must not be the untested part.
//
// KiSource.qml keeps the I/O: the watcher, the bounded Process, the timers.

var FORMS = ["base", "ssj", "blue", "ui"]

// The complete snapshot contract. Every producer below returns exactly these keys, and
// KiSource holds the object WHOLE rather than mirroring it field by field -- mirroring is
// what silently dropped acceptedPower and killed three features in production.
var STATE_KEYS = ["status", "acceptedTs", "acceptedForm", "acceptedPower"]

// ki.json's `ts` is Unix SECONDS (1788227478.59), not milliseconds.
var LIMITS = {
    staleS: 300,
    futureSkewS: 120,
    maxBytes: 65536
}

function limitsOr(limits) {
    return {
        staleS: (limits && limits.staleS !== undefined) ? limits.staleS : LIMITS.staleS,
        futureSkewS: (limits && limits.futureSkewS !== undefined)
            ? limits.futureSkewS : LIMITS.futureSkewS,
        maxBytes: (limits && limits.maxBytes !== undefined) ? limits.maxBytes : LIMITS.maxBytes
    }
}

function emptyState() {
    return { status: "missing", acceptedTs: -1, acceptedForm: "base", acceptedPower: null }
}

function rejected(why) {
    // A rejection CLEARS the accepted snapshot. Keeping the last good reading around would
    // let a fossil sit on screen indefinitely after the producer died.
    return { status: why, acceptedTs: -1, acceptedForm: "base", acceptedPower: null }
}

// The only thing callers should render. Anything not currently trustworthy reads as base:
// showing a power level the machine is not actually at is the one failure that matters.
function formOf(state) {
    return (state && state.status === "ok") ? state.acceptedForm : "base"
}

function indexOf(form) {
    var i = FORMS.indexOf(form)
    return i < 0 ? 0 : i
}

// Evaluates one read. Returns the NEW state, or null meaning "keep what you have" -- which
// is how an out-of-order read is ignored without being mistaken for a rejection.
function evaluate(state, text, byteLength, nowSecs, limits) {
    var L = limitsOr(limits)

    // Overflow is decided on BYTES, never on decoded string length: multibyte UTF-8 makes an
    // oversized payload report a SHORTER `length`, so a string-length check lets it through.
    // Checked before parsing, so an oversized payload is never decoded at all.
    if (byteLength !== undefined && byteLength !== null && byteLength > L.maxBytes)
        return rejected("malformed")
    if (!text || text.length === 0) return rejected("missing")
    if ((byteLength === undefined || byteLength === null) && text.length > L.maxBytes)
        return rejected("malformed")

    var d
    try {
        d = JSON.parse(text)
    } catch (e) {
        return rejected("malformed")
    }
    if (!d || typeof d !== "object") return rejected("malformed")

    var ts = Number(d.ts)
    if (d.ts === null || d.ts === undefined || !isFinite(ts) || ts < 0)
        return rejected("malformed")
    if (ts - nowSecs > L.futureSkewS) return rejected("malformed")

    var f = d.form
    // Never let a string from a file become a path component. Anything off the allowlist is
    // not "some other form", it is a reading we do not understand.
    if (typeof f !== "string" || FORMS.indexOf(f) < 0) return rejected("malformed")

    // The monotonic rule comes AFTER validation, deliberately. It exists so a slow read
    // cannot overwrite a newer snapshot -- it is not permission to keep showing a
    // transformation while the file on disk is garbage. Checking it first meant an older
    // MALFORMED reading returned "nothing new" and left a stale `ui` on screen forever,
    // which is exactly the honesty rule this file exists to enforce.
    if (state && state.acceptedTs >= 0 && ts < state.acceptedTs) return null

    // `power` validates INDEPENDENTLY of `form`: a malformed power hides the readout and
    // nothing else, so it can never poison a snapshot carrying a valid form. It must be an
    // actual JSON number ("9000" the string is not a reading), finite, and inside [0, 1e9].
    var p = null
    if (typeof d.power === "number" && isFinite(d.power)
        && d.power >= 0 && d.power <= 1e9)
        p = d.power

    return {
        status: (nowSecs - ts > L.staleS) ? "stale" : "ok",
        acceptedTs: ts,
        acceptedForm: f,
        acceptedPower: p
    }
}

// The only power callers should render: nothing but an ok snapshot with a valid power
// shows a readout, the same fail-closed rule formOf enforces.
function powerOf(state) {
    if (!state || state.status !== "ok") return null
    return (state.acceptedPower === undefined || state.acceptedPower === null)
        ? null : state.acceptedPower
}

// Re-evaluates freshness when the file has not changed, so a producer that simply stopped
// updating goes stale on its own instead of sitting there looking current.
function refreshed(state, nowSecs, limits) {
    if (!state || state.acceptedTs < 0) return null
    var L = limitsOr(limits)
    var want = (nowSecs - state.acceptedTs > L.staleS) ? "stale" : "ok"
    if (state.status === want) return null
    return {
        status: want,
        acceptedTs: state.acceptedTs,
        acceptedForm: state.acceptedForm,
        acceptedPower: (state.acceptedPower === undefined) ? null : state.acceptedPower
    }
}

// --- the sparkline's buckets -------------------------------------------------

// 144 five-minute buckets = twelve hours. A bucket keeps THE COMPLETE sample with the
// maximum power in its interval -- never independent maxima, which could combine a power
// and a rung from different moments into a state that never existed. Bucket indices come
// from the wall clock, so a suspend simply leaves empty buckets: gaps, never interpolated,
// never carried forward.
var BUCKET_MS = 300000
var BUCKET_COUNT = 144

function bucketIndexAt(ms) {
    return Math.floor(ms / BUCKET_MS)
}

// A sample enters only when both its power and its rung are valid; partial samples leave
// the gap alone.
function bucketUpsert(map, nowMs, power, rungIndex) {
    if (!map) return map
    if (power === undefined || power === null || !isFinite(Number(power))) return map
    var r = Number(rungIndex)
    if (!isFinite(r)) return map
    var idx = bucketIndexAt(nowMs)
    var cur = map[idx]
    if (!cur || Number(power) > cur.power) map[idx] = { power: Number(power), rung: r }
    var minKeep = idx - BUCKET_COUNT
    for (var k in map) if (Number(k) < minKeep) delete map[k]
    return map
}

// The 144 CLOSED buckets before the current one, oldest first. The open bucket is
// excluded: a bucket renders once, when it closes.
function bucketSeries(map, nowMs) {
    var end = bucketIndexAt(nowMs)
    var out = []
    for (var i = end - BUCKET_COUNT; i < end; i++) {
        var b = map ? map[i] : undefined
        out.push(b === undefined ? null : b)
    }
    return out
}
