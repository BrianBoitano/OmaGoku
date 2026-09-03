import QtQuick
import QtTest
import "../behaviour.js" as Behaviour

// Per-line signature behaviours. The dwell rules exist so a behaviour cannot thrash the
// sprite's animation restart, and the priority rule exists so a meditating Piccolo can
// never hide a starving pet.
TestCase {
  name: "Behaviour"

  function hold(st, predicate, busy, ms) {
    for (var t = 0; t < ms; t += 1000)
      st = Behaviour.next(st, predicate, busy, 1000)
    return st
  }

  function test_activation_needs_five_seconds() {
    var st = hold(Behaviour.emptyState(), true, false, 4000)
    compare(st.active, false)
    st = hold(st, true, false, 2000)
    compare(st.active, true)
  }

  function test_a_minimum_dwell_prevents_animation_thrash() {
    var st = hold(Behaviour.emptyState(), true, false, 6000)
    compare(st.active, true)
    // Predicate drops immediately; the behaviour still holds its 20s floor.
    st = hold(st, false, false, 6000)
    compare(st.active, true, "inside the 20s minimum dwell")
    st = hold(st, false, false, 20000)
    compare(st.active, false)
  }

  function test_exit_needs_the_predicate_false_for_five_seconds() {
    var st = hold(Behaviour.emptyState(), true, false, 30000)
    compare(st.active, true)
    st = hold(st, false, false, 4000)
    compare(st.active, true, "a brief dip does not end it")
    st = hold(st, true, false, 1000)
    st = hold(st, false, false, 4000)
    compare(st.active, true, "the exit clock restarted")
  }

  // A real need, a care animation or leaving idle cancels with NO dwell at all.
  function test_a_higher_priority_state_cancels_immediately() {
    var st = hold(Behaviour.emptyState(), true, false, 30000)
    compare(st.active, true)
    st = Behaviour.next(st, true, true, 40)
    compare(st.active, false, "no dwell survives a real need")
  }

  function test_it_cannot_activate_while_busy() {
    var st = hold(Behaviour.emptyState(), true, true, 60000)
    compare(st.active, false)
  }

  function test_the_state_field_set_is_pinned() {
    var want = Behaviour.STATE_KEYS.slice().sort().join(",")
    function keysOf(o) { var k = []; for (var n in o) k.push(n); return k.sort().join(",") }
    compare(keysOf(Behaviour.emptyState()), want)
    compare(keysOf(hold(Behaviour.emptyState(), true, false, 30000)), want)
  }

  // --- the per-line predicates ---

  // Vegeta is furious about being CAPPED: raw ki above the care-capped rung. It reads the
  // machine truth, so a full-moon night can neither fake it nor mask it.
  function test_vegeta_is_furious_only_when_care_caps_him() {
    compare(Behaviour.vegetaFurious(3, 1), true)
    compare(Behaviour.vegetaFurious(1, 1), false)
    compare(Behaviour.vegetaFurious(0, 0), false)
  }

  function test_piccolo_meditates_only_when_idle_and_not_fullscreen() {
    compare(Behaviour.piccoloMeditates(true, false), true)
    compare(Behaviour.piccoloMeditates(false, false), false)
    compare(Behaviour.piccoloMeditates(true, true), false,
            "respectInhibitors does not guarantee a player takes an inhibitor")
  }

  function test_frieza_complains_about_measured_filth_only() {
    compare(Behaviour.friezaComplains(91, 0), true)
    compare(Behaviour.friezaComplains(50, 5), true)
    compare(Behaviour.friezaComplains(50, 0), false)
    compare(Behaviour.friezaComplains(null, null), false, "unknown is not dirty")
  }

  function test_krillin_is_nervous_only_while_the_rival_is_present() {
    compare(Behaviour.krillinNervous("facing"), true)
    compare(Behaviour.krillinNervous("entering"), true)
    compare(Behaviour.krillinNervous("none"), false)
  }
}
