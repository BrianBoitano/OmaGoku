.pragma library

// Per-line signature behaviours, driven by real signals.
//
// Two rules matter more than the animations. The dwell window stops a behaviour thrashing
// the sprite's animation restart, and the busy veto means a behaviour can NEVER mask a real
// need -- a meditating Piccolo who is actually starving hides information the care loop
// exists to surface.

var STATE_KEYS = ["active", "holdMs", "dwellMs", "exitMs"]

var ACTIVATE_MS = 5000
var MIN_DWELL_MS = 20000
var EXIT_MS = 5000

function emptyState() { return { active: false, holdMs: 0, dwellMs: 0, exitMs: 0 } }

function next(state, predicate, busy, dtMs) {
    var st = (state && typeof state === "object")
        ? { active: state.active === true, holdMs: state.holdMs || 0,
            dwellMs: state.dwellMs || 0, exitMs: state.exitMs || 0 }
        : emptyState()

    // A real need emote, a care animation, sleep or leaving idle cancels with NO dwell.
    if (busy === true) return emptyState()

    if (!st.active) {
        if (predicate === true) {
            st.holdMs += dtMs
            if (st.holdMs >= ACTIVATE_MS) {
                st.active = true; st.dwellMs = 0; st.exitMs = 0
            }
        } else st.holdMs = 0
        return st
    }

    st.dwellMs += dtMs
    st.exitMs = (predicate === true) ? 0 : st.exitMs + dtMs
    if (st.dwellMs >= MIN_DWELL_MS && st.exitMs >= EXIT_MS) {
        st.active = false; st.holdMs = 0
    }
    return st
}

// --- the predicates, one per line ---------------------------------------------

// Vegeta is furious about being CAPPED, which is the point: it makes a subtle mechanic
// visible. It reads the MACHINE truth (raw ki above the care-capped rung), never the visual
// index, so a full-moon night can neither fake it nor mask it.
function vegetaFurious(rawKiIndex, effectiveRungIndex) {
    return isFinite(rawKiIndex) && isFinite(effectiveRungIndex)
        && rawKiIndex > effectiveRungIndex
}

// respectInhibitors does not guarantee that every fullscreen player actually takes an idle
// inhibitor, and a pet meditating through a film reads as a bug even when the input really
// was idle. The all-monitor fullscreen signal is the second gate.
function piccoloMeditates(isIdle, anyFullscreen) {
    return isIdle === true && anyFullscreen !== true
}

function friezaComplains(diskPercent, orphanCount) {
    var dirty = typeof diskPercent === "number" && isFinite(diskPercent) && diskPercent >= 90
    var orphans = typeof orphanCount === "number" && isFinite(orphanCount) && orphanCount > 0
    return dirty || orphans
}

function krillinNervous(rivalPhase) {
    return rivalPhase === "entering" || rivalPhase === "facing"
}
