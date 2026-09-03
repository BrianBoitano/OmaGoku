import QtQuick
import QtTest
import "../lines.js" as Lines

// The speech contract: every line carries its own copy for every event the pipeline can
// fire, so Vegeta and Krillin never say the same thing, and no trigger ever falls back to
// an empty notification.
TestCase {
  name: "Speech"

  readonly property var eventKeys: ["evolve_baby", "evolve_child", "evolve_teen_neat",
    "evolve_teen_scruffy", "evolve_adult", "rebirth", "line_selected", "transformation",
    "hard_landing", "need_hunger", "need_dirt", "need_tired", "need_bored", "need_lonely"]

  function test_every_line_defines_every_event_key() {
    var ids = Lines.ids()
    for (var i = 0; i < ids.length; i++) {
      for (var k = 0; k < eventKeys.length; k++) {
        var s = Lines.speak(ids[i], eventKeys[k], { name: "Test" })
        verify(typeof s === "string" && s.length > 0,
               ids[i] + "." + eventKeys[k] + " missing")
        verify(s.length <= 140, ids[i] + "." + eventKeys[k] + " too long for a toast")
      }
    }
  }

  function test_moon_copy_exists_exactly_for_oozaru_lines() {
    var ids = Lines.ids()
    for (var i = 0; i < ids.length; i++) {
      var rise = Lines.speak(ids[i], "moonrise", {})
      var dawn = Lines.speak(ids[i], "dawn", {})
      if (Lines.isOozaruLine(ids[i])) {
        verify(typeof rise === "string" && rise.length > 0, ids[i] + " moonrise")
        verify(typeof dawn === "string" && dawn.length > 0, ids[i] + " dawn")
      } else {
        compare(rise, null, ids[i] + " has no moon night")
        compare(dawn, null, ids[i] + " has no moon night")
      }
    }
  }

  function test_chatter_is_a_bag_of_distinct_lines() {
    var ids = Lines.ids()
    for (var i = 0; i < ids.length; i++) {
      var bag = Lines.chatterLines(ids[i])
      verify(Array.isArray(bag) && bag.length >= 4, ids[i] + " needs a real bag")
      var seen = {}
      for (var j = 0; j < bag.length; j++) {
        verify(typeof bag[j] === "string" && bag[j].length > 0)
        verify(bag[j].length <= 140, ids[i] + " chatter " + j + " too long")
        verify(!(bag[j] in seen), ids[i] + " repeats a chatter line")
        seen[bag[j]] = true
      }
    }
  }

  function test_placeholders_are_substituted() {
    var s = Lines.speak("goku", "evolve_baby", { name: "Goten" })
    verify(s.indexOf("{") < 0, "no raw placeholder may reach a toast: " + s)
  }

  function test_the_lines_do_not_share_voices() {
    // Spot check the personality boundary: the same event reads differently per line.
    var seen = {}
    var ids = Lines.ids()
    for (var i = 0; i < ids.length; i++) {
      var s = Lines.speak(ids[i], "need_hunger", { name: "X" })
      verify(!(s in seen), "two lines share a hunger line: " + s)
      seen[s] = true
    }
  }

  function test_an_unknown_key_is_null_not_a_crash() {
    compare(Lines.speak("goku", "no_such_event", {}), null)
    compare(Lines.speak("goku", "moonrise", {}) !== null, true)
    compare(Lines.speak("nonsense_line", "evolve_baby", { name: "X" }) !== null, true,
            "unknown lines fall back to the default line's voice")
  }
}
