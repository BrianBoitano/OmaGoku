.pragma library

// Probe-pack parsing, pure. A probe result is { status, ... }: anything the parser does
// not fully understand is an error, never a guessed number, because unknown removes the
// pet's effect while a wrong number would lie with confidence.

// df --output=source,target,pcent output: one header line, then "source target pcent%".
// Rows are deduplicated by filesystem identity (the source column), so a /home that is
// not a separate filesystem never double-reports the root.
function parseDf(text) {
    if (!text || typeof text !== "string") return { status: "error" }
    var lines = text.split("\n")
    var seen = {}
    var worst = null
    for (var i = 1; i < lines.length; i++) {
        var line = lines[i].trim()
        if (line === "") continue
        var cols = line.split(/\s+/)
        if (cols.length !== 3) return { status: "error" }
        var m = /^(\d{1,3})%$/.exec(cols[2])
        if (!m) return { status: "error" }
        var pcent = Number(m[1])
        if (!isFinite(pcent) || pcent > 100) return { status: "error" }
        if (cols[0] in seen) continue
        seen[cols[0]] = true
        if (!worst || pcent > worst.pcent) worst = { pcent: pcent, target: cols[1] }
    }
    if (!worst) return { status: "error" }
    return { status: "ok", worst: worst }
}

// systemctl --failed --no-pager --no-legend --plain: one unit per line, unit name first.
// An empty output is a healthy zero; a line that does not look like a unit row is an
// error, not a count.
function parseFailedUnits(text) {
    if (text === undefined || text === null || typeof text !== "string")
        return { status: "error" }
    var trimmed = text.trim()
    if (trimmed === "") return { status: "ok", count: 0 }
    var lines = trimmed.split("\n")
    for (var i = 0; i < lines.length; i++) {
        var cols = lines[i].trim().split(/\s+/)
        if (cols.length < 4 || cols[0].indexOf(".") < 0) return { status: "error" }
    }
    return { status: "ok", count: lines.length }
}

// The two managers are tracked separately, and the combined count exists only when BOTH
// are ok -- a half-known count displayed as complete would be a quiet lie.
function combineFailed(sys, user) {
    if (!sys || !user || sys.status !== "ok" || user.status !== "ok")
        return { status: "unknown", count: 0 }
    return { status: "ok", count: sys.count + user.count }
}

function fresh(probe, nowMs, ttlMs) {
    if (!probe || typeof probe.sampledAtMs !== "number"
        || !isFinite(probe.sampledAtMs)) return false
    return nowMs - probe.sampledAtMs <= ttlMs
}
