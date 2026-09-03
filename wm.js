.pragma library

// Window-manager predicates on plain data, so they are testable without Hyprland.

// True when any toplevel on ANY monitor's active workspace is fullscreen. The ids cover
// every monitor (Hyprland keeps one active workspace per monitor), so chatter cannot
// escape while a second screen is showing a movie.
function anyFullscreen(toplevels, activeWorkspaceIds) {
    if (!toplevels || !activeWorkspaceIds) return false
    for (var i = 0; i < toplevels.length; i++) {
        var t = toplevels[i]
        if (!t || t.fullscreen !== true) continue
        if (activeWorkspaceIds.indexOf(t.workspaceId) >= 0) return true
    }
    return false
}
