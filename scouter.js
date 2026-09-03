.pragma library

// The window scouter: reading ONE process and saying so honestly.
//
// A browser is forty processes, so a toplevel pid's RSS is not the window's memory. The
// number is real; the copy is what keeps it honest. Scouters are famously inaccurate --
// that is canon, and here it also happens to be true.

var PAGE_KB = 4
var MAX_PID = 4194304
var TITLE_CAP = 64
// Dead states parse perfectly cleanly, which is the trap: a well-formed line with rss 0
// would render "BP 0", a measured-looking number for a process that is not there.
var DEAD_STATES = ["Z", "X", "x"]

function validPid(p) {
    return typeof p === "number" && isFinite(p) && Math.floor(p) === p
        && p >= 1 && p <= MAX_PID
}

// Field 2 of /proc/<pid>/stat is the comm, in parentheses, and it MAY CONTAIN SPACES AND
// PARENTHESES. Splitting on whitespace shifts every later field: pid 338317 on this desktop
// is named "npm exec @playw" and a naive parse reports 7.1 GB for a 22 MB process. Split
// after the LAST close paren. (`rindexOf` is not a JavaScript method; this is lastIndexOf.)
function parseStat(text, expectPid, pageKb) {
    var err = { status: "error", state: null, rssKb: null, starttime: null }
    if (!text || typeof text !== "string") return err

    var close = text.lastIndexOf(")")
    var open = text.indexOf("(")
    if (close < 0 || open < 0 || open > close) return err

    var pid = Number(text.slice(0, open).trim())
    if (!validPid(pid) || pid !== expectPid) return err

    var rest = text.slice(close + 1).trim()
    if (rest.length === 0) return err
    var f = rest.split(/\s+/)
    // Indices counted from the first field AFTER the close paren.
    if (f.length < 22) return err

    var state = f[0]
    var starttime = Number(f[19])
    var rssPages = Number(f[21])
    if (!isFinite(starttime) || !isFinite(rssPages)) return err

    var kb = (pageKb === undefined || pageKb === null) ? PAGE_KB : pageKb
    var rssKb = (DEAD_STATES.indexOf(state) >= 0 || rssPages <= 0)
        ? null : rssPages * kb
    return { status: "ok", state: state, rssKb: rssKb, starttime: starttime }
}

// RSS to a themed number. Snapped to a magnitude-scaled step so it holds still against the
// few megabytes of idle drift every process has, instead of jittering every poll.
function power(rssKb) {
    if (rssKb === null || rssKb === undefined || !isFinite(rssKb) || rssKb <= 0) return null
    var raw = rssKb / 64
    if (raw < 10) return Math.round(raw)
    var step = Math.pow(10, Math.floor(Math.log(raw) / Math.LN10) - 1)
    return Math.round(raw / step) * step
}

// A value is adopted only after it repeats, so one jitter never moves the readout.
function adopt(state, next) {
    var st = (state && typeof state === "object")
        ? { candidate: state.candidate, count: state.count, value: state.value }
        : { candidate: null, count: 0, value: null }
    if (next === st.candidate) st.count += 1
    else { st.candidate = next; st.count = 1 }
    if (st.count >= 2) st.value = st.candidate
    return { value: st.value === undefined ? null : st.value, state: st }
}

// Window titles and classes are untrusted text. The bubble sets Text.PlainText, but the
// notification body reaches omarchy-notification-send and a renderer this plugin does not
// control -- so markup is neutralised here rather than relying on the surface.
function sanitize(s) {
    if (s === null || s === undefined) return ""
    var out = String(s)
    var kept = []
    var chars = Array.from(out)
    for (var i = 0; i < chars.length; i++) {
        var c = chars[i].charCodeAt(0)
        // C0, DEL and C1 controls.
        if (c < 0x20 || c === 0x7f || (c >= 0x80 && c <= 0x9f)) { kept.push(" "); continue }
        // Bidi overrides and embeddings, which can reorder a title into a lie.
        if ((c >= 0x202a && c <= 0x202e) || (c >= 0x2066 && c <= 0x2069)) continue
        if (chars[i] === "<" || chars[i] === ">" || chars[i] === "&") continue
        kept.push(chars[i])
    }
    var joined = kept.join("").replace(/\s+/g, " ").replace(/^ | $/g, "")
    var arr = Array.from(joined)
    return arr.length > TITLE_CAP ? arr.slice(0, TITLE_CAP).join("") : joined
}

// The copy carries the honesty, not the number. "window", "app" and "total" are banned:
// one pid commonly serves several windows of the same terminal, and a browser's usage is
// split across many. A pid is not a window.
function label(cls, bp, title, titlesOn) {
    var head = sanitize(cls) + " -- BP " + bp + ". One process of it."
    if (titlesOn !== true) return head
    var t = sanitize(title)
    // Omitted entirely when there is nothing to say -- never blanked, never a placeholder.
    return t.length === 0 ? head : head + ' "' + t + '"'
}
