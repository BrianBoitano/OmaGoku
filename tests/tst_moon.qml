import QtQuick
import QtTest
import "../moon.js" as Moon

// Lunar phase from the pinned epoch and synodic constant. Every time is injected; the
// suite never reads the wall clock, so full-moon nights are reproducible on any day.
TestCase {
  name: "Moon"

  // The model's own constants: epoch new moon 2000-01-06T18:14Z, synodic 29.530588853 d.
  readonly property real epochMs: Date.UTC(2000, 0, 6, 18, 14, 0)
  readonly property real synodicMs: 29.530588853 * 86400000
  function fullInstant(k) { return epochMs + (k + 0.5) * synodicMs }

  function test_a_new_moon_is_not_in_the_full_window() {
    compare(Moon.isFullWindow(epochMs), false)
    compare(Moon.isFullWindow(epochMs + 100 * synodicMs), false)
  }

  function test_the_full_instant_is_in_the_window() {
    compare(Moon.isFullWindow(fullInstant(0)), true)
    compare(Moon.isFullWindow(fullInstant(325)), true)
  }

  function test_the_window_is_36_hours_each_side() {
    var f = fullInstant(325)
    compare(Moon.isFullWindow(f + 35 * 3600000), true)
    compare(Moon.isFullWindow(f - 35 * 3600000), true)
    compare(Moon.isFullWindow(f + 37 * 3600000), false)
    compare(Moon.isFullWindow(f - 37 * 3600000), false)
  }

  function test_night_is_20_to_06_local() {
    var nightHours = [20, 21, 23, 0, 2, 5]
    var dayHours = [6, 7, 12, 19]
    for (var i = 0; i < nightHours.length; i++)
      compare(Moon.isNight(nightHours[i]), true, "hour " + nightHours[i])
    for (var j = 0; j < dayHours.length; j++)
      compare(Moon.isNight(dayHours[j]), false, "hour " + dayHours[j])
  }

  function test_lunar_active_needs_both_full_and_night() {
    var f = fullInstant(325)
    compare(Moon.lunarActive(f, 23), true)
    compare(Moon.lunarActive(f, 12), false)
    compare(Moon.lunarActive(epochMs, 23), false)
  }

  // Dusk is its own predicate: isNight() is 20:00-06:00 and would have summoned Shenron at
  // four in the morning.
  function test_dusk_is_18_to_21_inclusive_lower_exclusive_upper() {
    var dusk = [18, 19, 20]
    var notDusk = [17, 21, 22, 0, 6, 12]
    for (var i = 0; i < dusk.length; i++)
      compare(Moon.isDusk(dusk[i]), true, "hour " + dusk[i])
    for (var j = 0; j < notDusk.length; j++)
      compare(Moon.isDusk(notDusk[j]), false, "hour " + notDusk[j])
  }

  // Night rest, 20:00 to 07:00 local. A SEPARATE predicate from isNight (20:00-06:00),
  // which drives the Oozaru window and must not move. The pet sleeps through these hours
  // and accrues nothing: leaving the machine on overnight used to return a fully depleted
  // pet, which is eleven hours of needs nobody was awake to meet.
  function test_rest_hours_are_20_to_07_local() {
    var resting = [20, 21, 23, 0, 3, 6]
    var awake = [7, 8, 12, 17, 19]
    for (var i = 0; i < resting.length; i++)
      compare(Moon.isRestHours(resting[i]), true, "hour " + resting[i])
    for (var j = 0; j < awake.length; j++)
      compare(Moon.isRestHours(awake[j]), false, "hour " + awake[j])
  }

  function test_rest_hours_are_not_the_oozaru_night() {
    // 06:00 is still rest, but no longer night: the Great Ape window must not gain an hour.
    compare(Moon.isRestHours(6), true)
    compare(Moon.isNight(6), false)
    compare(Moon.isRestHours(7), false)
  }

  function test_a_bad_hour_is_not_resting() {
    compare(Moon.isRestHours(undefined), false)
    compare(Moon.isRestHours("late"), false)
  }

  function test_times_before_the_epoch_still_compute() {
    compare(Moon.isFullWindow(fullInstant(-1)), true)
    compare(Moon.isFullWindow(epochMs - synodicMs), false)
  }
}
