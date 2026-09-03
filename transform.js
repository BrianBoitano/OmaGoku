.pragma library

// The transformation ladder, and every rule that decides which rung Goku is on.
// Pure functions on purpose: this is the logic most likely to be wrong, so it is the logic
// that has to be testable without a QML object graph or a live ki.json.

// Exactly what saiyan-ki emits. ssj2/ssj3 are NOT here: the producer never writes them, so
// they would be unreachable rungs. Compared BY INDEX, never by string ordering --
// Math.min("ui", 2) is NaN.
var FORMS = ["base", "ssj", "blue", "ui"]

// The AURA table used to live here. It moved to lines.js, because the transformation hair is
// baked PER LINE in palettes.tsv and one global table contradicted four of the five lines.
// This module decides which RUNG a pet is on; the line decides what that rung looks like.

function formIndex(form) {
    var i = FORMS.indexOf(form)
    return i < 0 ? 0 : i          // anything unrecognised is base, never an error
}

// An INDEX, never a boolean. `Math.min(a, b, true)` coerces true to 1 and would silently
// cap every eligible pet at ssj forever.
function stageCapIndex(stage) {
    return (stage === "teen" || stage === "adult") ? FORMS.length - 1 : 0
}

// Care sets the ceiling ki is allowed to reach.
//
// Uses min(careAverage, happiness), not careAverage alone: careAverage is a STAGE-LONG
// average, so a pet that started starving five minutes ago still carries a high average and
// would transform freely. happiness is the current condition.
//
// And when careCount is 0, upstream's careAverage returns 100 (Service.qml:108) -- which
// evolve() causes on EVERY evolution by zeroing the counters. Without this branch a freshly
// evolved, starving Goku would read as perfectly cared for and go Ultra Instinct.
function ceilingIndex(careAverage, happiness, careCount) {
    var care = (careCount > 0) ? Math.min(careAverage, happiness) : happiness
    if (care >= 85) return 3
    if (care >= 70) return 2
    if (care >= 50) return 1
    return 0
}

// `ceilingOverride` is a SIXTH argument, added for Shenron's care-ceiling wish. It is an
// INDEX or null and nothing else: `true` would coerce to 1 inside Math.min and CAP an honest
// Blue or Ultra Instinct reading at Super Saiyan, which is the exact inverse of what the wish
// grants -- the same coercion trap stageCapIndex carries a comment about. It removes a cap; it
// can never add a rung, because the ki reading and the stage cap both still bind.
function validOverride(v) {
    return (typeof v === "number" && isFinite(v) && Math.floor(v) === v
            && v >= 0 && v < FORMS.length) ? v : null
}

// `levelCapIndex` is the SEVENTH argument, and it is validated in the OPPOSITE direction to
// ceilingOverride. There, null means "no override" and mapping junk to null is conservative
// because the override only ever LIFTS. Here null means UNCAPPED, so the same fail-open rule
// would let a malformed value switch progression gating off entirely. Omitted and explicit
// null are uncapped -- that is what keeps every five- and six-argument call unchanged --
// and anything else caps at base and says so.
//
// If an eighth argument is ever wanted, move this signature to an options object.
function validLevelCap(v) {
    if (v === undefined || v === null) return null
    if (typeof v === "number" && isFinite(v) && Math.floor(v) === v
        && v >= 0 && v < FORMS.length) return v
    console.warn("omagoku: invalid levelCapIndex (" + v + ") -- capping at base")
    return 0
}

// The one place the four caps are compared, so `binding` cannot disagree with `effective`.
//
// `binding` is null whenever nothing LOWERED the rung: a cap that merely equals the measured
// reading did not bind, and naming it would tell a level-8 pet showing an honest Super
// Saiyan that it is not strong enough yet. Precedence among caps that did bind is
// stage, then level, then care -- the order of what the user can do something about.
function caps(kiForm, stage, careAverage, happiness, careCount, ceilingOverride,
              levelCapIndex) {
    var ki = formIndex(kiForm)
    var override = validOverride(ceilingOverride)
    var care = (override !== null)
        ? override : ceilingIndex(careAverage, happiness, careCount)
    var st = stageCapIndex(stage)
    var lv = validLevelCap(levelCapIndex)
    var lvIdx = (lv === null) ? FORMS.length - 1 : lv
    var effective = Math.min(ki, care, st, lvIdx)
    var binding = null
    if (effective < ki) {
        if (st === effective) binding = "stage"
        else if (lvIdx === effective) binding = "level"
        else binding = "care"
    }
    return { ki: ki, care: care, stage: st, level: lv,
             effective: effective, binding: binding }
}

function displayIndex(kiForm, stage, careAverage, happiness, careCount, ceilingOverride,
                      levelCapIndex) {
    return caps(kiForm, stage, careAverage, happiness, careCount, ceilingOverride,
                levelCapIndex).effective
}

