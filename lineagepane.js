.pragma library
.import "levels.js" as Levels
.import "lines.js" as Lines

// What the lineage pane may honestly say. Pure, because the pane's hard part is not layout
// but arithmetic over a record with holes in it, and arithmetic is testable.
//
// The rule the whole file exists for: A METRIC IS COMPLETE ONLY IF NOTHING WAS EXCLUDED
// FROM IT. Frozen and corrupt rows carry no numbers, live rows may have no care sample,
// rows we could not read never became entries at all, and the cap silently drops the
// oldest. Each of those excludes a different set, so each metric carries its own
// contributor count rather than sharing one "excluded" flag.

var MAX_ROWS = 8

function isPlainObject(v) {
    return v !== null && typeof v === "object" && !(v instanceof Array)
}

function entriesOf(state) {
    if (!isPlainObject(state) || !isPlainObject(state.record)) return []
    return (state.record.entries instanceof Array) ? state.record.entries : []
}

function countOf(state, key) {
    var n = isPlainObject(state) ? state[key] : 0
    return (typeof n === "number" && isFinite(n) && n > 0) ? Math.floor(n) : 0
}

// Lifespan is rendered ONLY when both stamps exist and the span is non-negative. The stored
// values are milliseconds while ageLabel takes minutes, and two independently valid stamps
// still produce a negative span after a clock rollback.
function lifespanMinutes(e) {
    if (!isPlainObject(e)) return null
    if (typeof e.bornAt !== "number" || typeof e.endedAt !== "number") return null
    var ms = e.endedAt - e.bornAt
    if (!isFinite(ms) || ms < 0) return null
    return Math.floor(ms / 60000)
}

// levelFor is built for ONE curve, so a row from a future curve 2 would render a
// confidently wrong level. An unknown curve shows XP and no level.
function levelOf(e) {
    if (!isPlainObject(e) || e.progressMode !== "live") return null
    if (e.curve !== Levels.CURVE_V) return null
    return Levels.levelFor(e.xp)
}

function aggregate(state) {
    var entries = entriesOf(state)
    var retained = entries.length
    var unreadable = countOf(state, "unreadableRows")
    var dropped = countOf(state, "droppedByCap")
    // Nothing was excluded ANYWHERE. A metric may still be partial on its own count.
    var recordWhole = (unreadable === 0 && dropped === 0)

    var live = []
    for (var i = 0; i < entries.length; i++)
        if (isPlainObject(entries[i]) && entries[i].progressMode === "live")
            live.push(entries[i])

    var balls = 0, wishes = 0
    var careSum = 0, careN = 0
    var peak = null
    for (var j = 0; j < live.length; j++) {
        var e = live[j]
        balls += e.ballsCollected
        wishes += e.wishesGranted
        if (typeof e.careAverage === "number") { careSum += e.careAverage; careN += 1 }
        // Ties go to the most recent, and the array is oldest-first, so >= wins.
        if (peak === null || e.peakKiRung >= peak.tier)
            peak = { tier: e.peakKiRung, label: Lines.rungLabel(e.line, e.peakKiRung),
                     gen: e.gen, line: e.line }
    }

    return {
        retained: retained,
        unreadable: unreadable,
        droppedByCap: dropped,
        // Sums are true LOWER BOUNDS when anything is missing: every unknown contribution
        // is non-negative.
        balls: { value: balls, contributors: live.length,
                 complete: recordWhole && live.length === retained },
        wishes: { value: wishes, contributors: live.length,
                  complete: recordWhole && live.length === retained },
        // A peak is not a bound in either direction, so it is named as partial knowledge.
        peak: { best: peak, contributors: live.length,
                complete: recordWhole && live.length === retained },
        // A mean over a subset bounds the whole in NEITHER direction, so it never carries
        // an inequality -- the qualifier is the denominator instead.
        care: { mean: careN > 0 ? Math.round(careSum / careN) : null,
                contributors: careN,
                complete: recordWhole && careN === retained }
    }
}

// The row count is computed, because there is no maximum scale to test against:
// Style.effectiveSpacingScale is spacingScale * fontScale and neither is bounded. The
// budget comes from the host panel's own clamp, which depends on screen and bar geometry
// only -- never on the content -- so there is no binding loop, and it may reach zero.
function rowsThatFit(availableCardHeight, verticalContentInset, breathingRoom, chrome, pitch) {
    if (typeof pitch !== "number" || !isFinite(pitch) || pitch <= 0) return 0
    var budget = availableCardHeight - verticalContentInset - breathingRoom - chrome
    if (!isFinite(budget)) return 0
    return Math.max(0, Math.min(MAX_ROWS, Math.floor(budget / pitch)))
}

// The most recent rows, oldest-first order preserved for display.
function visibleRows(state, count) {
    var entries = entriesOf(state)
    if (count <= 0) return []
    return entries.slice(Math.max(0, entries.length - count))
}
