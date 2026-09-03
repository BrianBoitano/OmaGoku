import QtQuick
import QtTest
import "../moves.js" as Moves
import "../lines.js" as Lines

// The signature move sets. Availability is DERIVED from level and line and nothing else --
// the persisted announcement ledger is a toast record, not an authority, because persisted
// derived state used as authority is the defect class this project has already shipped.
TestCase {
  name: "Moves"

  function test_every_line_has_exactly_three_moves_at_the_pinned_levels() {
    var ids = Lines.ids()
    for (var i = 0; i < ids.length; i++) {
      var set = Moves.forLine(ids[i])
      compare(set.length, 3, ids[i] + " must have three moves")
      compare(set[0].level, 12)
      compare(set[1].level, 30)
      compare(set[2].level, 60)
    }
    compare(Moves.ids().length, 15)
  }

  function test_every_move_belongs_to_a_real_line_and_a_known_geometry() {
    var all = Moves.ids()
    var seen = {}
    for (var i = 0; i < all.length; i++) {
      var m = Moves.byId(all[i])
      verify(Lines.has(m.line), m.id + " has line " + m.line)
      verify(Moves.GEOMETRY[m.geometry] !== undefined, m.id + " geometry " + m.geometry)
      verify(seen[m.id] === undefined, "duplicate id " + m.id)
      seen[m.id] = true
    }
  }

  // Per-line colour is a RUNTIME tint: gen-sprites.py applies a line palette only to PET
  // grids, so every decor_* asset is generated once with the global palette.
  function test_every_line_defines_a_move_colour() {
    var ids = Lines.ids()
    for (var i = 0; i < ids.length; i++)
      verify(/^#[0-9A-Fa-f]{6}$/.test(Lines.moveColor(ids[i])),
             ids[i] + " needs a moveColor, got " + Lines.moveColor(ids[i]))
  }

  function test_availability_is_derived_from_level_and_line_alone() {
    compare(Moves.available("goku", 1).length, 0)
    compare(Moves.available("goku", 11).length, 0)
    compare(Moves.available("goku", 12).length, 1)
    compare(Moves.available("goku", 29).length, 1)
    compare(Moves.available("goku", 30).length, 2)
    compare(Moves.available("goku", 60).length, 3)
    compare(Moves.available("goku", 100).length, 3)
    compare(Moves.available("trunks", 100).length, 0, "an unknown line has no moves")
  }

  function test_a_line_can_never_fire_another_lines_move() {
    verify(Moves.isAvailable("goku", 100, "kamehameha"))
    verify(!Moves.isAvailable("goku", 100, "galick_gun"))
    verify(!Moves.isAvailable("vegeta", 100, "kamehameha"))
    verify(!Moves.isAvailable("goku", 11, "kamehameha"), "level still binds")
    verify(!Moves.isAvailable("goku", 100, "not_a_move"))
  }

  // One rule, named once: the ambient trigger and the over-9000 trigger both use it.
  function test_the_pet_shows_off_its_best() {
    compare(Moves.best("goku", 12).id, "kamehameha")
    compare(Moves.best("goku", 30).id, "spirit_bomb")
    compare(Moves.best("goku", 100).id, "kaioken")
    compare(Moves.best("goku", 5), null)
  }

  // aura and flash are stationary by nature; the generic "travel to the screen edge" rule
  // would have slid a Kaioken aura off the monitor.
  function test_stationary_geometries_never_leave_the_pet() {
    verify(!Moves.GEOMETRY.aura.travels)
    verify(!Moves.GEOMETRY.flash.travels)
    verify(Moves.GEOMETRY.beam.travels)
    verify(Moves.GEOMETRY.orb.travels)
    verify(Moves.GEOMETRY.ring.travels)
  }

  function test_the_timeline_is_absolute_and_per_class() {
    var beam = Moves.timeline("beam", false)
    compare(beam.charge, 800)
    compare(beam.total, 2600)
    compare(Moves.timeline("fine_line", false).total, 1800)
    compare(Moves.timeline("flash", false).total, 900)
    // The aura's admission and its lifetime must be ONE number.
    compare(Moves.timeline("aura", false).total, Moves.GEOMETRY.aura.lifetime)
    compare(Moves.timeline("beam", false).total, Moves.GEOMETRY.beam.lifetime)
  }

  function test_reduced_motion_is_a_static_hold_with_no_animation() {
    var geoms = Object.keys(Moves.GEOMETRY)
    for (var i = 0; i < geoms.length; i++) {
      var t = Moves.timeline(geoms[i], true)
      compare(t.total, Moves.MOVE_STATIC_MS, geoms[i] + " holds then hides")
      compare(t.charge, 0, geoms[i] + " does not animate a charge")
      compare(t.fade, 0, geoms[i] + " does not fade")
    }
  }

  // "Not animated" is not the same as "safe": a stationary 2.5x flash at opacity 0.9
  // appearing instantly is most of what a reduced-motion setting is asking to be spared.
  function test_flash_and_aura_are_substituted_under_reduced_motion() {
    verify(Moves.reducedForm("flash").substitute)
    verify(Moves.reducedForm("aura").substitute)
    verify(!Moves.reducedForm("beam").substitute)
    compare(Moves.reducedForm("flash").opacity, 0.5)
  }
}
