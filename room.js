.pragma library

// The room's furniture as ONE computed list.
//
// Panel.qml's model used to be `stageDecor[form] || stageDecor[stage] || []` -- a static
// literal selected by a single key -- so a level unlock could only ever be in every room or
// in none. Merging is now a pure function with a pinned precedence, which is also the only
// way "the unlocks do not collide with the keepsake" is a testable claim rather than a hope.
//
// Precedence: stage furniture, then the keepsake slot, then unlocks in ascending level.

// Verbatim from Panel.qml, moved here so it can be tested. `beam` is the emitting edge of a
// light source in sprite pixels; `colorize: false` keeps a piece's own palette instead of
// flattening it to the theme accent.
var STAGE_DECOR = {
    egg: [
        { name: "moon", x: 0.62, y: 0.04, px: 3, beam: [8, 26, 23, 26], colorize: false }
    ],
    baby: [
        { name: "dragonballs", x: 0.08, y: 0.03, px: 3, sway: true, colorize: false }
    ],
    child: [
        { name: "dragonball", x: 0.74, y: 0.52, px: 4, bounce: true, colorize: false }
    ],
    teen_neat: [
        { name: "radar", x: 0.11, y: 0.74, px: 4, colorize: false }
    ],
    teen_scruffy: [
        { name: "moon", x: 0.62, y: 0.04, px: 3, beam: [8, 26, 23, 26], colorize: false }
    ],
    adult_gremlin: [
        { name: "tree_gremlin", x: 0.78, y: 0.40, px: 3, colorize: false }
    ],
    adult_ok: [
        { name: "tree_ok", x: 0.78, y: 0.40, px: 3, colorize: false },
        { name: "boots", x: 0.10, y: 0.78, px: 3, colorize: false }
    ],
    adult_ace: [
        { name: "tree_ace", x: 0.78, y: 0.40, px: 3, colorize: false }
    ]
}

// Four NEW 16x16 trophies. The obvious candidates -- korin, kame, lookout, timechamber --
// are all 96x48 room BACKDROPS in MANIFEST.tsv, so at the delegate's px scaling each would
// render 192x96 inside the room and four together would be scenery, not furniture.
//
// Positions are pinned clear of the top-left dragonballs slot, which the idea-9 keepsake
// owns. The keepsake has no renderer yet; Phase 1 reserves the position and draws nothing.
var UNLOCKS = [
    { level: 25,  name: "trophy_korin",   x: 0.02, y: 0.30, px: 2, colorize: false },
    { level: 50,  name: "trophy_kame",    x: 0.30, y: 0.74, px: 2, colorize: false },
    { level: 75,  name: "trophy_lookout", x: 0.44, y: 0.04, px: 2, colorize: false },
    { level: 100, name: "trophy_chamber", x: 0.86, y: 0.06, px: 2, colorize: false }
]

var KEEPSAKE_SLOT = { x: 0.08, y: 0.03 }

function decor(form, stage, level, keepsakeEarned) {
    var out = []
    var stageSet = STAGE_DECOR[form] || STAGE_DECOR[stage] || []
    for (var i = 0; i < stageSet.length; i++) out.push(stageSet[i])
    // The keepsake slot is reserved here rather than filled: its renderer is Phase 2, and
    // an unlock must not be allowed to move into the space while it is empty.
    var n = (typeof level === "number" && isFinite(level) && level >= 1) ? level : 1
    for (var j = 0; j < UNLOCKS.length; j++) if (n >= UNLOCKS[j].level) out.push(UNLOCKS[j])
    return out
}
