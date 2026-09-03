.pragma library
.import "transform.js" as Transform
.import "lines.js" as Lines

// The ONE resolved-display object. Every surface consumes this and nothing else, so
// displayForm, displayIndex, aura and kiExplain can never describe different forms --
// the divergence class behind the 2026-09-01 Critical defect.
//
// Two truths always ride along, untouched by costume: rawKiIndex is the validated ki
// reading's rung (the machine truth), effectiveRungIndex is the care-capped rung that
// drives the visuals when no moon is up. Anything that reasons about the MACHINE reads
// those, never the visual fields, so the moon cannot lie to it.

var MOON_EXPLAIN = "The moon is full. It is not itself tonight."
var NO_AURA = Lines.NO_AURA

// A module-private sentinel meaning "the source object did not have this property".
// Distinct from undefined on purpose: see inputs().
var MISSING = { missing: true }

var INPUT_KEYS = ["line", "stage", "form", "kiForm", "kiStatus", "careAverage",
                  "happiness", "careCount", "moonActive", "ceilingOverride",
                  "levelCapIndex", "level"]

// The ONE constructor of a resolver argument. Service.qml builds its `display` binding
// through this and the test harness builds a stub through the same function, so the two
// cannot drift.
//
// Presence is tested on the SOURCE, not on the output: writing
// `{ levelCapIndex: s.levelCapIndex }` creates a present key holding undefined, a downstream
// presence check passes, and undefined reads as uncapped -- the check failing open in
// exactly the case it exists for.
function inputs(s) {
    var out = {}
    for (var i = 0; i < INPUT_KEYS.length; i++) {
        var k = INPUT_KEYS[i]
        out[k] = (s && (k in s)) ? s[k] : MISSING
    }
    return out
}

function levelCapOf(p) {
    if (!("levelCapIndex" in p) || p.levelCapIndex === MISSING) {
        console.warn("omagoku: display input has no levelCapIndex -- capping at base")
        return 0
    }
    return p.levelCapIndex
}

function resolve(p) {
    var rawKiIndex = Transform.formIndex(p.kiForm)
    // Threaded all the way through: nothing calls displayIndex directly any more, so a cap
    // that stopped here would be implementable and completely invisible.
    var c = Transform.caps(p.kiForm, p.stage, p.careAverage, p.happiness, p.careCount,
                           p.ceilingOverride === MISSING ? null : p.ceilingOverride,
                           levelCapOf(p))
    var effective = c.effective
    var lunar = p.moonActive === true
        && Lines.isOozaruLine(p.line)
        && (p.stage === "teen" || p.stage === "adult")
    if (lunar) {
        return {
            displayForm: Lines.baseSprite(p.line, p.stage, "teen_scruffy"),
            displayIndex: 0,
            aura: NO_AURA,
            kiExplain: MOON_EXPLAIN,
            cause: "moon",
            rawKiIndex: rawKiIndex,
            effectiveRungIndex: effective
        }
    }
    return {
        displayForm: effective === 0
            ? Lines.baseSprite(p.line, p.stage, p.form)
            : Lines.baseSprite(p.line, p.stage, Transform.FORMS[effective]),
        displayIndex: effective,
        aura: Lines.auraFor(p.line, effective),
        kiExplain: explain(p, effective, rawKiIndex, c.binding),
        cause: effective > 0 ? "ki" : (c.binding === "level" ? "level" : "base"),
        rawKiIndex: rawKiIndex,
        effectiveRungIndex: effective
    }
}

function explain(p, effective, rawKiIndex, binding) {
    if (effective > 0) return Lines.rungLabel(p.line, effective)
    // Base. The interesting part is WHY: "fell back to base" and "is genuinely base"
    // look identical on screen and mean completely different things. The order is what the
    // user can act on: a child's age outranks its level, which outranks its condition.
    if (rawKiIndex > 0) {
        if (binding === "stage") return "Too young to transform"
        if (binding === "level")
            return (typeof p.level === "number" && isFinite(p.level))
                ? "Not strong enough yet (level " + p.level + ")"
                : "Not strong enough yet"
        return "Too run-down to hold the form"
    }
    switch (p.kiStatus) {
    case "ok": return "Ki steady"
    case "stale": return "Ki reading has gone stale"
    case "malformed": return "Ki reading unreadable"
    default: return "No ki reading"
    }
}
