.pragma library
.import "lines.js" as Lines

// The signature move sets: one roster, in one place, exactly as lines.js is.
//
// AVAILABILITY IS DERIVED. `Moves.available(line, level)` is a pure function of the roster,
// the pet's line and the level derived from its XP. The persisted `progress.announced` array
// records which moves have already been TOASTED and participates in nothing else -- persisted
// derived state used as authority is the defect class behind both Criticals this project has
// had, and a corrupt array must never be able to unlock an unearned move.

var LEVELS = [12, 30, 60]

// Geometry is BEHAVIOUR, not just a sprite. "Travel to the screen edge" describes a beam and
// is nonsense for a Kaioken aura, which would slide off the monitor.
//
//   travels   -- whether it leaves the pet at all
//   scale     -- multiple of spriteSize for the long axis
//   thickness -- multiple of spriteSize for the short axis (beams and lines only)
//   count     -- how many pieces are drawn
//   stagger   -- ms between pieces of a multi-piece move
//   lifetime  -- total ms, and the same number admitMove reserves. ONE value, not two.
var GEOMETRY = {
    beam:      { travels: true,  scale: 1,   thickness: 0.5,  count: 1, stagger: 0,   lifetime: 2600 },
    wide_beam: { travels: true,  scale: 2,   thickness: 1.0,  count: 1, stagger: 0,   lifetime: 2600 },
    fine_line: { travels: true,  scale: 1,   thickness: 0.17, count: 1, stagger: 0,   lifetime: 1800 },
    orb:       { travels: true,  scale: 1,   thickness: 1.0,  count: 1, stagger: 0,   lifetime: 2600 },
    large_orb: { travels: true,  scale: 2,   thickness: 2.0,  count: 1, stagger: 0,   lifetime: 2600 },
    orbs:      { travels: true,  scale: 0.5, thickness: 0.5,  count: 5, stagger: 120, lifetime: 2600 },
    dots:      { travels: true,  scale: 0.33, thickness: 0.33, count: 8, stagger: 80, lifetime: 2600 },
    ring:      { travels: true,  scale: 1,   thickness: 1.0,  count: 1, stagger: 0,   lifetime: 2600 },
    spiral:    { travels: true,  scale: 1,   thickness: 0.33, count: 1, stagger: 0,   lifetime: 2600 },
    aura:      { travels: false, scale: 2,   thickness: 2.0,  count: 1, stagger: 0,   lifetime: 2600 },
    flash:     { travels: false, scale: 2.5, thickness: 2.5,  count: 1, stagger: 0,   lifetime: 900 }
}

// Absolute phases, per class. A single universal 800 + 1200 + 600 left the charge duration
// and the fade callback ambiguous for the two classes that are shorter than that.
var TIMELINE = {
    beam:      { charge: 800, action: 1200, fade: 600 },
    wide_beam: { charge: 800, action: 1200, fade: 600 },
    fine_line: { charge: 800, action: 600,  fade: 400 },
    orb:       { charge: 800, action: 1200, fade: 600 },
    large_orb: { charge: 800, action: 1200, fade: 600 },
    orbs:      { charge: 800, action: 1200, fade: 600 },
    dots:      { charge: 800, action: 1200, fade: 600 },
    ring:      { charge: 800, action: 1200, fade: 600 },
    spiral:    { charge: 800, action: 1200, fade: 600 },
    aura:      { charge: 800, action: 1200, fade: 600 },
    flash:     { charge: 400, action: 500,  fade: 0 }
}

var MOVE_STATIC_MS = 1200

var MOVES = [
    { id: "kamehameha",       line: "goku",    level: 12, geometry: "beam",      label: "Kamehameha" },
    { id: "spirit_bomb",      line: "goku",    level: 30, geometry: "orb",       label: "Spirit Bomb" },
    { id: "kaioken",          line: "goku",    level: 60, geometry: "aura",      label: "Kaioken" },
    { id: "galick_gun",       line: "vegeta",  level: 12, geometry: "beam",      label: "Galick Gun" },
    { id: "big_bang",         line: "vegeta",  level: 30, geometry: "orb",       label: "Big Bang Attack" },
    { id: "final_flash",      line: "vegeta",  level: 60, geometry: "wide_beam", label: "Final Flash" },
    { id: "special_beam",     line: "piccolo", level: 12, geometry: "spiral",    label: "Special Beam Cannon" },
    { id: "hellzone",         line: "piccolo", level: 30, geometry: "orbs",      label: "Hellzone Grenade" },
    { id: "light_grenade",    line: "piccolo", level: 60, geometry: "orb",       label: "Light Grenade" },
    { id: "destructo_disc",   line: "krillin", level: 12, geometry: "ring",      label: "Destructo Disc" },
    { id: "scattering",       line: "krillin", level: 30, geometry: "dots",      label: "Scattering Bullet" },
    { id: "solar_flare",      line: "krillin", level: 60, geometry: "flash",     label: "Solar Flare" },
    { id: "death_beam",       line: "frieza",  level: 12, geometry: "fine_line", label: "Death Beam" },
    { id: "death_ball",       line: "frieza",  level: 30, geometry: "orb",       label: "Death Ball" },
    { id: "supernova",        line: "frieza",  level: 60, geometry: "large_orb", label: "Supernova" }
]

function ids() {
    var out = []
    for (var i = 0; i < MOVES.length; i++) out.push(MOVES[i].id)
    return out
}

function byId(id) {
    for (var i = 0; i < MOVES.length; i++) if (MOVES[i].id === id) return MOVES[i]
    return null
}

function forLine(line) {
    var out = []
    for (var i = 0; i < MOVES.length; i++) if (MOVES[i].line === line) out.push(MOVES[i])
    out.sort(function (a, b) { return a.level - b.level })
    return out
}

function available(line, level) {
    var n = (typeof level === "number" && isFinite(level)) ? level : 1
    if (!Lines.has(line)) return []
    var set = forLine(line)
    var out = []
    for (var i = 0; i < set.length; i++) if (n >= set[i].level) out.push(set[i])
    return out
}

// Membership by ID, not "some move is available": a handshake that only checked the latter
// would let a stale command fire another line's move.
function isAvailable(line, level, id) {
    var set = available(line, level)
    for (var i = 0; i < set.length; i++) if (set[i].id === id) return true
    return false
}

// ONE selection rule, used by the ambient trigger and the over-9000 trigger alike: the pet
// shows off its best.
function best(line, level) {
    var set = available(line, level)
    return set.length === 0 ? null : set[set.length - 1]
}

function spriteFor(id) { return "decor_move_" + id }

// Reduced motion is a static hold and then an instantaneous hide -- no animated property at
// all. But "not animated" is not "safe": a stationary 2.5x Solar Flare at opacity 0.9
// appearing instantly is a large luminance step, which is most of what the setting is asking
// to be spared. So the stationary classes are substituted by a small shoulder icon.
function reducedForm(geometry) {
    var g = GEOMETRY[geometry]
    var stationary = !!(g && !g.travels)
    return stationary
        ? { substitute: true, scale: 0.5, opacity: 0.5 }
        : { substitute: false, scale: g ? g.scale : 1, opacity: 0.9 }
}

function timeline(geometry, reducedMotion) {
    if (reducedMotion === true)
        return { charge: 0, action: MOVE_STATIC_MS, fade: 0, total: MOVE_STATIC_MS }
    var t = TIMELINE[geometry] || TIMELINE.beam
    return { charge: t.charge, action: t.action, fade: t.fade,
             total: t.charge + t.action + t.fade }
}
