import QtQuick
import QtTest
import "../wm.js" as Wm

// The fullscreen-suppression predicate: pure data in, bool out. The set of active
// workspaces covers EVERY monitor, so chatter cannot escape on a second screen.
TestCase {
  name: "Wm"

  function tl(ws, fs) { return { workspaceId: ws, fullscreen: fs } }

  function test_no_toplevels_is_not_fullscreen() {
    compare(Wm.anyFullscreen([], [1]), false)
    compare(Wm.anyFullscreen(null, [1]), false)
    compare(Wm.anyFullscreen([tl(1, true)], null), false)
  }

  function test_fullscreen_on_an_active_workspace_suppresses() {
    compare(Wm.anyFullscreen([tl(1, true)], [1]), true)
  }

  function test_fullscreen_on_an_inactive_workspace_does_not_suppress() {
    compare(Wm.anyFullscreen([tl(3, true)], [1, 2]), false)
  }

  function test_any_monitors_active_workspace_counts() {
    compare(Wm.anyFullscreen([tl(2, true)], [1, 2]), true)
  }

  function test_non_fullscreen_toplevels_do_not_suppress() {
    compare(Wm.anyFullscreen([tl(1, false), tl(1, undefined)], [1]), false)
  }
}
