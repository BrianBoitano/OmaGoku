.pragma library

// Lunar phase from the system clock: pure arithmetic, no network, no almanac. The pet's
// full moon is the model's full moon -- accurate to a few hours over decades, which is
// plenty for a 72-hour window -- and every function takes injected time so the whole
// mechanic is testable on any afternoon.

// A known new moon, and the mean synodic month.
var EPOCH_MS = Date.UTC(2000, 0, 6, 18, 14, 0)
var SYNODIC_MS = 29.530588853 * 86400000
// "Near full" = within 36 hours of the exact full instant, so a full-moon night is
// observable on the evening either side of the astronomical moment.
var FULL_WINDOW_MS = 36 * 3600000

function nearestFullMs(nowMs) {
    var k = Math.round((nowMs - EPOCH_MS) / SYNODIC_MS - 0.5)
    return EPOCH_MS + (k + 0.5) * SYNODIC_MS
}

function isFullWindow(nowMs) {
    var t = Number(nowMs)
    if (!isFinite(t)) return false
    return Math.abs(t - nearestFullMs(t)) <= FULL_WINDOW_MS
}

// Night is 20:00 to 06:00 LOCAL: the phase math is UTC, only this gate reads local hours.
function isNight(localHour) {
    var h = Number(localHour)
    if (!isFinite(h)) return false
    return h >= 20 || h < 6
}

// Dusk is its OWN predicate. Reusing isNight() would summon Shenron at four in the morning.
function isDusk(localHour) {
    var h = Number(localHour)
    if (!isFinite(h)) return false
    return h >= 18 && h < 21
}

// Night rest, 20:00 to 07:00 LOCAL. Deliberately NOT isNight(): that one ends at 06:00 and
// drives the Great Ape window, which is pinned by its own test matrix and must not move.
// During these hours the pet sleeps and accrues nothing -- a machine left on overnight used
// to hand back a fully depleted pet, which is eleven hours of needs nobody was awake to meet.
function isRestHours(localHour) {
    var h = Number(localHour)
    if (!isFinite(h)) return false
    return h >= 20 || h < 7
}

function lunarActive(nowMs, localHour) {
    return isFullWindow(nowMs) && isNight(localHour)
}
