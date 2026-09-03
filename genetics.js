.pragma library
.import "lines.js" as Lines

// Breakable genetics: the bucket a bloodline has earned from how its last three grown pets
// were looked after. Derived on every read, never written to a save -- a stored bucket is a
// second number that can disagree with the record it came from.
//
// Two rules govern everything here:
//
//   IT READS ONLY WHAT IS ON DISK. Service promotes lineageState solely on a matching
//   `saved`, so the record this sees is the last one confirmed written. A row that has not
//   landed is not part of the bloodline yet.
//
//   IT NEVER THROWS AND NEVER GUESSES. The result reaches a sprite path through
//   Lines.variantSuffix, so every hostile shape resolves to the neutral bucket with a reason.

var NEUTRAL = 2
var WINDOW = 3

// The care sum of three rows, compared as integers. careAverage is safeInt(v, 100), so the
// three values are integers 0..100 and a mean like 49.333 -- which falls between the integer
// bucket bounds -- cannot arise.
var SUM_BOUNDS = [90, 150, 210, 255]

function result(bucket, reason) { return { bucket: bucket, reason: reason } }

function isPlainObject(v) {
    return v !== null && typeof v === "object" && !(v instanceof Array)
}

// The whole record is trusted or it is not. `partial` means a row could not be READ, and an
// unreadable row carries no readable line, so it could have belonged inside any line's
// window -- there is no tombstone that could prove otherwise.
function bucket(state, line) {
    if (!isPlainObject(state)) return result(NEUTRAL, "unreadable")
    if (!isPlainObject(state.record)) return result(NEUTRAL, "unreadable")
    if (!(state.record.entries instanceof Array)) return result(NEUTRAL, "unreadable")
    if (!Lines.has(line)) return result(NEUTRAL, "unreadable")

    if (state.ready !== true) return result(NEUTRAL, "not-ready")
    if (state.mode === "partial") return result(NEUTRAL, "record-incomplete")
    // `write-failed` carries the last record CONFIRMED on disk -- exactly the input this
    // function asks for. Treating it as unreadable made a full disk change the pet's
    // colours, which is a lie in the opposite direction from the one we were avoiding.
    if (state.mode !== "valid" && state.mode !== "missing" && state.mode !== "write-failed")
        return result(NEUTRAL, "unreadable")

    // Candidacy tests only fields that exist on EVERY entry variant, so a frozen or corrupt
    // adult farewell IS a candidate. That is the point: it must be able to block the window
    // rather than vanish from it.
    var cands = []
    var entries = state.record.entries
    for (var i = 0; i < entries.length; i++) {
        var e = entries[i]
        if (!isPlainObject(e)) continue
        if (e.line !== line) continue
        if (e.endedBy !== "farewell") continue
        if (e.stage !== "adult") continue
        cands.push(e)
    }
    if (cands.length < WINDOW) return result(NEUTRAL, "too-few-farewells")

    // The LAST three by POSITION. Position is arrival order -- upsert pushes, replaces in
    // place on a retry, and drops from the front -- and it is the only monotonic ordering
    // available: endedAt is nullable and goes backwards after a clock rollback.
    var win = cands.slice(cands.length - WINDOW)

    for (var j = 0; j < WINDOW; j++)
        if (win[j].progressMode !== "live") return result(NEUTRAL, "window-unreadable")

    var sum = 0
    for (var k = 0; k < WINDOW; k++) {
        var c = win[k].careAverage
        if (typeof c !== "number" || !isFinite(c)) return result(NEUTRAL, "window-unsampled")
        sum += c
    }

    for (var b = 0; b < SUM_BOUNDS.length; b++)
        if (sum < SUM_BOUNDS[b]) return result(b, "inherited")
    return result(4, "inherited")
}
