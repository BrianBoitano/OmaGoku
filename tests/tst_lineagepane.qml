import QtQuick
import QtTest
import "../lineagepane.js" as Pane

// The pane's arithmetic. Its whole job is to never claim to know something it does not:
// a record with holes must not render a figure that looks exact.
TestCase {
  name: "LineagePane"

  function live(over) {
    var e = { progressMode: "live", petId: "0123456789abcdef0123456789abcdef",
              gen: 1, line: "goku", endedBy: "farewell", stage: "adult", form: "adult_ace",
              bornAt: 1700000000000, endedAt: 1700009000000,
              curve: 1, xp: 1000, peakKiRung: 1, ballsCollected: 3, wishesGranted: 1,
              careAverage: 60 }
    for (var k in over) e[k] = over[k]
    return e
  }

  function frozen(over) {
    var e = { progressMode: "frozen", petId: "0123456789abcdef0123456789abcdef",
              gen: 2, line: "goku", endedBy: "farewell", stage: "adult", form: "adult_ace",
              bornAt: null, endedAt: null }
    for (var k in over) e[k] = over[k]
    return e
  }

  function st(entries, over) {
    var s = { mode: "valid", record: { v: 1, entries: entries },
              unreadableRows: 0, droppedByCap: 0 }
    for (var k in over) s[k] = over[k]
    return s
  }

  // --- completeness ----------------------------------------------------------

  function test_a_whole_record_reports_every_metric_as_complete() {
    var a = Pane.aggregate(st([live({}), live({ ballsCollected: 5 })]))
    compare(a.balls.value, 8)
    compare(a.balls.complete, true)
    compare(a.care.complete, true)
    compare(a.peak.complete, true)
  }

  // A frozen row carries no numbers at all, so every metric it should have contributed to
  // becomes partial -- and the sums become lower bounds rather than totals.
  function test_a_frozen_row_makes_the_sums_bounds() {
    var a = Pane.aggregate(st([live({}), frozen({})]))
    compare(a.balls.value, 3, "the readable row still counts")
    compare(a.balls.complete, false)
    compare(a.balls.contributors, 1)
    compare(a.retained, 2)
  }

  // A live row that was never sampled contributes nothing to the mean, and revision 6's
  // single excluded-flag missed exactly this: it is not frozen, not corrupt, not
  // unreadable, and still unknown.
  function test_a_never_sampled_row_makes_only_CARE_partial() {
    var a = Pane.aggregate(st([live({}), live({ careAverage: null })]))
    compare(a.care.contributors, 1)
    compare(a.care.complete, false, "care is missing a contributor")
    compare(a.balls.complete, true, "but the sums are not")
    compare(a.care.mean, 60, "and the mean is over the rows that HAVE a sample")
  }

  function test_care_with_no_samples_at_all_is_null_not_zero() {
    var a = Pane.aggregate(st([live({ careAverage: null })]))
    compare(a.care.mean, null, "never sampled is not a score of zero")
    compare(a.care.contributors, 0)
  }

  // Rows we could not read never became entries, so they cannot be seen in the array --
  // which is exactly why they have to be counted from the state.
  function test_unreadable_rows_make_every_metric_partial() {
    var a = Pane.aggregate(st([live({}), live({})], { unreadableRows: 2, mode: "partial" }))
    compare(a.unreadable, 2)
    compare(a.balls.complete, false)
    compare(a.care.complete, false)
    compare(a.retained, 2, "retained counts READABLE generations only, never the junk")
  }

  function test_rows_dropped_by_the_cap_also_make_it_partial() {
    var a = Pane.aggregate(st([live({})], { droppedByCap: 7 }))
    compare(a.droppedByCap, 7)
    compare(a.balls.complete, false)
  }

  // --- the peak --------------------------------------------------------------

  function test_the_peak_carries_the_winning_rows_own_label() {
    var a = Pane.aggregate(st([live({ peakKiRung: 3, line: "piccolo", gen: 7 }),
                               live({ peakKiRung: 1 })]))
    compare(a.peak.best.tier, 3)
    compare(a.peak.best.gen, 7)
    compare(a.peak.best.label, "Orange Piccolo",
            "tier 3 means something different on every line")
  }

  function test_a_tie_goes_to_the_most_recent() {
    var a = Pane.aggregate(st([live({ peakKiRung: 2, gen: 4 }),
                               live({ peakKiRung: 2, gen: 9 })]))
    compare(a.peak.best.gen, 9)
  }

  function test_no_readable_row_means_no_peak() {
    var a = Pane.aggregate(st([frozen({})]))
    compare(a.peak.best, null)
    compare(a.peak.contributors, 0)
  }

  // --- per-row facts ---------------------------------------------------------

  function test_lifespan_needs_both_stamps_and_a_forward_clock() {
    compare(Pane.lifespanMinutes(live({})), 150)
    compare(Pane.lifespanMinutes(live({ bornAt: null })), null, "not recorded")
    compare(Pane.lifespanMinutes(live({ endedAt: null })), null)
    compare(Pane.lifespanMinutes(live({ endedAt: 1699999999000 })), null,
            "a clock rollback is not a negative lifetime")
    compare(Pane.lifespanMinutes(frozen({})), null)
  }

  function test_a_future_curve_shows_xp_and_no_level() {
    verify(Pane.levelOf(live({})) !== null)
    compare(Pane.levelOf(live({ curve: 2 })), null,
            "levelFor is built for one curve; another would render a confident wrong level")
    compare(Pane.levelOf(frozen({})), null)
  }

  // --- the row budget --------------------------------------------------------

  function test_the_row_count_is_computed_and_may_reach_zero() {
    // 1080 tall, 44 bar, inset 28, breathing 16, chrome 180, pitch 34
    compare(Pane.rowsThatFit(1000, 28, 16, 180, 34), 8, "capped at MAX_ROWS")
    compare(Pane.rowsThatFit(300, 28, 16, 180, 34), 2)
    compare(Pane.rowsThatFit(200, 28, 16, 180, 34), 0,
            "at a large enough scale the chrome alone fills the card")
    compare(Pane.rowsThatFit(120, 28, 16, 400, 34), 0, "never negative")
  }

  function test_a_nonsense_pitch_cannot_produce_a_row() {
    compare(Pane.rowsThatFit(1000, 28, 16, 180, 0), 0)
    compare(Pane.rowsThatFit(1000, 28, 16, 180, NaN), 0)
  }

  function test_visible_rows_are_the_most_recent() {
    var rows = [live({ gen: 1 }), live({ gen: 2 }), live({ gen: 3 })]
    var v = Pane.visibleRows(st(rows), 2)
    compare(v.length, 2)
    compare(v[0].gen, 2)
    compare(v[1].gen, 3)
    compare(Pane.visibleRows(st(rows), 0).length, 0)
  }

  // --- hostile ---------------------------------------------------------------

  function test_a_hostile_state_aggregates_to_nothing_rather_than_throwing() {
    var bad = [null, undefined, 5, {}, { record: 3 }, { record: { entries: "no" } }]
    for (var i = 0; i < bad.length; i++) {
      var a = Pane.aggregate(bad[i])
      compare(a.retained, 0, "hostile " + i)
      compare(a.care.mean, null, "hostile " + i)
    }
  }
}
