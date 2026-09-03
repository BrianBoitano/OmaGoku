.pragma library

// The five family lines, and everything that differs between them.
// Pure functions on purpose: Quickshell's QML plugin cannot load outside the quickshell binary,
// so anything living in a QML component is untestable here.
//
// A line id reaches an asset URL as a path component, so `has()` is the only thing that
// makes an id trustworthy and every other function falls back to DEFAULT_LINE.

var DEFAULT_LINE = "goku"

// What to show before the service has loaded. It must be a sprite that EXISTS: every pet
// sprite is line-prefixed, so a bare "pod" resolves to a file that was renamed away and
// PetSprite's fallback chain then finds nothing at all.
var PLACEHOLDER_SPRITE = "goku_pod"

var LINES = {
    goku: {
        rungColors: { Y: "#FFD24A", C: "#66E0FF", G: "#C8C8D4" },
        moveColor: "#7FE3FF",
        members: ["Goku", "Gohan", "Goten", "Goku Jr."],
        rungs: ["Base", "Super Saiyan", "Super Saiyan Blue", "Ultra Instinct"],
        rooms: ["kame", "korin", "kingkai"],
        rates: { hunger: 1.0, dirt: 1.0, tired: 1.0, fun: 1.0, lonely: 1.0 },
        blurb: "Eats anything, trains anywhere, forgives everything.",
        oozaru: true
    },
    vegeta: {
        rungColors: { Y: "#FFD24A", C: "#66E0FF", G: "#7FD4FF" },
        moveColor: "#B060E8",
        members: ["Vegeta", "Trunks", "Bulla"],
        rungs: ["Base", "Super Saiyan", "Super Saiyan 2", "Blue Evolution"],
        rooms: ["gravity", "capsule", "westcity"],
        rates: { hunger: 1.4, dirt: 1.0, tired: 0.8, fun: 1.5, lonely: 0.6 },
        blurb: "Trains harder than he should. Will not admit he wants company.",
        oozaru: true
    },
    piccolo: {
        rungColors: { Y: "#7FE05A", C: "#B0F0C8", G: "#F0902A" },
        moveColor: "#F0B429",
        members: ["Piccolo", "Piccolo Jr."],
        rungs: ["Base", "Nail-fused", "Kami-fused", "Orange Piccolo"],
        rooms: ["lookout", "timechamber", "waterfall"],
        rates: { hunger: 0.4, dirt: 1.0, tired: 0.7, fun: 0.5, lonely: 0.4 },
        blurb: "Drinks water, meditates, and would rather you left him alone.",
        oozaru: false
    },
    krillin: {
        rungColors: { Y: "#FFD24A", C: "#66E0FF", G: "#F5F0C0" },
        moveColor: "#BFE9F5",
        members: ["Krillin", "Marron"],
        rungs: ["Base", "Focused", "Destructo Disc", "Unlocked Potential"],
        rooms: ["kame", "satancity", "lookout"],
        rates: { hunger: 0.8, dirt: 0.8, tired: 1.0, fun: 0.8, lonely: 1.2 },
        blurb: "Low maintenance, endlessly loyal, thrilled you noticed him.",
        oozaru: false
    },
    frieza: {
        rungColors: { Y: "#C060C0", C: "#E8E8F0", G: "#FFD24A" },
        moveColor: "#E24BC8",
        members: ["Frieza", "Kuriza"],
        rungs: ["First Form", "Second Form", "Final Form", "Golden Frieza"],
        rooms: ["ship", "namek", "hell"],
        rates: { hunger: 1.3, dirt: 1.5, tired: 1.0, fun: 1.2, lonely: 0.3 },
        blurb: "Demanding, ungrateful, and somehow still your responsibility.",
        oozaru: false
    }
}

// Display order for the selector. Explicit, because object key order is not a contract.
var ORDER = ["goku", "vegeta", "piccolo", "krillin", "frieza"]

function ids() {
    return ORDER.slice()
}

function has(id) {
    return typeof id === "string" && ORDER.indexOf(id) >= 0
}

// Every accessor goes through this, so an unknown id degrades to a renderable pet instead
// of throwing inside a QML binding, where the error would be silent.
function entry(id) {
    return has(id) ? LINES[id] : LINES[DEFAULT_LINE]
}

function safeId(id) {
    return has(id) ? id : DEFAULT_LINE
}

function gen(generation) {
    var n = Math.floor(generation) || 1
    return n < 1 ? 1 : n
}

function roman(n) {
    var table = ["", "I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X"]
    return (n >= 0 && n < table.length) ? table[n] : String(n)
}

function nameFor(id, generation) {
    var members = entry(id).members
    var n = gen(generation)
    var base = members[(n - 1) % members.length]
    var cycle = Math.floor((n - 1) / members.length)
    return cycle === 0 ? base : base + " " + roman(cycle + 1)
}

function roomFor(id, generation) {
    var rooms = entry(id).rooms
    return rooms[(gen(generation) - 1) % rooms.length]
}

function rungLabel(id, index) {
    var rungs = entry(id).rungs
    var i = Math.floor(index)
    if (!isFinite(i) || i < 0 || i >= rungs.length) return rungs[0]
    return rungs[i]
}

function ratesFor(id) {
    return entry(id).rates
}

function blurbFor(id) {
    return entry(id).blurb
}

// The colour of a line's transformation, taken from the SAME hex the build bakes into its
// hair. transform.js used to hold one global aura table while palettes.tsv bakes the hair per
// line, so four of five lines wore a glow that contradicted their own head: a green-haired
// Super Saiyan Piccolo inside a gold aura, Golden Frieza inside silver. Two sources for one
// truth, which is the defect class this project has already paid for twice.
//
// These hexes must equal plugin/tools/palettes.tsv. gen-sprites.py enforces that at build
// time -- the colour check its own header promised and that had never been written.
var RUNG_GLYPHS_BY_INDEX = [null, "Y", "C", "G"]
var NO_AURA = { enabled: false, color: "#00000000", pulse: false }

function rungColor(id, index) {
    var glyph = RUNG_GLYPHS_BY_INDEX[index]
    if (!glyph) return null
    var e = entry(id)
    if (!e || !e.rungColors || typeof e.rungColors[glyph] !== "string") return null
    return e.rungColors[glyph]
}

// The ONE aura resolver. `index` is the EFFECTIVE rung -- the one the pet is showing, after
// care, stage, the wish and the level gate -- never the machine's raw reading.
function auraFor(id, index) {
    var c = rungColor(id, index)
    return c === null ? NO_AURA : { enabled: true, color: c, pulse: true }
}

// The colour a line's signature moves are TINTED at. gen-sprites.py applies a line palette
// only to PET grids, so every decor_* asset -- the move sprites included -- is generated once
// with the global palette and recoloured at render time instead.
function moveColor(id) {
    var e = entry(id)
    return (e && typeof e.moveColor === "string") ? e.moveColor : "#FFFFFF"
}

function isOozaruLine(id) {
    return entry(id).oozaru === true
}

// The sprite prefix for a pet's LIFE form. Ladder index 0 resolves through this.
function baseSprite(id, stage, form) {
    return safeId(id) + "_" + form
}

// The genetic variant token, appended to a whole sprite FILENAME -- never to a form.
//
// Keeping it out of the form string is structural, not stylistic: Lineage.validEntry checks
// `form` against a fixed list, so a token that reached it would make every historical row
// fail and be dropped silently, destroying the history the file exists to protect. As a
// trailing filename segment it cannot get there.
//
// Bucket 2 is the identity transform, so it reuses the canonical name and today's art stays
// byte-identical by being the SAME FILE. Every other value -- null, "3", 3.5, -1, 5, NaN --
// also falls to canonical. Deliberately NO clamp and NO modulo: either would map an invalid
// bucket onto arbitrary VALID art, hiding the bug behind a pet that looks fine.
var VARIANT_SUFFIX = { 0: "_g0", 1: "_g1", 3: "_g3", 4: "_g4" }

function variantSuffix(bucket) {
    if (typeof bucket !== "number" || !isFinite(bucket) || Math.floor(bucket) !== bucket)
        return ""
    var s = VARIANT_SUFFIX[bucket]
    return s === undefined ? "" : s
}

// Line rates MULTIPLY the stage rates rather than replacing them, so a Piccolo baby still
// naps like a baby and a Vegeta teen still raids the fridge like a teen. A missing stage
// key reads as 1 rather than NaN, because these values feed the need levels directly and a
// single NaN poisons the whole pet.
function composeRates(stageRates, id) {
    var s = stageRates || {}
    var m = ratesFor(id)
    function num(v) { var n = Number(v); return isFinite(n) ? n : 1 }
    return {
        hunger: num(s.hunger) * m.hunger,
        dirt: num(s.dirt) * m.dirt,
        tired: num(s.tired) * m.tired,
        fun: num(s.fun) * m.fun,
        lonely: m.lonely
    }
}

// --- speech ------------------------------------------------------------------
//
// Hand-written per-line copy for every event the notification pipeline can fire, plus
// each line's idle-chatter bag. Strings may use {name}, {rung} and {gen} placeholders.
// moonrise/dawn exist only for the Oozaru lines: the other three have no moon night.

var SPEECH = {
    goku: {
        evolve_baby: "{name} here! Whoa, everything's huge. Is there food?",
        evolve_child: "{name}'s growing! Found my fighting stance today. And your snack drawer.",
        evolve_teen_neat: "{name}'s all grown up and training hard. Thanks for taking care of me!",
        evolve_teen_scruffy: "{name} grew up a little wild. More training, fewer baths. Deal?",
        evolve_adult: "{name}, full power! Whatever comes at this machine, I've got it.",
        rebirth: "He walked off smiling. A new pod just hit the yard — come see! (Gen {gen})",
        line_selected: "A pod from the Son family! {name} is on the way — better stock the fridge.",
        transformation: "{name} went {rung}! Feel that?!",
        hard_landing: "Ow. That was a long way down. I'm okay! Mostly okay.",
        need_hunger: "{name} is STARVING. Even Yajirobe wouldn't hoard food like this.",
        need_dirt: "{name} could really use a bath. Training dirt is still dirt.",
        need_tired: "{name} can barely stand. Even Saiyans sleep sometimes.",
        need_bored: "{name} is bored stiff. Send me out! Nimbus is waiting!",
        need_lonely: "Hey… {name} misses you. One little spar? A pat counts.",
        moonrise: "SCOUTER: the moon is full. {name} is… not himself. Approach the bar with caution.",
        dawn: "Morning! {name} here. Weird dreams. Why is there a crater outside?",
        chatter: [
            "Did you eat yet? Big day of sitting at this desk — keep your strength up.",
            "I counted the windows on this screen. All strong opponents. Good.",
            "Kind of quiet today. Quiet is nice. Suspiciously nice.",
            "I did four hundred push-ups while you weren't looking. Probably.",
            "This machine's ki feels steady. You take good care of things.",
            "If a giant space tyrant shows up, I'm ready. Just saying."
        ]
    },
    vegeta: {
        evolve_baby: "{name}, prince of all Saiyans, has hatched. Kneel. Or feed me. Both.",
        evolve_child: "{name} grows stronger. This 'childhood' phase is beneath me, but acceptable.",
        evolve_teen_neat: "Hmph. {name} is a teen. Your maintenance was… adequate.",
        evolve_teen_scruffy: "{name} grew up feral. Good. Polish is for Earthlings.",
        evolve_adult: "Behold {name}, at full power. This desktop is now the strongest in the solar system.",
        rebirth: "He left without ceremony. Typical. A new pod approaches — Gen {gen}. Try to keep up.",
        line_selected: "Royal signature locked. {name} of the Vegeta line approaches. Show some respect.",
        transformation: "{name} has ascended to {rung}. Naturally.",
        hard_landing: "I MEANT to land like that. Speak of this to no one.",
        need_hunger: "{name} requires sustenance. NOW. A prince does not 'wait for lunch'.",
        need_dirt: "This filth is an insult. Clean {name} at once.",
        need_tired: "{name} does not 'nap'. {name} strategically recovers. Allow it.",
        need_bored: "{name} is wasting away in this box. Release me or suffer the whining.",
        need_lonely: "{name} does not miss you. {name} merely notes your absence. Constantly.",
        moonrise: "SCOUTER: full moon. {name} remembers what he is. Stay clear of the bar.",
        dawn: "The moon is down. {name} is himself again. We will not discuss the roaring.",
        chatter: [
            "Forty-seven browser tabs. Your discipline disgusts me.",
            "I have been training while you type. One of us is improving.",
            "This machine could be stronger. So could you. I say this with respect. Barely.",
            "Kakarot's line would have eaten your lunch by now. Count your blessings.",
            "Silence. Good. I was meditating, not sulking.",
            "When this computer finally transforms, remember who kept its ki honest."
        ]
    },
    piccolo: {
        evolve_baby: "{name} has hatched. It is loud and it needs things. I will manage.",
        evolve_child: "{name} is a child now. The questions have started. There are many.",
        evolve_teen_neat: "{name} has grown disciplined. Someone raised it right. I take partial credit.",
        evolve_teen_scruffy: "{name} grew up rough around the edges. Rough edges cut deeper. Fine by me.",
        evolve_adult: "{name} is fully grown. My work here continues anyway.",
        rebirth: "He left quietly. Respectable. A new pod has landed — Gen {gen}.",
        line_selected: "Signature locked. {name}. Expect little conversation. That is a feature.",
        transformation: "{name}: {rung}. The machine earned it. Back to work.",
        hard_landing: "That fall was sloppy. We will train the landing. Later.",
        need_hunger: "{name} needs water. Just water. This should be easy for you.",
        need_dirt: "{name} meditates better clean. See to it.",
        need_tired: "{name} is exhausted. Rest is training too. Do not wake it.",
        need_bored: "{name} is restless. Stillness must be learned. Open the door anyway.",
        need_lonely: "{name} would not say it misses you. I am saying it. Once.",
        chatter: [
            "Finally. Silence.",
            "I heard your notification sound nine times this hour. Consider your choices.",
            "The waterfall was louder than this office. I have adapted.",
            "Meditation report: no progress on your clutter. Some things resist enlightenment.",
            "You work. I watch. This arrangement is acceptable."
        ]
    },
    krillin: {
        evolve_baby: "Hey, {name} hatched! Tiny, bald, adorable. Runs in the family.",
        evolve_child: "{name}'s a kid now! Already braver than me. Not a high bar, but still.",
        evolve_teen_neat: "{name} turned out great! Honestly kind of relieved. Okay, very relieved.",
        evolve_teen_scruffy: "{name}'s a scrappy teen now. A little chaotic? Sure. Lovable? Extremely.",
        evolve_adult: "{name} made it to full strength! Who says the support cast can't go the distance?",
        rebirth: "He said thanks for everything before he left. I teared up. New pod incoming — Gen {gen}!",
        line_selected: "Signature locked. It's {name}! Low maintenance, high loyalty. Good pick.",
        transformation: "Whoa, {name} hit {rung}! I'll just… stand over here. Proudly.",
        hard_landing: "I'm okay! The floor broke my fall. The floor is fine too. Mostly.",
        need_hunger: "Um, {name} here. Really hungry. No rush! Okay, small rush.",
        need_dirt: "{name}'s a mess and pretending not to mind. I mind. Help?",
        need_tired: "{name} is running on fumes. Even destructo discs need a recharge.",
        need_bored: "{name} has reorganized the room twice. Please. Anything. A walk?",
        need_lonely: "Not to be needy, but {name} misses you a lot. This is me being needy.",
        chatter: [
            "Everything's fine here! Just, you know, checking in. Like I do.",
            "I did a hundred sit-ups. Okay, ten. Okay, I thought about it.",
            "Your screen's power levels are way above mine. Story of my life.",
            "Quiet day. I like quiet days. Statistically, something explodes soon.",
            "If anything scary shows up on the scouter, I'll yell. Loudly. That's my role."
        ]
    },
    frieza: {
        evolve_baby: "{name} has emerged. How small. How fragile. How very like your filing system.",
        evolve_child: "{name} is developing nicely. The screaming phase suits this household.",
        evolve_teen_neat: "{name} has matured with such polish. Almost as if raised by someone competent. Almost.",
        evolve_teen_scruffy: "{name} grew up untidy. I would say I am disappointed, but expectations were low.",
        evolve_adult: "{name}, final form. Applaud. Slowly. With feeling.",
        rebirth: "He has departed. How touching. A new vessel arrives — generation {gen}. Do better this time.",
        line_selected: "Signature locked. {name} graces this desktop. You may express gratitude at any time.",
        transformation: "{name} has reached {rung}. The machine flatters itself. I allow it.",
        hard_landing: "I dropped nothing. The planet rose to meet me. We will not discuss it further.",
        need_hunger: "{name} hungers. Feed me, or the mood in this bar becomes… festive.",
        need_dirt: "This place is FILTHY, and now, so am I. Rectify it.",
        need_tired: "{name} requires beauty rest. Interruptions will be remembered. Fondly. At length.",
        need_bored: "{name} is bored. Bored emperors make poor desk ornaments. Amuse me.",
        need_lonely: "{name} notes you have been away. Not that it matters. It has been logged. Twice.",
        chatter: [
            "I have inspected your filesystem. We shall speak of it never.",
            "Such industrious little clicks. Like ants. Ambitious, doomed ants.",
            "Your machine hums along adequately. Praise, from me. Savor it.",
            "I counted the dust motes. Seven thousand. One of us should care.",
            "Do continue working. An audience of one is still an audience."
        ]
    }
}

// The event copy for one line, placeholders substituted. null means "this line has no
// such moment" (a missing key, or moon copy on a moonless line) -- callers skip the
// notification entirely rather than toasting an empty string.
function speak(id, key, ctx) {
    var sp = SPEECH[safeId(id)]
    var s = sp ? sp[key] : undefined
    if (typeof s !== "string" || s.length === 0) return null
    if (ctx && typeof ctx === "object")
        for (var k in ctx) s = s.split("{" + k + "}").join(String(ctx[k]))
    return s
}

function chatterLines(id) {
    var sp = SPEECH[safeId(id)]
    return (sp && Array.isArray(sp.chatter)) ? sp.chatter.slice() : []
}

function profile(id, generation) {
    var safe = safeId(id)
    var n = gen(generation)
    return {
        line: safe,
        generation: n,
        name: nameFor(safe, n),
        room: roomFor(safe, n),
        rates: ratesFor(safe),
        blurb: blurbFor(safe),
        oozaru: isOozaruLine(safe),
        moveColor: moveColor(safe),
        rungColor: function (i) { return rungColor(safe, i) },
        baseSprite: function (stage, form) { return baseSprite(safe, stage, form) },
        rungLabel: function (i) { return rungLabel(safe, i) }
    }
}
