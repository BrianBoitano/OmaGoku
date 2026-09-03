import QtQuick
import QtTest
import "../rival.js" as Rival

// A second entity on the floor. It must arrive slowly, leave INSTANTLY when the evidence
// for it goes away, and never survive a farewell.
TestCase {
  name: "Rival"

  function fresh() { return Rival.emptyState() }
  // Hold `encounter` for ms of simulated time in 40ms ticks (the real physics interval).
  function hold(st, encounter, ms, petX) {
    for (var t = 0; t < ms; t += 40)
      st = Rival.next(st, petX === undefined ? 500 : petX, 40, encounter, false)
    return st
  }

  function test_entry_needs_sixty_contiguous_seconds() {
    var st = hold(fresh(), true, 59000)
    compare(st.phase, "none", "59s is not enough")
    st = hold(st, true, 2000)
    compare(st.phase, "entering")
  }

  // A bare phase string plus elapsedMs cannot express "contiguously true"; the timer must
  // live in the returned state or a flicker keeps the entry clock running.
  function test_a_flicker_resets_the_entry_clock() {
    var st = hold(fresh(), true, 50000)
    st = Rival.next(st, 500, 40, false, false)
    compare(st.encounterTrueMs, 0, "one false observation resets it")
    st = hold(st, true, 50000)
    compare(st.phase, "none", "the clock restarted, so 50s more is still not entry")
  }

  function test_exit_is_immediate_on_measured_false() {
    var st = hold(fresh(), true, 61000)
    compare(st.phase, "entering")
    st = Rival.next(st, 500, 40, false, false)
    compare(st.phase, "leaving", "no exit dwell: a lingering rival asserts a dead reading")
  }

  function test_exit_is_immediate_on_unknown() {
    var st = hold(fresh(), true, 61000)
    st = Rival.next(st, 500, 40, "unknown", false)
    compare(st.phase, "leaving", "a stale feed is not evidence of an opponent")
  }

  function test_abort_vanishes_instantly_from_any_phase() {
    var phases = ["entering", "facing", "leaving"]
    for (var i = 0; i < phases.length; i++) {
      var st = hold(fresh(), true, 61000)
      st.phase = phases[i]
      var gone = Rival.next(st, 500, 40, true, true)
      compare(gone.phase, "none", phases[i] + " must vanish on abort")
      compare(gone.encounterTrueMs, 0, phases[i] + " must not keep its clock")
    }
  }

  function test_entering_walks_toward_the_pet_and_settles_into_facing() {
    var st = hold(fresh(), true, 61000)
    var startX = st.rivalX
    st = Rival.next(st, 500, 40, true, false)
    verify(st.rivalX !== startX, "it moves")
    st = hold(st, true, 30000)
    compare(st.phase, "facing", "it stops a few tiles off and stares")
  }

  function test_the_state_field_set_is_pinned() {
    var want = Rival.STATE_KEYS.slice().sort().join(",")
    function keysOf(o) { var k = []; for (var n in o) k.push(n); return k.sort().join(",") }
    compare(keysOf(fresh()), want)
    compare(keysOf(hold(fresh(), true, 61000)), want)
  }

  // --- identity, pinned so it cannot be invented at implementation time ---

  function test_the_rival_line_is_deterministic_and_never_the_local_one() {
    var order = ["goku", "vegeta", "piccolo", "krillin", "frieza"]
    for (var i = 0; i < order.length; i++) {
      var r = Rival.lineFor(order[i])
      verify(r !== order[i], order[i] + " must not face itself")
      compare(r, Rival.lineFor(order[i]), "stable across calls")
      verify(order.indexOf(r) >= 0, "and a real line")
    }
  }

  function test_an_unknown_local_line_means_no_rival() {
    compare(Rival.lineFor("nonsense"), null)
    compare(Rival.lineFor(""), null)
  }

  // pod_walk_* and baby_walk_* do not exist, so a young rival would slide standing up.
  function test_the_rival_form_is_child_or_older_only() {
    compare(Rival.formFor("egg"), null)
    compare(Rival.formFor("baby"), null)
    compare(Rival.formFor("child"), "child")
    compare(Rival.formFor("teen"), "teen_neat")
    compare(Rival.formFor("adult"), "adult_ok")
  }
}
