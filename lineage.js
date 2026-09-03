.pragma library
.import "lines.js" as Lines

// The lineage record: one row per pet that has ended, in its OWN file.
//
// Deliberately not the pet save, because resetPet() wipes that and surviving it is this
// record's entire purpose. Two rules govern everything here:
//
//   IT MUST NEVER BLOCK A PET ENDING. Total functions only; a hostile file degrades, and
//   the caller runs the ending in a finally.
//
//   IT MUST NEVER DESTROY HISTORY. A corrupt or unreadable file is READ-ONLY, not an empty
//   writable one -- degrading corruption to "empty" means the next ending overwrites every
//   recoverable generation with a single row.

var SCHEMA_V = 1
var MAX_ENTRIES = 100
var MAX_BYTES = 65536
var MAX_INT = 4102444800000

var ENDED_BY = ["farewell", "reset"]
var STAGES = ["egg", "baby", "child", "teen", "adult"]
var FORMS = ["pod", "baby", "child", "teen_neat", "teen_scruffy",
             "adult_ace", "adult_ok", "adult_gremlin"]

// A live ending records its progression. A frozen or corrupt one records that it could not.
//
// Each carries its OWN maximum, and read and write use the same one. A single shared bound
// let peakKiRung be written through safeInt(v, 3) and validated on read against 1e8, so a
// hand-edited rung 500 would load -- and Lines.rungLabel maps anything out of range to the
// LOWEST rung, which would render an Ultra Instinct pet's peak as "Base".
var LIVE_MAX = {
    curve: 1000,
    xp: 100000000,
    peakKiRung: 3,
    ballsCollected: 1000000,
    wishesGranted: 1000000
}
var LIVE_FIELDS = ["curve", "xp", "peakKiRung", "ballsCollected", "wishesGranted"]

function emptyRecord() { return { v: SCHEMA_V, entries: [] } }

function isPlainObject(v) {
    return v !== null && typeof v === "object" && !(v instanceof Array)
}

function safeInt(v, max) {
    return (typeof v === "number" && isFinite(v) && Math.floor(v) === v
            && v >= 0 && v <= max) ? v : null
}

function validPetId(v) {
    return (typeof v === "string" && /^[0-9a-f]{32}$/.test(v)) ? v : null
}

// --- loading ----------------------------------------------------------------

// Takes the READER'S OWN RESULT, not just its text. `head` exits non-zero identically for a
// missing file, a permission failure and an I/O error, so a caller that only passes text
// cannot tell "no history yet" from "history we could not read" -- and those two must not
// lead to the same place.
function load(reader) {
    var r = reader || {}
    if (r.status === "missing") return loaded("missing", [], 0, 0)
    if (r.status !== "ok") return loaded("corrupt", [], 0, 0)
    if (typeof r.bytes === "number" && r.bytes > MAX_BYTES)
        return loaded("corrupt", [], 0, 0)
    var text = typeof r.text === "string" ? r.text : ""
    if (text.trim() === "") return loaded("missing", [], 0, 0)

    var d
    try { d = JSON.parse(text) } catch (e) { return loaded("corrupt", [], 0, 0) }
    if (!isPlainObject(d) || d.v !== SCHEMA_V || !(d.entries instanceof Array))
        return loaded("corrupt", [], 0, 0)

    // The cap runs on the RAW array, BEFORE validation. Validating first and keeping the
    // newest MAX_ENTRIES survivors lets 100 valid rows plus one invalid one retain 101
    // positions against a cap of 100, and counts an unreadable row the cap should already
    // have evicted. The array is oldest-first (upsert pushes and shifts), so the newest
    // MAX_ENTRIES positions are the tail.
    var droppedByCap = Math.max(0, d.entries.length - MAX_ENTRIES)
    var slice = droppedByCap > 0 ? d.entries.slice(droppedByCap) : d.entries

    // A row we cannot read does NOT get dropped. Dropping it destroys it at the next
    // ending, because the writer serialises the record it loaded -- and a value that has
    // been through JSON.parse cannot be re-emitted byte-identically, so re-emitting it is
    // not an option either. The honest answer is to stop writing: `partial` shows what
    // parsed and refuses every write until a human repairs the file or archives it.
    var out = []
    var unreadable = 0
    for (var i = 0; i < slice.length; i++) {
        var e = readEntry(slice[i])
        if (e !== null) out.push(e)
        else unreadable++
    }
    return loaded(unreadable > 0 ? "partial" : "valid", out, unreadable, droppedByCap)
}

function loaded(mode, entries, unreadableRows, droppedByCap) {
    return {
        mode: mode,
        record: { v: SCHEMA_V, entries: entries },
        unreadableRows: unreadableRows,
        droppedByCap: droppedByCap,
        priorMode: null,
        backupPath: null
    }
}

function canWrite(mode) { return mode === "valid" || mode === "missing" }

// The archive may act on a record no ending may write, because it is the escape hatch out
// of `partial`. It is still an ALLOWLIST, so a mode nobody anticipated is refused by
// default -- read-only is the safe side of every ambiguity. `corrupt` stays refused: a file
// we could not parse at all may be all that is left of a person's history.
function canWipe(mode) {
    return mode === "valid" || mode === "missing"
        || mode === "partial" || mode === "write-failed"
}

// --- entries ----------------------------------------------------------------

// A discriminated union keyed by progressMode, not one shape with nullable progression
// fields: nullable fields let a strict loader reject its own output and a permissive one
// accept an incoherent mixture.
function buildEntry(ctx) {
    var c = ctx || {}
    var mode = c.progressMode
    // No progression subtree means there was no pet. An unclaimed pod is not a generation.
    if (mode !== "live" && mode !== "frozen" && mode !== "corrupt") return null
    var petId = validPetId(c.petId)
    // No stable identity, no row. A freshly minted fallback id would defeat the upsert: a
    // crash after the write and before the reset appends a second ending for the same pet.
    if (petId === null) return null
    if (!Lines.has(c.line)) return null
    if (ENDED_BY.indexOf(c.endedBy) < 0) return null
    if (STAGES.indexOf(c.stage) < 0) return null
    if (FORMS.indexOf(c.form) < 0) return null
    var gen = safeInt(c.gen, 1000000)
    if (gen === null) return null

    var e = {
        progressMode: mode,
        petId: petId,
        gen: gen,
        line: c.line,
        endedBy: c.endedBy,
        stage: c.stage,
        form: c.form,
        bornAt: safeInt(c.bornAt, MAX_INT),
        endedAt: safeInt(c.endedAt, MAX_INT)
    }
    if (mode !== "live") return e

    e.curve = safeInt(c.curve, LIVE_MAX.curve)
    e.xp = safeInt(c.xp, LIVE_MAX.xp)
    e.peakKiRung = safeInt(c.peakKiRung, LIVE_MAX.peakKiRung)
    e.ballsCollected = safeInt(c.ballsCollected, LIVE_MAX.ballsCollected)
    e.wishesGranted = safeInt(c.wishesGranted, LIVE_MAX.wishesGranted)
    // Nullable on purpose: a pet that was never sampled has no average, and 0 would be a
    // claim that it was neglected.
    e.careAverage = safeInt(c.careAverage, 100)
    for (var i = 0; i < LIVE_FIELDS.length; i++)
        if (e[LIVE_FIELDS[i]] === null) return null
    return e
}

function validEntry(e) {
    if (!isPlainObject(e)) return false
    if (validPetId(e.petId) === null) return false
    // Lines.has() is the whole check: it requires a string and membership in a fixed
    // five-id allowlist, so a separate length bound could never be the thing that rejects a
    // row. A guard that cannot fire is worse than no guard, because the next reader trusts it.
    if (!Lines.has(e.line)) return false
    if (ENDED_BY.indexOf(e.endedBy) < 0) return false
    if (STAGES.indexOf(e.stage) < 0) return false
    if (FORMS.indexOf(e.form) < 0) return false
    if (safeInt(e.gen, 1000000) === null) return false
    if (e.bornAt !== null && safeInt(e.bornAt, MAX_INT) === null) return false
    if (e.endedAt !== null && safeInt(e.endedAt, MAX_INT) === null) return false

    if (e.progressMode === "live") {
        for (var i = 0; i < LIVE_FIELDS.length; i++)
            if (safeInt(e[LIVE_FIELDS[i]], LIVE_MAX[LIVE_FIELDS[i]]) === null) return false
        if (e.careAverage !== null && safeInt(e.careAverage, 100) === null) return false
        return true
    }
    if (e.progressMode !== "frozen" && e.progressMode !== "corrupt") return false
    // FORBIDDEN, not null: an absent field says "not recorded".
    for (var j = 0; j < LIVE_FIELDS.length; j++) if (LIVE_FIELDS[j] in e) return false
    if ("careAverage" in e) return false
    return true
}

function readEntry(raw) {
    if (!validEntry(raw)) return null
    var out = {
        progressMode: raw.progressMode, petId: raw.petId, gen: raw.gen, line: raw.line,
        endedBy: raw.endedBy, stage: raw.stage, form: raw.form,
        bornAt: raw.bornAt === undefined ? null : raw.bornAt,
        endedAt: raw.endedAt === undefined ? null : raw.endedAt
    }
    if (raw.progressMode === "live") {
        for (var i = 0; i < LIVE_FIELDS.length; i++) out[LIVE_FIELDS[i]] = raw[LIVE_FIELDS[i]]
        out.careAverage = raw.careAverage === undefined ? null : raw.careAverage
    }
    return out
}

// --- writing ----------------------------------------------------------------

// An UPSERT by petId, not an append: a crash between the lineage write and the pet reset
// leaves the ending to be retried, and a second row for one pet is a fabricated generation.
function upsert(record, entry) {
    var rec = (isPlainObject(record) && record.entries instanceof Array)
        ? { v: SCHEMA_V, entries: record.entries.slice() } : emptyRecord()
    if (entry === null || entry === undefined) return rec
    for (var i = 0; i < rec.entries.length; i++) {
        if (rec.entries[i].petId === entry.petId) { rec.entries[i] = entry; return rec }
    }
    rec.entries.push(entry)
    while (rec.entries.length > MAX_ENTRIES) rec.entries.shift()
    return rec
}

function toText(record) {
    return JSON.stringify({ v: SCHEMA_V, entries: record.entries }, null, 2) + "\n"
}

// The reader is `head -c`, which counts BYTES, and the stat probe refuses a file over the
// cap outright -- and a refused file is CORRUPT, which is read-only forever. So the writer
// has to measure the same way the reader does.
function byteLength(s) {
    if (typeof s !== "string") return 0
    var n = 0
    for (var i = 0; i < s.length; i++) {
        var c = s.charCodeAt(i)
        if (c < 0x80) n += 1
        else if (c < 0x800) n += 2
        else if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) { n += 4; i++ }
        else n += 3
    }
    return n
}

// Trim from the OLDEST end until the serialised record fits, mirroring the direction upsert
// already drops in. Returns null when no honest trim exists -- there is then no record to
// write, which is a refusal, not an empty file. The pet save preflights its own size the
// same way; this path had no guard at all, so one extra field on a full record was a silent
// one-way trip to a permanently unreadable history.
function fit(record, capBytes) {
    var entries = (isPlainObject(record) && record.entries instanceof Array)
        ? record.entries.slice() : []
    var had = entries.length
    while (byteLength(toText({ v: SCHEMA_V, entries: entries })) >= capBytes) {
        if (entries.length === 0) return null
        entries.shift()
    }
    if (had > 0 && entries.length === 0) return null
    return { v: SCHEMA_V, entries: entries }
}
