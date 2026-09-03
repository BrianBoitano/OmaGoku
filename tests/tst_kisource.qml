import QtQuick
import QtTest
import "../ki.js" as Ki

// The rules for trusting a ki reading, tested without touching a file. Quickshell's QML
// plugin cannot load outside the quickshell binary, so KiSource itself is uninstantiable
// here -- which is exactly why these rules live in ki.js and not in the component.
TestCase {
  name: "KiSource"

  readonly property real now: 1788227500
  property var st: Ki.emptyState()

  function init() { st = Ki.emptyState() }

  function json(form, ts) { return JSON.stringify({ form: form, ts: ts }) }

  // Mirrors what KiSource.apply() does: null means "nothing new", so keep the state.
  function feed(text, byteLength, atSecs) {
    var next = Ki.evaluate(st, text, byteLength,
                           atSecs === undefined ? now : atSecs, undefined)
    if (next) st = next
    return st
  }

  function statusOf() { return st.status }
  function formOf() { return Ki.formOf(st) }

  function test_a_fresh_reading_is_accepted() {
    feed(json("ssj", 1788227478.59), undefined)
    compare(statusOf(), "ok")
    compare(formOf(), "ssj")
    compare(Ki.indexOf(formOf()), 1)
  }

  // ki.json's ts is Unix SECONDS; Date.now() is milliseconds. Mixing them makes every
  // reading look fifty years in the future.
  function test_staleness_is_measured_in_seconds() {
    feed(json("blue", now - 299), undefined)
    compare(statusOf(), "ok")
    init()
    feed(json("blue", now - 301), undefined)
    compare(statusOf(), "stale")
    compare(formOf(), "base", "a stale reading must not show a form")
  }

  function test_a_future_dated_reading_is_rejected() {
    feed(json("ui", now + 121), undefined)
    compare(statusOf(), "malformed")
    compare(formOf(), "base")
  }

  function test_skew_inside_the_bound_is_tolerated() {
    feed(json("ui", now + 119), undefined)
    compare(statusOf(), "ok")
    compare(formOf(), "ui")
  }

  function test_malformed_json_falls_to_base() {
    feed("{not json", undefined)
    compare(statusOf(), "malformed")
    compare(formOf(), "base")
  }

  // An absent file is a zero-byte read from `head -c`, which must read as missing rather
  // than as a corrupt payload: they mean different things to the person reading the log.
  function test_an_empty_read_is_missing_not_malformed() {
    feed("", undefined)
    compare(statusOf(), "missing")
  }

  // Overflow is decided on BYTES. A multibyte payload of 65537 bytes reports a SHORTER
  // decoded length, so a string-length check would let an oversized file through.
  function test_oversize_is_measured_on_bytes_not_decoded_length() {
    var small = json("ssj", 1788227490)
    feed(small, 65537)
    compare(statusOf(), "malformed", "byteLength is authoritative over string length")
    compare(formOf(), "base")
    init()
    feed(small, 65536)
    compare(statusOf(), "ok", "exactly at the cap is still acceptable")
  }

  // The form is concatenated into an asset URL, so anything off the allowlist is a reading
  // we do not understand, not "some other form".
  function test_a_form_off_the_allowlist_can_never_reach_a_sprite_path() {
    var bad = ["ssj4", "../../etc/passwd", "", "base/../ui", 3, null]
    for (var i = 0; i < bad.length; i++) {
      init()
      feed(JSON.stringify({ form: bad[i], ts: 1788227490 }), undefined)
      compare(formOf(), "base", "form " + bad[i])
      compare(statusOf(), "malformed", "form " + bad[i])
    }
  }

  function test_a_nonnumeric_timestamp_is_rejected() {
    var bad = ["soon", null, -1]
    for (var i = 0; i < bad.length; i++) {
      init()
      feed(JSON.stringify({ form: "ssj", ts: bad[i] }), undefined)
      compare(statusOf(), "malformed", "ts " + bad[i])
    }
    init()
    feed('{"form":"ssj"}', undefined)
    compare(statusOf(), "malformed", "a missing ts is not a fresh ts")
  }

  // A slow read that lands after a newer one must not resurrect the older reading.
  function test_a_late_read_cannot_overwrite_a_newer_snapshot() {
    feed(json("ui", 1788227490), undefined)
    compare(formOf(), "ui")
    feed(json("base", 1788227480), undefined)
    compare(formOf(), "ui", "the older snapshot was ignored")
    compare(st.acceptedTs, 1788227490)
  }

  // A reading that simply stops being updated has to go stale on its own, or a machine that
  // stopped reporting sits there looking like it is still at full power.
  function test_freshness_is_re_evaluated_without_the_file_changing() {
    feed(json("blue", 1788227490), undefined)
    compare(statusOf(), "ok")
    var next = Ki.refreshed(st, 1788227490 + 301, undefined)
    verify(next !== null, "freshness must change on its own")
    st = next
    compare(statusOf(), "stale")
    compare(formOf(), "base")
  }

  // A 5s poll that re-set the status every tick would log a transition every tick.
  function test_unchanged_freshness_reports_nothing_new() {
    feed(json("blue", 1788227490), undefined)
    compare(Ki.refreshed(st, 1788227495, undefined), null)
  }

  // Recovery: a machine that goes quiet and comes back must climb back out of stale.
  function test_a_recovered_reading_returns_to_ok() {
    feed(json("blue", 1788227100), undefined)
    compare(statusOf(), "stale")
    feed(json("blue", 1788227499), undefined)
    compare(statusOf(), "ok")
    compare(formOf(), "blue")
  }

  // Everything fails closed: no state other than "ok" may report a transformation.
  function test_only_an_ok_status_can_show_a_form() {
    var states = ["stale", "missing", "malformed"]
    for (var i = 0; i < states.length; i++)
      compare(Ki.formOf({ status: states[i], acceptedTs: 1, acceptedForm: "ui" }),
              "base", states[i])
  }

  // Regression, cross-inspection finding 5. The monotonic rule used to run BEFORE the form
  // was validated, so an older reading that was ALSO garbage returned "nothing new" and the
  // previously accepted transformation stayed on screen indefinitely -- the pet showing a
  // power level while the only evidence for it was an unreadable file.
  function test_an_older_reading_that_is_malformed_still_clears_the_snapshot() {
    feed(json("ui", 1788227490), undefined)
    compare(formOf(), "ui")
    feed(JSON.stringify({ form: "../../bad", ts: 1788227480 }), undefined)
    compare(statusOf(), "malformed")
    compare(formOf(), "base")
    compare(st.acceptedTs, -1)
  }

  function test_an_older_reading_that_is_valid_is_still_ignored() {
    feed(json("ui", 1788227490), undefined)
    feed(json("ssj", 1788227480), undefined)
    compare(formOf(), "ui", "a valid older snapshot must not overwrite a newer one")
    compare(statusOf(), "ok")
  }

  // A rejection must clear the snapshot, not leave a fossil behind it.
  function test_a_rejection_clears_the_accepted_snapshot() {
    feed(json("ui", 1788227490), undefined)
    compare(formOf(), "ui")
    feed("{corrupt", undefined)
    compare(st.acceptedTs, -1)
    compare(st.acceptedForm, "base")
  }
}
