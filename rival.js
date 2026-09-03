.pragma library

// The rival: a second, much simpler entity that walks on when a distant machine is working
// hard while the local pet is transformed. It never fights. It stares, which is
// franchise-accurate for entire seasons.
//
// It arrives SLOWLY and leaves INSTANTLY. The asymmetry is deliberate: entry hysteresis
// stops a flickering remote reading from summoning it, but a rival that lingers after the
// evidence went away is asserting a state nobody measured.

var STATE_KEYS = ["phase", "rivalX", "facingLeft", "encounterTrueMs", "phaseMs"]

var ENTRY_MS = 60000
var WALK_PX_S = 60
var STOP_GAP = 100
var LEAVE_X = -60

var ORDER = ["goku", "vegeta", "piccolo", "krillin", "frieza"]
var FORM_BY_STAGE = { child: "child", teen: "teen_neat", adult: "adult_ok" }

function emptyState() {
    return { phase: "none", rivalX: 0, facingLeft: false, encounterTrueMs: 0, phaseMs: 0 }
}

// Deterministic and never the local line, so the same machine state always produces the
// same opponent. An unknown local line means no rival at all rather than a guess.
function lineFor(localLine) {
    var i = ORDER.indexOf(localLine)
    if (i < 0) return null
    return ORDER[(i + 2) % ORDER.length]
}

// pod_walk_* and baby_walk_* do not exist for any line, so a young rival would resolve
// "walk" to idle and slide across the floor standing up.
function formFor(stage) {
    var f = FORM_BY_STAGE[stage]
    return f === undefined ? null : f
}

function next(state, petX, dtMs, encounter, abort) {
    var st = (state && typeof state === "object")
        ? { phase: state.phase, rivalX: state.rivalX, facingLeft: state.facingLeft,
            encounterTrueMs: state.encounterTrueMs, phaseMs: state.phaseMs }
        : emptyState()

    // One flag, one instant vanish, so a farewell can never be ruined by a phase that
    // forgot a case.
    if (abort === true) return emptyState()

    // The contiguous-true timer lives in the STATE, not in an elapsed-ms argument: a bare
    // phase plus elapsed time cannot express "true without interruption", so a flicker
    // would leave the entry clock running.
    st.encounterTrueMs = (encounter === true) ? st.encounterTrueMs + dtMs : 0
    st.phaseMs += dtMs

    if (st.phase === "none") {
        if (st.encounterTrueMs >= ENTRY_MS) {
            st.phase = "entering"
            st.phaseMs = 0
            st.rivalX = 0
            st.facingLeft = false
        }
        return st
    }

    // Measured false OR unknown both leave, with no dwell.
    if (encounter !== true && st.phase !== "leaving") {
        st.phase = "leaving"
        st.phaseMs = 0
        st.facingLeft = true
        return st
    }

    var step = WALK_PX_S * dtMs / 1000
    if (st.phase === "entering") {
        var target = petX - STOP_GAP
        if (st.rivalX + step >= target) { st.rivalX = target; st.phase = "facing"; st.phaseMs = 0 }
        else st.rivalX += step
    } else if (st.phase === "leaving") {
        st.rivalX -= step
        if (st.rivalX <= LEAVE_X) return emptyState()
    }
    return st
}
