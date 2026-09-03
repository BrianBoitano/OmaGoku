import QtQuick
import QtTest
import "../ki.js" as Ki

// `power` validates INDEPENDENTLY of `form`: a malformed power must not poison a valid
// form, and only an ok snapshot with a valid power shows a readout at all.
TestCase {
  name: "KiPower"

  readonly property real now: 1788227500
  property var st: Ki.emptyState()
  function init() { st = Ki.emptyState() }
  function feed(obj, atSecs) {
    var next = Ki.evaluate(st, JSON.stringify(obj), undefined,
                           atSecs === undefined ? now : atSecs, undefined)
    if (next) st = next
    return st
  }

  function test_a_valid_power_rides_a_valid_form() {
    feed({ form: "ssj", ts: now - 1, power: 12400 })
    compare(Ki.powerOf(st), 12400)
    compare(Ki.formOf(st), "ssj")
  }

  function test_a_malformed_power_does_not_poison_the_form() {
    var bad = ["12k", -1, 1e9 + 1, {}, true]
    for (var i = 0; i < bad.length; i++) {
      init()
      feed({ form: "ssj", ts: now - 1, power: bad[i] })
      compare(st.status, "ok", "power " + JSON.stringify(bad[i])
              + " must not reject the snapshot")
      compare(Ki.formOf(st), "ssj", "power " + JSON.stringify(bad[i]))
      compare(Ki.powerOf(st), null, "power " + JSON.stringify(bad[i])
              + " must hide the readout")
    }
  }

  function test_an_absent_power_reads_null() {
    feed({ form: "blue", ts: now - 1 })
    compare(Ki.powerOf(st), null)
  }

  function test_zero_and_the_cap_are_valid() {
    feed({ form: "base", ts: now - 1, power: 0 })
    compare(Ki.powerOf(st), 0)
    init()
    feed({ form: "base", ts: now - 1, power: 1e9 })
    compare(Ki.powerOf(st), 1e9)
  }

  function test_only_an_ok_snapshot_shows_power() {
    feed({ form: "ssj", ts: now - 301, power: 9500 })
    compare(st.status, "stale")
    compare(Ki.powerOf(st), null, "a stale power is not a reading")
  }

  function test_a_rejection_clears_power_too() {
    feed({ form: "ssj", ts: now - 1, power: 9500 })
    compare(Ki.powerOf(st), 9500)
    feed({ corrupt: true })
    compare(Ki.powerOf(st), null)
  }

  // REGRESSION, shipped defect 2026-09-01. KiSource mirrored the snapshot field by field and
  // simply forgot acceptedPower, so powerOf() read undefined forever and three wave-1 features
  // were dead in production while every ki.js test passed. The component now holds ONE state
  // object so there is nothing to mirror; this test pins the field set so a future field
  // cannot drift between the producers either.
  function test_every_state_producer_agrees_on_the_field_set() {
    var want = Ki.STATE_KEYS.slice().sort().join(",")
    function keysOf(o) { var k = []; for (var n in o) k.push(n); return k.sort().join(",") }
    compare(keysOf(Ki.emptyState()), want, "emptyState")
    compare(keysOf(Ki.rejected("malformed")), want, "rejected")
    var ok = Ki.evaluate(Ki.emptyState(), json2("ssj", now - 1, 9500), undefined, now, undefined)
    compare(keysOf(ok), want, "evaluate")
    var refreshed = Ki.refreshed(ok, now + 400, undefined)
    verify(refreshed !== null)
    compare(keysOf(refreshed), want, "refreshed")
  }

  function json2(form, ts, power) {
    return JSON.stringify({ form: form, ts: ts, power: power })
  }

  function test_power_survives_a_freshness_round_trip() {
    feed({ form: "ssj", ts: now - 1, power: 9500 })
    var stale = Ki.refreshed(st, now + 400, undefined)
    verify(stale !== null)
    compare(Ki.powerOf(stale), null, "stale hides the readout")
    var back = Ki.refreshed(stale, now + 100, undefined)
    verify(back !== null)
    compare(Ki.powerOf(back), 9500, "recovery restores the same reading")
  }
}
