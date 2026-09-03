.pragma library

// A ki reading derived from this machine, for people who do not run a separate producer.
//
// KiSource reads an external ki.json when one exists. Nothing in this plugin writes that
// file, so on a stock install it is absent forever, the status pins to "missing", and the
// pet can never transform -- which makes the headline feature inert for everyone except the
// author. This is the fallback that closes that gap: /proc/stat is on every Linux machine
// and costs one bounded read every few seconds.
//
// Pure, because everything interesting here is arithmetic on two samples and a set of
// thresholds, and because a Quickshell component cannot be instantiated in a TestCase.
//
// THE SAME HONESTY RULE APPLIES. One sample is not a reading: the first poll has nothing to
// difference against and reports "warming", not "base". A reading that cannot be computed
// says so rather than inventing a calm machine.

// /proc/stat's first line: cpu user nice system idle iowait irq softirq steal guest ...
// Idle time is fields 4 and 5 (idle, iowait); everything else counts as work.
var IDLE_FIELDS = [3, 4]

// Sustained busy fraction -> transformation. The gaps are wide on purpose: a pet that flicks
// between forms while you scroll a web page is noise, not a power level.
var RUNGS = [
    { form: "ui", atLeast: 0.80 },
    { form: "blue", atLeast: 0.55 },
    { form: "ssj", atLeast: 0.30 },
    { form: "base", atLeast: 0 }
]

// Battle power is theatre, but it should be theatre with a fixed exchange rate: the
// over-9000 alert has to mean "this machine is genuinely working", which lands around 41%.
var POWER_SCALE = 22000

// A busy machine ramps quickly and calms slowly, so the number on the panel does not
// flicker. This is a plain exponential smooth over the raw fraction.
var RISE = 0.55
var FALL = 0.18

function emptySample() { return { total: -1, idle: -1 } }

// Returns {total, idle}, or null when the text is not a /proc/stat we recognise. Total is
// the sum of every field, so a kernel that adds a tenth column cannot make it drift.
function parse(text) {
    if (typeof text !== "string") return null
    var line = text.split("\n")[0]
    if (!line || line.indexOf("cpu ") !== 0) return null
    var parts = line.split(/\s+/)
    var total = 0, idle = 0
    // parts[0] is "cpu"; the counters start at 1.
    for (var i = 1; i < parts.length; i++) {
        var n = Number(parts[i])
        if (!isFinite(n) || n < 0) return null
        total += n
        if (IDLE_FIELDS.indexOf(i - 1) >= 0) idle += n
    }
    if (total <= 0) return null
    return { total: total, idle: idle }
}

// The busy fraction between two samples, or null when there is nothing to compare. A
// counter that went backwards means a reboot or a rollover, and the honest answer is to
// start over rather than to report a spike.
function busyFraction(prev, cur) {
    if (!prev || !cur || prev.total < 0 || cur.total < 0) return null
    var dt = cur.total - prev.total
    var di = cur.idle - prev.idle
    if (dt <= 0 || di < 0) return null
    var busy = (dt - di) / dt
    return Math.max(0, Math.min(1, busy))
}

function smooth(previous, fraction) {
    if (typeof previous !== "number" || !isFinite(previous)) return fraction
    var k = fraction > previous ? RISE : FALL
    return previous + (fraction - previous) * k
}

function formFor(fraction) {
    if (typeof fraction !== "number" || !isFinite(fraction)) return "base"
    for (var i = 0; i < RUNGS.length; i++)
        if (fraction >= RUNGS[i].atLeast) return RUNGS[i].form
    return "base"
}

function powerFor(fraction) {
    if (typeof fraction !== "number" || !isFinite(fraction)) return 0
    return Math.round(Math.max(0, Math.min(1, fraction)) * POWER_SCALE)
}

// The snapshot KiSource's contract expects, so the two producers are interchangeable.
// "warming" is its own status: one sample is not a reading, and calling it base would be
// the same lie the external reader's "missing" exists to avoid.
function state(fraction) {
    if (fraction === null || fraction === undefined)
        return { status: "warming", form: "base", power: null, fraction: null }
    return {
        status: "ok",
        form: formFor(fraction),
        power: powerFor(fraction),
        fraction: fraction
    }
}
