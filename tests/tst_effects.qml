import QtQuick
import QtTest
import "../effects.js" as Effects

// The effect lane is separate from the notification budget on purpose: 4/hour and 120s
// spacing are calibrated for an interrupting toast, while a 10s flare's irritation is
// about motion. A flare must never spend a notification slot. Phase 1 puts a second
// consumer -- the move sets -- on the same lane.
TestCase {
  name: "Effects"

  readonly property real t0: 1788300000000
  readonly property var moveIds: ["kamehameha", "spirit_bomb", "kaioken"]

  // The exact document Service.flushNotifyState() writes: the budget state at the root with
  // the effect state under its own key.
  function flushed(effects) {
    return JSON.stringify({ sends: [], chatter: {}, reducers: {}, effects: effects })
  }
  function opts(over) {
    var o = { moveIds: moveIds, clockReady: true }
    for (var k in over) o[k] = over[k]
    return o
  }

  // --- the flare, unchanged --------------------------------------------------

  function test_a_first_flare_is_admitted() {
    compare(Effects.admit(Effects.emptyState(), t0, false).ok, true)
  }

  function test_spacing_is_ten_minutes() {
    var st = Effects.admit(Effects.emptyState(), t0, false).state
    compare(Effects.admit(st, t0 + 599000, false).ok, false)
    compare(Effects.admit(st, t0 + 601000, false).ok, true)
  }

  function test_only_one_flare_is_in_flight() {
    var st = Effects.admit(Effects.emptyState(), t0, false).state
    var r = Effects.admit(st, t0 + 5000, false)
    compare(r.ok, false)
    compare(r.reason, "in-flight")
  }

  function test_reduced_motion_is_a_hard_veto_for_the_flare() {
    var r = Effects.admit(Effects.emptyState(), t0, true)
    compare(r.ok, false)
    compare(r.reason, "reduced-motion")
  }

  // A bare inFlight boolean persisted just before a crash would mute the lane forever.
  function test_in_flight_is_derived_from_an_expiring_stamp() {
    var st = Effects.admit(Effects.emptyState(), t0, false).state
    compare(Effects.inFlight(st, t0 + 1000), true)
    compare(Effects.inFlight(st, t0 + Effects.FLARE_MS + 1), false,
            "expiry recovers on its own after a crash")
  }

  // --- the envelope, and the bug it is fixing --------------------------------

  // THE REGRESSION. Service wrote the stamps under `effects` while loadState read them from
  // the document ROOT, so validPair(undefined, undefined) was false, every load returned an
  // empty state, and the flare's spacing never once survived a shell restart. This test
  // feeds back the exact document Service writes, which is what nothing did before.
  function test_the_written_document_reads_back() {
    var st = Effects.admit(Effects.emptyState(), t0, false).state
    var back = Effects.loadState(flushed(st), t0 + 60000, opts({}))
    compare(back.lastAdmittedAt, t0, "the spacing must survive a restart")
    compare(back.admittedUntil, t0 + Effects.FLARE_MS)
    compare(Effects.admit(back, t0 + 60000, false).ok, false, "and still be owed")
  }

  // The shape found in the wild before versioning: a nested object with no version.
  function test_an_unversioned_envelope_migrates() {
    var legacy = { lastAdmittedAt: t0, admittedUntil: t0 + Effects.FLARE_MS }
    var st = Effects.loadState(flushed(legacy), t0 + 1000, opts({}))
    compare(st.mode, "live")
    compare(st.v, 1)
    compare(st.lastAdmittedAt, t0)
  }

  // Running cold-start instead would discard the spacing authority the envelope holds, and
  // repeated restarts would bypass it over and over while unable to persist a replacement.
  function test_an_unknown_version_disables_the_lane_and_is_preserved() {
    var future = { v: 99, lastAdmittedAt: t0, somethingNew: [1, 2] }
    var st = Effects.loadState(flushed(future), t0 + 1000, opts({}))
    compare(st.mode, "disabled")
    compare(Effects.admit(st, t0 + 999999, false).ok, false)
    compare(Effects.admitMove(st, t0 + 999999, false, "kamehameha", 2600, opts({})).ok, false)
    compare(JSON.stringify(Effects.toSave(st)), JSON.stringify(future),
            "and it is written back untouched")
  }

  // Fails CLOSED, and the penalty starts from the trusted clock, not from boot time.
  function test_a_corrupt_document_fails_closed_until_the_clock_is_trusted() {
    var st = Effects.loadState("{nope", t0, opts({}))
    compare(st.mode, "disabled")
    compare(Effects.admit(st, t0, false).ok, false, "a garbled file is not a free flare")
    var armed = Effects.armAfterClock(st, t0)
    compare(armed.mode, "live")
    compare(Effects.admit(armed, t0 + 1000, false).ok, false, "a full spacing is owed")
    compare(Effects.admit(armed, t0 + Effects.SPACING_MS + 1000, false).ok, true)
  }

  function test_a_missing_envelope_is_a_normal_cold_start() {
    var st = Effects.loadState(flushed(undefined), t0, opts({}))
    compare(st.mode, "live")
    compare(Effects.admit(st, t0, false).ok, true)
  }

  // --- moves -----------------------------------------------------------------

  function test_a_move_and_a_flare_share_the_lane() {
    var st = Effects.admitMove(Effects.emptyState(), t0, false, "kamehameha", 2600,
                               opts({})).state
    compare(Effects.admit(st, t0 + 1000, false).reason, "in-flight")
    compare(Effects.admit(st, t0 + 5000, false).reason, "spacing",
            "the move's 2600ms is over but the shared ten minutes is not")
    var flare = Effects.admit(Effects.emptyState(), t0, false).state
    compare(Effects.admitMove(flare, t0 + 1000, false, "kamehameha", 2600, opts({})).ok, false)
  }

  function test_each_move_has_its_own_hourly_cooldown() {
    var st = Effects.admitMove(Effects.emptyState(), t0, false, "kamehameha", 2600,
                               opts({})).state
    var soon = t0 + Effects.SPACING_MS + 1000
    compare(Effects.admitMove(st, soon, false, "kamehameha", 2600, opts({})).reason,
            "move-cooldown")
    compare(Effects.admitMove(st, soon, false, "kaioken", 2600, opts({})).ok, true,
            "a different move is not on that cooldown")
    compare(Effects.admitMove(st, t0 + Effects.MOVE_COOLDOWN_MS + 1000, false,
                              "kamehameha", 2600, opts({})).ok, true)
  }

  // Dropping the whole map on one bad key turns a single clock anomaly into a burst.
  function test_one_bad_cooldown_entry_does_not_clear_its_siblings() {
    var env = { v: 1, moves: { kamehameha: t0, spirit_bomb: "whenever",
                               not_a_move: t0, kaioken: -5 } }
    var st = Effects.loadState(flushed(env), t0 + 1000, opts({}))
    compare(st.mode, "live")
    compare(st.moves.kamehameha, t0, "the valid sibling survives")
    compare(st.moves.spirit_bomb, undefined)
    compare(st.moves.not_a_move, undefined, "and an id off the roster is dropped")
    compare(st.moves.kaioken, undefined)
  }

  function test_a_future_cooldown_suppresses_without_being_rewritten() {
    var env = { v: 1, moves: { kamehameha: t0 + 86400000 } }
    var st = Effects.loadState(flushed(env), t0, opts({}))
    compare(st.moves.kamehameha, t0 + 86400000, "kept, not clamped")
    compare(Effects.admitMove(st, t0, false, "kamehameha", 2600, opts({})).ok, false,
            "a clock that is behind will catch up")
  }

  // Suppressing motion is not suppressing the feature.
  function test_reduced_motion_gives_a_move_a_static_result_not_a_veto() {
    var r = Effects.admitMove(Effects.emptyState(), t0, true, "kamehameha", 1200, opts({}))
    compare(r.ok, true)
    compare(r.static, true)
  }

  function test_no_move_is_admitted_before_the_clock_is_trusted() {
    var r = Effects.admitMove(Effects.emptyState(), t0, false, "kamehameha", 2600,
                              opts({ clockReady: false }))
    compare(r.ok, false)
    compare(r.reason, "clock")
  }

  // --- the ambient schedule --------------------------------------------------

  function test_the_ambient_deadline_is_drawn_between_45_and_90_minutes() {
    var lo = Effects.drawAmbient(Effects.emptyState(), t0, function () { return 0 })
    var hi = Effects.drawAmbient(Effects.emptyState(), t0, function () { return 1 })
    compare(lo.nextAmbientAt, t0 + Effects.AMBIENT_MIN_MS)
    compare(hi.nextAmbientAt, t0 + Effects.AMBIENT_MAX_MS)
  }

  // It advances after every DUE ATTEMPT, admitted or not. Committing it only on success
  // means an overdue attempt retries on every tick, which is a queued move in disguise.
  function test_an_undrawn_schedule_is_never_due_and_a_drawn_one_becomes_due() {
    compare(Effects.ambientDue(Effects.emptyState(), t0), false)
    var st = Effects.drawAmbient(Effects.emptyState(), t0, function () { return 0 })
    compare(Effects.ambientDue(st, t0 + Effects.AMBIENT_MIN_MS - 1000), false)
    compare(Effects.ambientDue(st, t0 + Effects.AMBIENT_MIN_MS), true)
  }
}
