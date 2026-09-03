import QtQuick
import QtTest
import "../notifybudget.js" as Nb

// Two pure layers: source reducers that own latches and see raw values, and a budget that
// owns the cap and never sees a measurement. Every rule here is a rule about not
// irritating the one person who can uninstall the pet.
TestCase {
  name: "NotifyBudget"

  readonly property real t0: 1788220800000
  function rand0() { return 0 }
  function fresh() { return Nb.emptyState() }
  function event(source) { return { source: source, cls: "event" } }
  function chatter() { return { source: "chatter", cls: "chatter" } }

  // --- the budget -------------------------------------------------------------

  function test_an_exempt_candidate_always_sends() {
    var st = fresh()
    // Three, not four: wave 2 reserves the fourth slot for care traffic.
    for (var i = 0; i < 3; i++) {
      var r = Nb.decide(st, event("evolution"), t0 + i * 200000, rand0)
      st = r.state
      compare(r.send, true, "fill " + i)
    }
    var r2 = Nb.decide(st, { source: "saveCorruption", cls: "exempt" },
                       t0 + 900000, rand0)
    compare(r2.send, true, "save corruption bypasses the cap")
  }

  function test_the_rolling_cap_is_4_per_hour_and_rolls() {
    var st = fresh()
    var sent = 0
    for (var i = 0; i < 6; i++) {
      var r = Nb.decide(st, event("evolution"), t0 + i * 200000, rand0)
      st = r.state
      if (r.send) sent++
    }
    compare(sent, 3, "non-care traffic stops at 3 of 4; the last slot is care's")
    var r2 = Nb.decide(st, event("evolution"), t0 + 3600001, rand0)
    compare(r2.send, true, "an hour after the first send there is room again")
  }

  function test_the_minimum_interval_spaces_ordinary_events() {
    var st = fresh()
    var r1 = Nb.decide(st, event("over9000"), t0, rand0); st = r1.state
    compare(r1.send, true)
    var r2 = Nb.decide(st, event("disk"), t0 + 60000, rand0); st = r2.state
    compare(r2.send, false)
    compare(r2.reason, "spacing")
    var r3 = Nb.decide(st, event("disk"), t0 + 121000, rand0)
    compare(r3.send, true)
  }

  function test_lifecycle_skips_spacing_but_counts_toward_the_cap() {
    var st = fresh()
    var r1 = Nb.decide(st, event("rebirth"), t0, rand0); st = r1.state
    var r2 = Nb.decide(st, event("lineSelection"), t0 + 5000, rand0); st = r2.state
    compare(r2.send, true, "rebirth then signature-locked is a legitimate sequence")
    var r3 = Nb.decide(st, event("evolution"), t0 + 10000, rand0); st = r3.state
    compare(r3.send, true)
    var r4 = Nb.decide(st, event("evolution"), t0 + 15000, rand0)
    compare(r4.send, false, "lifecycle still counts toward the non-care cap")
    compare(r4.reason, "cap")
  }

  function test_per_source_cooldowns_hold_independent_of_latches() {
    var st = fresh()
    var r1 = Nb.decide(st, event("over9000"), t0, rand0); st = r1.state
    compare(r1.send, true)
    var r2 = Nb.decide(st, event("over9000"), t0 + 2 * 3600000, rand0); st = r2.state
    compare(r2.send, false, "over-9000 cools down for 6 h")
    compare(r2.reason, "cooldown")
    var r3 = Nb.decide(st, event("over9000"), t0 + 6 * 3600000 + 1000, rand0)
    compare(r3.send, true)
  }

  function test_chatter_is_subordinate_to_events() {
    var st = Nb.primeChatter(fresh(), t0 - 7200000, rand0)
    var r1 = Nb.decide(st, event("disk"), t0, rand0); st = r1.state
    var r2 = Nb.decide(st, event("transformation"), t0 + 121000, rand0); st = r2.state
    compare(r2.send, true)
    var r3 = Nb.decide(st, chatter(), t0 + 300000, rand0)
    compare(r3.send, false, "two sends in the window: chatter yields")
    compare(r3.reason, "subordinate")
  }

  function test_chatter_draws_a_randomized_next_eligibility() {
    var st = Nb.primeChatter(fresh(), t0 - 7200000, rand0)
    var r = Nb.decide(st, chatter(), t0, rand0)
    compare(r.send, true)
    st = r.state
    var r2 = Nb.decide(st, chatter(), t0 + 3599999, rand0)
    compare(r2.send, false, "rand=0 still means at least 60 minutes")
    var r3 = Nb.decide(st, chatter(), t0 + 3600001, rand0)
    compare(r3.send, true)
  }

  function test_cold_start_priming_delays_the_first_chatter() {
    var st = Nb.primeChatter(fresh(), t0, function() { return 1 })
    var r = Nb.decide(st, chatter(), t0 + 3600000, rand0)
    compare(r.send, false, "rand=1 draws the full 180 minutes")
    var r2 = Nb.decide(st, chatter(), t0 + 180 * 60000 + 1, rand0)
    compare(r2.send, true)
  }

  // --- persistence ------------------------------------------------------------

  function test_state_round_trips_through_json() {
    var st = fresh()
    var r1 = Nb.decide(st, event("over9000"), t0, rand0); st = r1.state
    var loaded = Nb.loadState(JSON.stringify(st), t0 + 1000)
    var r2 = Nb.decide(loaded, event("over9000"), t0 + 2 * 3600000, rand0)
    compare(r2.send, false, "the 6 h cooldown survives a restart")
  }

  function test_old_entries_prune_but_do_not_cold_start() {
    var st = fresh()
    var r1 = Nb.decide(st, event("over9000"), t0, rand0); st = r1.state
    // Five quiet hours later. Old is NORMAL, not corruption.
    var loaded = Nb.loadState(JSON.stringify(st), t0 + 5 * 3600000)
    compare(loaded.lastSent.over9000, t0, "a quiet period must not wipe valid state")
    var r2 = Nb.decide(loaded, event("over9000"), t0 + 5 * 3600000, rand0)
    compare(r2.send, false, "still inside the 6 h cooldown after a quiet restart")
  }

  function test_future_fields_are_rejected_individually() {
    var st = fresh()
    var r1 = Nb.decide(st, event("disk"), t0, rand0); st = r1.state
    st.lastSent.over9000 = t0 + 9e12
    var loaded = Nb.loadState(JSON.stringify(st), t0 + 1000)
    var r2 = Nb.decide(loaded, event("over9000"), t0 + 200000, rand0)
    compare(r2.send, true, "the poisoned field cold-starts")
    compare(loaded.lastSent.disk, t0, "the valid field beside it was preserved")
  }

  function test_garbage_state_cold_starts_a_working_pipeline() {
    var loaded = Nb.loadState("{not json", t0)
    var r = Nb.decide(loaded, event("evolution"), t0, rand0)
    compare(r.send, true)
  }

  // --- reducers ---------------------------------------------------------------

  function test_latch_fires_on_upward_crossing_only() {
    var r = Nb.latchCross(null, 5000, 9000, 8000)
    compare(r.fire, false, "priming below the threshold never fires")
    r = Nb.latchCross(r.state, 9001, 9000, 8000)
    compare(r.fire, true)
    r = Nb.latchCross(r.state, 9500, 9000, 8000)
    compare(r.fire, false, "still latched")
  }

  function test_cold_start_above_the_threshold_never_fires() {
    var r = Nb.latchCross(null, 12000, 9000, 8000)
    compare(r.fire, false)
    var r2 = Nb.latchCross(r.state, 12500, 9000, 8000)
    compare(r2.fire, false, "primed above: quiet until a real re-arm")
  }

  function test_rearm_needs_the_low_band() {
    var rs = Nb.latchCross(null, 5000, 9000, 8000).state
    rs = Nb.latchCross(rs, 9001, 9000, 8000).state
    rs = Nb.latchCross(rs, 8500, 9000, 8000).state
    var r = Nb.latchCross(rs, 9200, 9000, 8000)
    compare(r.fire, false, "8500 did not re-arm")
    rs = Nb.latchCross(rs, 7999, 9000, 8000).state
    var r2 = Nb.latchCross(rs, 9200, 9000, 8000)
    compare(r2.fire, true, "re-armed below 8000")
  }

  function test_full_band_oscillation_fires_the_latch_repeatedly() {
    // The latch alone cannot stop a full-band swing (7999/9001 alternating): each swing is
    // a legitimate crossing. This is exactly why over-9000 carries a 6 h budget cooldown.
    var rs = Nb.latchCross(null, 7999, 9000, 8000).state
    var fires = 0
    for (var i = 0; i < 20; i++) {
      var r = Nb.latchCross(rs, (i % 2 === 0) ? 9001 : 7999, 9000, 8000)
      rs = r.state
      if (r.fire) fires++
    }
    verify(fires >= 9, "saw " + fires + " fires")
  }

  function test_unknown_preserves_the_latch() {
    var rs = Nb.latchCross(null, 5000, 9000, 8000).state
    rs = Nb.latchCross(rs, 9001, 9000, 8000).state
    var r = Nb.latchCross(rs, null, 9000, 8000)
    compare(r.fire, false)
    var r2 = Nb.latchCross(r.state, 9500, 9000, 8000)
    compare(r2.fire, false, "an outage that recovers high must not re-fire")
  }

  function test_count_latch_fires_on_zero_to_some() {
    var r = Nb.countLatch(null, 0)
    compare(r.fire, false)
    r = Nb.countLatch(r.state, 2)
    compare(r.fire, true)
    r = Nb.countLatch(r.state, 3)
    compare(r.fire, false, "more damage while latched stays quiet")
    r = Nb.countLatch(r.state, 0)
    r = Nb.countLatch(r.state, 1)
    compare(r.fire, true, "re-armed at zero")
  }

  function test_count_latch_primes_on_first_sample() {
    var r = Nb.countLatch(null, 5)
    compare(r.fire, false, "a cold start with damage present stays quiet")
  }

  function test_rung_rise_needs_60s_of_stability() {
    var r = Nb.rungRise(null, 0, true, t0)
    compare(r.fire, false)
    r = Nb.rungRise(r.state, 2, true, t0 + 5000)
    compare(r.fire, false)
    r = Nb.rungRise(r.state, 2, true, t0 + 30000)
    compare(r.fire, false, "not stable yet")
    r = Nb.rungRise(r.state, 2, true, t0 + 66000)
    compare(r.fire, true)
    r = Nb.rungRise(r.state, 2, true, t0 + 120000)
    compare(r.fire, false, "no re-fire while held")
  }

  function test_a_dip_resets_the_pending_rise() {
    var rs = Nb.rungRise(null, 0, true, t0).state
    rs = Nb.rungRise(rs, 2, true, t0 + 5000).state
    rs = Nb.rungRise(rs, 0, true, t0 + 30000).state
    var r = Nb.rungRise(rs, 2, true, t0 + 70000)
    compare(r.fire, false, "the 60 s clock restarted at the dip")
  }

  function test_recovery_from_unknown_primes_silently() {
    var rs = Nb.rungRise(null, 0, true, t0).state
    rs = Nb.rungRise(rs, 0, false, t0 + 5000).state
    var r = Nb.rungRise(rs, 3, true, t0 + 10000)
    compare(r.fire, false, "recovery is priming, not a transformation")
    var r2 = Nb.rungRise(r.state, 3, true, t0 + 80000)
    compare(r2.fire, false, "the recovered rung is the new stable")
  }

  function test_bool_edge_reports_rise_and_fall_once() {
    var r = Nb.boolEdge(null, false)
    compare(r.rose, false)
    r = Nb.boolEdge(r.state, true)
    compare(r.rose, true)
    r = Nb.boolEdge(r.state, true)
    compare(r.rose, false)
    r = Nb.boolEdge(r.state, false)
    compare(r.fell, true)
  }

  function test_bool_edge_primes_without_firing() {
    var r = Nb.boolEdge(null, true)
    compare(r.rose, false, "restarting mid-moon-night must not re-announce the moon")
  }

  function test_shuffle_bag_exhausts_before_repeating() {
    var bag = null
    var seen = {}
    var rand = function() { return 0.5 }
    for (var i = 0; i < 4; i++) {
      var r = Nb.bagDraw(bag, 4, rand)
      bag = r.state
      seen[r.index] = true
    }
    var count = 0
    for (var k in seen) count++
    compare(count, 4, "all four lines drawn before any repeat")
  }

  // --- wave 2: the care class, typed send history, and the reserved slot ---

  function care(source) { return { source: source || "needCritical", cls: "care" } }
  function ambient(source) { return { source: source || "fleetSurge", cls: "ambient" } }

  // Reserving a slot for any non-ambient event was not enough: an over-9000 alert would
  // take it and still block a need crossing. Care gets its own class and its own slot.
  function test_non_care_traffic_can_never_fill_the_last_slot() {
    var st = fresh()
    var sent = 0
    for (var i = 0; i < 6; i++) {
      var r = Nb.decide(st, ambient(), t0 + i * 700000, rand0)
      st = r.state
      if (r.send) sent++
    }
    compare(sent, 3, "ambient may occupy at most 3 of 4")
    var r2 = Nb.decide(st, care(), t0 + 5 * 700000 + 1000, rand0)
    compare(r2.send, true, "the reserved slot is still there for care")
  }

  function test_event_traffic_also_stops_at_three() {
    var st = fresh()
    var sent = 0
    for (var i = 0; i < 5; i++) {
      // A source with no per-source cooldown, so the cap is what is under test.
      var r = Nb.decide(st, event("disk"), t0 + i * 700000, rand0)
      st = r.state
      if (r.send) sent++
    }
    compare(sent, 3, "non-care means event AND ambient together")
    compare(Nb.decide(st, care(), t0 + 4 * 700000 + 1000, rand0).send, true)
  }

  function test_spacing_yields_to_care_but_not_to_event() {
    var st = fresh()
    var r1 = Nb.decide(st, ambient(), t0, rand0); st = r1.state
    compare(r1.send, true)
    compare(Nb.decide(st, event("disk"), t0 + 30000, rand0).send, false,
            "an ordinary event still waits its 120s")
    compare(Nb.decide(st, care(), t0 + 30000, rand0).send, true,
            "care does not wait behind ambient chatter")
  }

  // Checking only "was the most recent send non-care" would let a spacing-exempt lifecycle
  // event slip between two care sends and hand the second a free pass.
  function test_care_still_spaces_against_care() {
    var st = fresh()
    var r1 = Nb.decide(st, care(), t0, rand0); st = r1.state
    var r2 = Nb.decide(st, event("rebirth"), t0 + 5000, rand0); st = r2.state
    compare(r2.send, true, "lifecycle is spacing-exempt")
    var r3 = Nb.decide(st, care(), t0 + 10000, rand0)
    compare(r3.send, false, "a care send 10s ago still spaces the next one")
    compare(Nb.decide(st, care(), t0 + 121000, rand0).send, true)
  }

  // --- typed history and wave-1 migration ---

  function test_a_wave_1_numeric_history_migrates_to_event() {
    var legacy = JSON.stringify({ version: 1, sends: [t0 - 1000],
                                  lastSent: {}, reducers: {}, chatter: {} })
    var st = Nb.loadState(legacy, t0)
    compare(st.sends.length, 1, "the send really happened; do not discard it")
    compare(st.sends[0].cls, "event")
  }

  // A wave-1 file can hold FOUR untyped sends, which fills the cap. Dropping one would
  // undercount real notifications, so they are preserved and the reservation binds later.
  function test_a_full_legacy_window_is_preserved_losslessly() {
    var legacy = JSON.stringify({ version: 1, lastSent: {}, reducers: {}, chatter: {},
      sends: [t0 - 4000, t0 - 3000, t0 - 2000, t0 - 1000] })
    var st = Nb.loadState(legacy, t0)
    compare(st.sends.length, 4, "all four preserved")
    compare(Nb.decide(st, care(), t0, rand0).send, false, "the cap still binds")
    // Once they age out, the reservation protects care again.
    compare(Nb.decide(st, care(), t0 + 3600001, rand0).send, true)
  }

  function test_malformed_typed_entries_are_dropped_not_trusted() {
    var bad = JSON.stringify({ version: 1, lastSent: {}, reducers: {}, chatter: {},
      sends: [{ t: t0 - 1000, cls: "care" }, { t: "soon", cls: "care" },
              { cls: "care" }, null, { t: t0 - 500 }] })
    var st = Nb.loadState(bad, t0)
    compare(st.sends.length, 2, "only the two with a valid time survive")
  }

  function test_an_unknown_class_is_demoted_to_ambient() {
    var sneaky = JSON.stringify({ version: 1, lastSent: {}, reducers: {}, chatter: {},
      sends: [{ t: t0 - 1000, cls: "superimportant" }] })
    var st = Nb.loadState(sneaky, t0)
    compare(st.sends[0].cls, "ambient",
            "a corrupt file must never manufacture care priority")
  }

  function test_exempt_still_bypasses_everything_with_typed_history() {
    var st = fresh()
    for (var i = 0; i < 4; i++) st = Nb.decide(st, care(), t0 + i * 200000, rand0).state
    compare(Nb.decide(st, { source: "saveCorruption", cls: "exempt" },
                      t0 + 900000, rand0).send, true)
  }
}
