.pragma library

// The dragon ball hunt: seven balls over six days, then Shenron.
//
// THIS IS THE FIRST FEATURE TO PERSIST STATE INSIDE THE PET'S SAVE FILE, which resets a pet
// to a fresh egg when it cannot be understood. So `fromSave` is a TOTAL function -- it is
// called OUTSIDE the biography try and may never throw for any input at all. A game object
// must not be able to erase a pet's biography.
//
// Structure is validated here; TIME is decided in the non-mutating eligibility helpers and
// nowhere else. A future timestamp means "not yet", never "corrupt": the desktop's clock is
// wrong for the first minute after every boot, which is exactly when the shell starts.

var STATE_KEYS = ["v", "pending", "scatteredAt", "items", "wish", "keepsake", "summon"]

var BALL_COUNT = 7
var DAY_MS = 86400000
var UNSEEN_MS = 48 * 3600000
var WISH_MS = 86400000
var WISH_KINDS = ["full_recovery", "care_ceiling", "keepsake"]
var MAX_TIME = 9007199254740991 - 6 * DAY_MS

function emptyState() {
    return { v: 1, pending: true, scatteredAt: null, items: [],
             wish: null, keepsake: null, summon: null }
}

function safeInt(v) {
    return typeof v === "number" && isFinite(v) && v >= 0
        && Math.floor(v) === v && v <= 9007199254740991
}

function validItem(it) {
    if (!it || typeof it !== "object") return false
    if (!(typeof it.ws === "number" && isFinite(it.ws) && Math.floor(it.ws) === it.ws
          && it.ws > 0)) return false
    if (!(typeof it.x === "number" && isFinite(it.x) && it.x >= 0 && it.x <= 1)) return false
    if (!safeInt(it.placedAt) || !safeInt(it.lastSeenAt)) return false
    return it.collected === true || it.collected === false
}

function validWish(w) {
    if (!w || typeof w !== "object") return null
    if (w.kind !== "care_ceiling") return null
    if (!safeInt(w.grantedAt) || !safeInt(w.expiresAt)) return null
    if (w.grantedAt > MAX_TIME) return null
    if (w.expiresAt !== w.grantedAt + WISH_MS) return null
    return { kind: "care_ceiling", grantedAt: w.grantedAt, expiresAt: w.expiresAt }
}

// Never throws. Every branch returns a canonical object.
function fromSave(raw, nowMs, generation) {
    var st = emptyState()
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) return st

    // The three subtrees degrade INDEPENDENTLY: a malformed hunt must not delete a valid
    // wish, and a malformed wish must not scatter a valid hunt.
    st.wish = validWish(raw.wish)
    st.keepsake = (safeInt(raw.keepsake) && raw.keepsake === generation)
        ? raw.keepsake : null

    var huntOk = raw.v === 1 && safeInt(raw.scatteredAt) && raw.scatteredAt <= MAX_TIME
        && Array.isArray(raw.items) && raw.items.length === BALL_COUNT
    if (huntOk) {
        for (var i = 0; i < BALL_COUNT; i++)
            if (!validItem(raw.items[i])) { huntOk = false; break }
    }

    var summon = null
    if (raw.summon && typeof raw.summon === "object"
        && (raw.summon.notified === true || raw.summon.notified === false)
        && safeInt(raw.summon.hunt) && raw.summon.hunt === raw.scatteredAt)
        summon = { hunt: raw.summon.hunt, notified: raw.summon.notified }

    if (huntOk) {
        st.pending = false
        st.scatteredAt = raw.scatteredAt
        st.items = []
        for (var j = 0; j < BALL_COUNT; j++) {
            var s = raw.items[j]
            st.items.push({ ws: s.ws, x: s.x, placedAt: s.placedAt,
                            lastSeenAt: s.lastSeenAt, collected: s.collected })
        }
        st.summon = summon
        return st
    }

    // A VALID summon outranks a broken hunt: otherwise a corrupt items array would start a
    // fresh week underneath a Shenron the pet genuinely earned.
    if (summon) {
        st.summon = summon
        st.suppressed = true
    }
    return st
}

// What actually goes on disk. Pending is a real second shape -- omitting `balls` entirely
// would discard a wish or a keepsake the pet had earned.
function toSave(state) {
    var out = { v: 1 }
    if (state.wish) out.wish = state.wish
    if (state.keepsake !== null && state.keepsake !== undefined) out.keepsake = state.keepsake
    if (state.pending) return out
    out.scatteredAt = state.scatteredAt
    out.items = state.items
    if (state.summon) out.summon = state.summon
    return out
}

// --- eligibility: the only place time is judged -------------------------------

function elapsed(nowMs, then) {
    return Math.max(0, nowMs - then)
}

function isFindable(state, i, nowMs) {
    if (state.pending || !safeInt(state.scatteredAt)) return false
    if (state.scatteredAt > nowMs) return false        // clock not settled: not yet
    return elapsed(nowMs, state.scatteredAt) >= i * DAY_MS
}

function findableCount(state, nowMs) {
    var n = 0
    for (var i = 0; i < state.items.length; i++) if (isFindable(state, i, nowMs)) n++
    return n
}

function collectedCount(state) {
    var n = 0
    for (var i = 0; i < state.items.length; i++) if (state.items[i].collected) n++
    return n
}

function allCollected(state) {
    return !state.pending && collectedCount(state) === BALL_COUNT
}

function visibleIndexes(state, activeWs, nowMs) {
    var out = []
    for (var i = 0; i < state.items.length; i++)
        if (!state.items[i].collected && state.items[i].ws === activeWs
            && isFindable(state, i, nowMs)) out.push(i)
    return out
}

// Scoped to the ACTIVE workspace: a global lowest-index rule would let a ball on a
// workspace nobody opens block the button for one standing in front of them.
function targetIndex(state, activeWs, nowMs) {
    var v = visibleIndexes(state, activeWs, nowMs)
    return v.length === 0 ? -1 : v[0]
}

// --- mutation ------------------------------------------------------------------

function copy(state) {
    var items = []
    for (var i = 0; i < state.items.length; i++) {
        var s = state.items[i]
        items.push({ ws: s.ws, x: s.x, placedAt: s.placedAt,
                     lastSeenAt: s.lastSeenAt, collected: s.collected })
    }
    return { v: 1, pending: state.pending, scatteredAt: state.scatteredAt, items: items,
             wish: state.wish, keepsake: state.keepsake, summon: state.summon }
}

// Placement needs workspace data, which only the compositor has -- which is why fromSave
// returns pending rather than inventing a workspace at load time.
function place(state, nowMs, workspaces, rand) {
    if (!workspaces || workspaces.length === 0) return state
    var st = copy(state)
    var pool = workspaces.slice()
    var items = []
    for (var i = 0; i < BALL_COUNT; i++) {
        // Spread across the set; repeat only when there are fewer than seven to go round.
        if (pool.length === 0) pool = workspaces.slice()
        var r = Math.floor(Number(rand ? rand() : 0) * pool.length)
        if (!isFinite(r) || r < 0 || r >= pool.length) r = 0
        var ws = pool.splice(r, 1)[0]
        var x = Number(rand ? rand() : 0.5)
        if (!isFinite(x) || x < 0 || x > 1) x = 0.5
        items.push({ ws: ws, x: 0.06 + x * 0.88, placedAt: nowMs, lastSeenAt: nowMs,
                     collected: false })
    }
    st.pending = false
    st.scatteredAt = nowMs
    st.items = items
    st.summon = null
    return st
}

// The active workspace counts as an observation, and a ball on it NEVER relocates however
// old its stamps are -- transition-only stamping misses the workspace already active when
// the shell starts, and a ball in plain view must not vanish seconds later.
function markSeen(state, activeWs, nowMs) {
    if (state.pending) return state
    var st = copy(state)
    var changed = false
    for (var i = 0; i < st.items.length; i++)
        if (st.items[i].ws === activeWs && st.items[i].lastSeenAt !== nowMs) {
            st.items[i].lastSeenAt = nowMs
            changed = true
        }
    return changed ? st : state
}

function relocate(state, nowMs, activeWs, workspaces) {
    if (state.pending) return state
    // No eligible active workspace: leave everything exactly as it is rather than guess.
    if (!workspaces || workspaces.length === 0) return state
    if (!(typeof activeWs === "number" && activeWs > 0)) return state
    var st = copy(state)
    var changed = false
    for (var i = 0; i < st.items.length; i++) {
        var it = st.items[i]
        if (it.collected || it.ws === activeWs) continue
        if (!isFindable(state, i, nowMs)) continue
        if (it.lastSeenAt > nowMs) continue              // clock not settled
        if (elapsed(nowMs, it.lastSeenAt) < UNSEEN_MS) continue
        it.ws = activeWs
        it.x = it.x
        it.placedAt = nowMs
        it.lastSeenAt = nowMs
        changed = true
    }
    return changed ? st : state
}

function collectAt(state, i, nowMs) {
    if (state.pending || i < 0 || i >= state.items.length) return state
    if (state.items[i].collected) return state
    var st = copy(state)
    st.items[i].collected = true
    return st
}

// --- Shenron and the wishes ----------------------------------------------------

function canSummon(state, localHour) {
    if (!allCollected(state)) return false
    if (state.summon) return false
    return localHour >= 18 && localHour < 21
}

function recordSummon(state, nowMs) {
    if (state.pending) return state
    var st = copy(state)
    st.summon = { hunt: st.scatteredAt, notified: false }
    return st
}

function markNotified(state) {
    if (!state.summon) return state
    var st = copy(state)
    st.summon = { hunt: st.summon.hunt, notified: true }
    return st
}

// An INDEX or null. NEVER a boolean: `true` coerces to 1 inside Math.min and would CAP an
// honest Blue or Ultra Instinct reading at Super Saiyan.
function wishCeiling(state, nowMs) {
    var w = state.wish
    if (!w) return null
    if (w.grantedAt > nowMs) return null      // granted in the future: not yet, not cancelled
    if (nowMs >= w.expiresAt) return null
    return 3
}

function applyWish(state, kind, nowMs, generation) {
    if (WISH_KINDS.indexOf(kind) < 0) return state
    var st = copy(state)
    if (kind === "care_ceiling")
        st.wish = { kind: "care_ceiling", grantedAt: nowMs, expiresAt: nowMs + WISH_MS }
    else if (kind === "keepsake")
        st.keepsake = generation
    // The balls scatter as stone; the next hunt places when workspace data is next known.
    st.pending = true
    st.scatteredAt = null
    st.items = []
    st.summon = null
    return st
}
