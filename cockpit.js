.pragma library

// The Omarchy Cockpit state document, validated. This is omagoku's ONE off-machine feed:
// it already sits local on the desktop, is already versioned and timestamped, and already
// already measures the remote machine, so the distant-power readout and the fleet surges
// need no producer, no credential and no change to the machine being watched.
//
// The whole file is about not rendering a number the machine is not currently at.
//
// FRESHNESS IS TWO QUESTIONS, and only one of them is obvious:
//   1. Did the fetcher die?  now - fetched_at. cockpit-stated stamps fetched_at with the
//      local clock, so this is same-clock and survives the local clock being wrong --
//      which it is for the first minute after every boot, precisely when it is looked at.
//   2. Is the fetcher alive but the collector frozen?  cockpit-stated rewrites fetched_at
//      every 30 s on any HTTP 200, even if the remote machine stopped collecting. So generated_at
//      must be seen to ADVANCE, timed against the local clock.
//
// NO CROSS-MACHINE SUBTRACTION ANYWHERE. `now - generated_at` and `now - last_ok` would
// subtract a remote timestamp from a local clock and inherit the skew in full. Within
// document age is `generated_at - last_ok`: two remote timestamps compared to each other.

var SNAPSHOT_KEYS = ["status", "trusted", "lastGen", "lastGenSeenAt", "gpu", "fleet"]

var MAX_BYTES = 65536
var FETCH_STALE_S = 90
var FUTURE_SKEW_S = 120
var STALL_S = 300
var GPU_STATES = ["free", "resident_idle", "generating"]

function emptyState() {
    return { status: "empty", trusted: false, lastGen: -1, lastGenSeenAt: -1,
             gpu: null, fleet: null }
}

// A non-usable read PRESERVES the trusted generation and its local stamp, so an outage
// cannot reset the stall clock and buy a second grace period.
function carry(prev, status) {
    return {
        status: status,
        trusted: prev ? prev.trusted === true : false,
        lastGen: prev && prev.lastGen !== undefined ? prev.lastGen : -1,
        lastGenSeenAt: prev && prev.lastGenSeenAt !== undefined ? prev.lastGenSeenAt : -1,
        gpu: null,
        fleet: null
    }
}

function safeNonNegInt(v) {
    return typeof v === "number" && isFinite(v) && v >= 0
        && Math.floor(v) === v && v <= 9007199254740991
}

function parse(text, byteLength, nowSecs, prev) {
    if (!text || typeof text !== "string" || text.length === 0) return carry(prev, "empty")
    if (byteLength !== undefined && byteLength !== null && byteLength > MAX_BYTES)
        return carry(prev, "malformed")

    var w
    try { w = JSON.parse(text) } catch (e) { return carry(prev, "malformed") }
    if (!w || typeof w !== "object") return carry(prev, "malformed")

    if (w.schema_version !== 1) return carry(prev, "malformed")
    if (!(typeof w.fetched_at === "number" && isFinite(w.fetched_at))
        || w.fetched_at > nowSecs + FUTURE_SKEW_S) return carry(prev, "malformed")
    // An UNKNOWN source is not a degraded one -- but degraded must stay reachable, so it is
    // allowlisted here rather than rejected before its own branch below.
    if (w.source !== "aggregator" && w.source !== "degraded") return carry(prev, "malformed")

    if (nowSecs - w.fetched_at > FETCH_STALE_S) return carry(prev, "grey")
    if (w.source === "degraded" || w.doc === null || w.doc === undefined)
        return carry(prev, "degraded")

    var doc = w.doc
    if (!doc || typeof doc !== "object" || doc.schema_version !== 1)
        return carry(prev, "malformed")
    // generated_at gets NO clock comparison, not even a future bound: it is a remote
    // timestamp and any now +/- generated_at inherits the local boot skew.
    if (!safeNonNegInt(doc.generated_at)) return carry(prev, "malformed")

    var limit = doc.collector ? doc.collector.stale_source_limit : undefined
    if (!safeNonNegInt(limit) || limit > 86400) return carry(prev, "malformed")

    var gen = doc.generated_at
    var lastGen, seenAt, trusted
    if (prev && prev.lastGen >= 0) {
        if (gen > prev.lastGen) {
            lastGen = gen; seenAt = nowSecs; trusted = true
        } else if (gen < prev.lastGen) {
            // A rollback is a NEW EPOCH: a collector restarted with a corrected clock must
            // re-earn trust, but must not be muted until the old timestamp is exceeded.
            lastGen = gen; seenAt = nowSecs; trusted = false
        } else {
            lastGen = prev.lastGen; seenAt = prev.lastGenSeenAt; trusted = prev.trusted === true
        }
    } else {
        // Cold start FAILS CLOSED: a first read can never be dated, so nothing renders
        // until generated_at is observed to advance strictly once.
        lastGen = gen; seenAt = nowSecs; trusted = false
    }

    var base = { trusted: trusted, lastGen: lastGen, lastGenSeenAt: seenAt,
                 gpu: null, fleet: null }
    if (trusted && seenAt >= 0 && nowSecs - seenAt > STALL_S) {
        base.status = "stalled"
        return base
    }
    if (!trusted) {
        base.status = "priming"
        return base
    }

    base.status = "ok"
    base.gpu = readGpu(doc, gen, limit)
    base.fleet = readFleet(doc, gen, limit)
    return base
}

// A source in status "error" still carries a fully-formed, entirely plausible, arbitrarily
// old data payload. Every shape check passes. The status and the age are the only defence.
function sourceUsable(src, generatedAt, limit) {
    if (!src || typeof src !== "object") return false
    if (src.status !== "ok") return false
    if (!safeNonNegInt(src.last_ok)) return false
    var age = generatedAt - src.last_ok
    return age >= 0 && age <= limit
}

function readGpu(doc, generatedAt, limit) {
    var src = doc.sources ? doc.sources.gpu : undefined
    // gpu is undocumented in the Cockpit contract and may vanish without a version bump.
    // Absent means render nothing, never a placeholder.
    if (!sourceUsable(src, generatedAt, limit)) return null
    var d = src.data
    if (!d || typeof d !== "object") return null
    var w = d.power_w
    if (!(typeof w === "number" && isFinite(w)) || w < 0 || w > 2000) return null
    return {
        powerW: w,
        state: GPU_STATES.indexOf(d.state) >= 0 ? d.state : "unknown"
    }
}

function readFleet(doc, generatedAt, limit) {
    var src = doc.sources ? doc.sources.agents : undefined
    if (!sourceUsable(src, generatedAt, limit)) return null
    var d = src.data
    if (!d || typeof d !== "object") return null
    var t = d.total
    if (!safeNonNegInt(t) || t > 1000) return null
    // sessions can be {"error": "..."} instead of an array. sessions.length is then
    // undefined and every comparison against it is false, which is a permanent invisible
    // outage rather than a crash. Nothing may index it unguarded.
    return { agents: t, sessions: Array.isArray(d.sessions) ? d.sessions : null }
}
