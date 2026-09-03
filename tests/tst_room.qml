import QtQuick
import QtTest
import "../room.js" as Room

// The room's furniture as ONE computed list. The panel's model used to be a static literal
// selected by one key, so a level unlock could only ever appear at every level or none.
TestCase {
  name: "Room"

  function names(list) {
    var out = []
    for (var i = 0; i < list.length; i++) out.push(list[i].name)
    return out
  }

  function test_stage_furniture_still_comes_first() {
    var d = Room.decor("adult_ok", "adult", 1, false)
    compare(names(d)[0], "tree_ok")
    verify(names(d).indexOf("boots") >= 0)
  }

  function test_the_form_beats_the_stage_and_the_stage_is_the_fallback() {
    compare(names(Room.decor("teen_neat", "teen", 1, false)), ["radar"])
    compare(names(Room.decor("pod", "egg", 1, false)), ["moon"])
    compare(Room.decor("nonsense_form", "nonsense_stage", 1, false).length, 0)
  }

  function test_nothing_unlocks_below_its_level() {
    compare(names(Room.decor("adult_ace", "adult", 24, false)), ["tree_ace"])
    compare(names(Room.decor("adult_ace", "adult", 25, false)),
            ["tree_ace", "trophy_korin"])
    compare(names(Room.decor("adult_ace", "adult", 49, false)),
            ["tree_ace", "trophy_korin"])
  }

  function test_unlocks_arrive_in_level_order_and_all_four_coexist() {
    var d = names(Room.decor("adult_ace", "adult", 100, false))
    compare(d, ["tree_ace", "trophy_korin", "trophy_kame",
                "trophy_lookout", "trophy_chamber"])
  }

  // The keepsake owns the top-left dragonballs slot. An unlock must never take it, and the
  // keepsake has no renderer yet, so Phase 1 reserves the position without drawing anything.
  function test_the_keepsake_slot_is_reserved_not_taken() {
    var withKeepsake = Room.decor("adult_ace", "adult", 100, true)
    var without = Room.decor("adult_ace", "adult", 100, false)
    compare(names(withKeepsake).length, names(without).length,
            "phase 1 draws no keepsake piece")
    var d = Room.decor("adult_ace", "adult", 100, true)
    for (var i = 0; i < d.length; i++)
      verify(!(d[i].x < 0.2 && d[i].y < 0.2),
             d[i].name + " is sitting in the reserved keepsake slot")
  }

  function test_unlocks_are_small_furniture_not_room_sized_scenery() {
    var d = Room.decor("adult_ace", "adult", 100, false)
    for (var i = 0; i < d.length; i++) {
      if (d[i].name.indexOf("trophy_") !== 0) continue
      compare(d[i].px, 2)
      compare(d[i].colorize, false)
      verify(d[i].sway === undefined && d[i].bounce === undefined && d[i].beam === undefined)
    }
  }

  function test_a_nonsense_level_is_treated_as_level_one() {
    compare(names(Room.decor("adult_ace", "adult", null, false)), ["tree_ace"])
    compare(names(Room.decor("adult_ace", "adult", "100", false)), ["tree_ace"])
    compare(names(Room.decor("adult_ace", "adult", NaN, false)), ["tree_ace"])
  }
}
