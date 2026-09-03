import QtQuick
import QtTest
import "../levels.js" as L

// The progression layer. Everything here is pure on purpose: it owns XP, the curve, every
// payout ledger and the save boundary, which is the logic most able to lose weeks of a pet's
// life quietly.
TestCase {
  name: "Levels"

  // --- the curve -------------------------------------------------------------

  function test_level_one_costs_nothing() {
    compare(L.THRESHOLDS[1], 0, "a fresh pet must load at level 1, not level 0")
    compare(L.levelFor(0), 1)
  }

  function test_the_curve_is_frozen_at_these_exact_numbers() {
    compare(L.THRESHOLDS[8], 2196)
    compare(L.THRESHOLDS[12], 5067)
    compare(L.THRESHOLDS[20], 13927)
    compare(L.THRESHOLDS[30], 30450)
    compare(L.THRESHOLDS[40], 52677)
    compare(L.THRESHOLDS[60], 113299)
    compare(L.THRESHOLDS[100], 295173)
  }

  function test_level_boundaries_are_exact() {
    var marks = [8, 12, 20, 30, 40, 60, 100]
    for (var i = 0; i < marks.length; i++) {
      var n = marks[i]
      compare(L.levelFor(L.THRESHOLDS[n] - 1), n - 1, "one XP below level " + n)
      compare(L.levelFor(L.THRESHOLDS[n]), n, "exactly at level " + n)
      compare(L.levelFor(L.THRESHOLDS[n] + 1), n, "one XP above level " + n)
    }
  }

  function test_the_curve_caps_at_one_hundred() {
    compare(L.levelFor(L.MAX_XP), 100)
    compare(L.levelFor(L.THRESHOLDS[100] * 10), 100)
    compare(L.xpToNextLevel(L.THRESHOLDS[100]), null, "level 100 has no next level")
  }

  function test_progress_readout() {
    compare(L.xpIntoLevel(L.THRESHOLDS[12]), 0)
    compare(L.xpIntoLevel(L.THRESHOLDS[12] + 40), 40)
    compare(L.xpToNextLevel(L.THRESHOLDS[12]), L.THRESHOLDS[13] - L.THRESHOLDS[12])
  }

  // --- safeInt ---------------------------------------------------------------

  // The general num() loader coerces strings and accepts fractions. XP is a counter.
  function test_safeInt_refuses_everything_that_is_not_a_counter() {
    compare(L.safeInt(5000, L.MAX_XP), 5000)
    compare(L.safeInt(0, L.MAX_XP), 0)
    compare(L.safeInt("5000", L.MAX_XP), null)
    compare(L.safeInt(1.5, L.MAX_XP), null)
    compare(L.safeInt(-1, L.MAX_XP), null)
    compare(L.safeInt(NaN, L.MAX_XP), null)
    compare(L.safeInt(Infinity, L.MAX_XP), null)
    compare(L.safeInt(1e300, L.MAX_XP), null)
    compare(L.safeInt([], L.MAX_XP), null)
    compare(L.safeInt({}, L.MAX_XP), null)
    compare(L.safeInt(null, L.MAX_XP), null)
    compare(L.safeInt(undefined, L.MAX_XP), null)
    compare(L.safeInt(true, L.MAX_XP), null)
  }

  // The reader is `head -c`, which counts BYTES. A .length check passes a multibyte
  // subtree that then writes a file over the cap, which resets the pet on the next load.
  function test_utf8Bytes_counts_bytes_not_characters() {
    compare(L.utf8Bytes("abc"), 3)
    compare(L.utf8Bytes("é"), 2)
    compare(L.utf8Bytes("気"), 3)
    compare(L.utf8Bytes("😀"), 4)
    compare(L.utf8Bytes("a気😀"), 8)
    verify(L.utf8Bytes("気気気") > "気気気".length)
  }

  // --- the rate multiplier ---------------------------------------------------

  function test_rate_multiplier_falls_one_percent_per_level_to_a_half() {
    compare(L.rateMultiplier(1), 1)
    compare(L.rateMultiplier(2), 0.99)
    compare(L.rateMultiplier(51), 0.5)
    compare(L.rateMultiplier(100), 0.5, "the floor holds")
  }

  // --- the transformation gate -----------------------------------------------

  function test_level_cap_index_is_an_index() {
    compare(L.levelCapIndex(1), 0)
    compare(L.levelCapIndex(7), 0)
    compare(L.levelCapIndex(8), 1)
    compare(L.levelCapIndex(19), 1)
    compare(L.levelCapIndex(20), 2)
    compare(L.levelCapIndex(39), 2)
    compare(L.levelCapIndex(40), 3)
    compare(L.levelCapIndex(100), 3)
  }

  // The deployment regression. Every pet alive today migrates at level 1, and gating it
  // would demote an honest Ultra Instinct to Base for six weeks.
  function test_a_legacy_pet_is_never_level_gated() {
    var legacy = L.mint({ claimedPet: true, nowMs: 1000, clockReady: true })
    compare(legacy.pacing, 0)
    compare(L.levelCapFor({ mode: "live", progress: legacy }), null, "uncapped for life")

    var fresh = L.mint({ claimedPet: false, nowMs: 1000, clockReady: true })
    compare(fresh.pacing, 1)
    compare(L.levelCapFor({ mode: "live", progress: fresh }), 0, "level 1 caps at base")
  }

  function test_a_non_live_subtree_fails_closed_and_never_speeds_the_pet_up() {
    var modes = ["absent", "frozen", "corrupt"]
    for (var i = 0; i < modes.length; i++) {
      compare(L.levelCapFor({ mode: modes[i], progress: null }), 0, modes[i] + " caps at base")
      compare(L.multiplierFor({ mode: modes[i], progress: null }), 1, modes[i] + " is neutral")
    }
  }

  // --- the falling-edge latch ------------------------------------------------

  function fall(rs, v) { return L.fallLatch(rs, v, 85, 90) }

  function test_a_real_recovery_pays_once() {
    var s = fall(null, 95).state          // prime: bad
    compare(fall(s, 95).fire, false)
    var r = fall(s, 40)
    compare(r.fire, true, "fell below 85 from armed")
    compare(fall(r.state, 40).fire, false, "does not re-fire while good")
  }

  function test_a_gap_pays_nothing() {
    var s = fall(null, 95).state
    var gap = fall(s, null)
    compare(gap.fire, false)
    compare(gap.state.continuous, false, "an unknown measurement breaks continuity")
    var back = fall(gap.state, 40)
    compare(back.fire, false, "bad -> unknown -> good must not pay")
    compare(back.state.continuous, true, "and the first trusted sample re-primes")
  }

  function test_two_real_recoveries_pay_twice() {
    var s = fall(null, 95).state
    var a = fall(s, 40); compare(a.fire, true)
    var b = fall(a.state, 95); compare(b.fire, false)
    var c = fall(b.state, 40); compare(c.fire, true)
  }

  // Continuity is a WITHIN-RUN property. Persisting it true would let the first probe after
  // a shell restart count as adjacent to the last sample before it.
  function test_continuity_always_cold_starts_closed() {
    var loaded = L.loadLatch({ primed: true, armed: true, continuous: true })
    compare(loaded.primed, true)
    compare(loaded.continuous, false, "forced closed on load")
    compare(fall(loaded, 40).fire, false, "so the first sample after a load pays nothing")
  }

  function test_count_latches_use_the_same_reducer() {
    var s = L.fallLatch(null, 3, 1, 1).state      // 3 failed units
    var r = L.fallLatch(s, 0, 1, 1)
    compare(r.fire, true, "reaching zero is the recovery")
    compare(L.fallLatch(r.state, 0, 1, 1).fire, false)
  }

  // --- the rising latch, for over-9000 ---------------------------------------

  function test_the_xp_rising_edge_requires_continuity() {
    var s = L.riseLatch(null, 100, 9000, 8000).state
    var hit = L.riseLatch(s, 9500, 9000, 8000)
    compare(hit.fire, true)
    var low = L.riseLatch(hit.state, 100, 9000, 8000)
    var gap = L.riseLatch(low.state, null, 9000, 8000)
    compare(L.riseLatch(gap.state, 9500, 9000, 8000).fire, false,
            "a crossing straddling a gap was not observed")
  }

  // --- civil days ------------------------------------------------------------

  // Only the DATE is compared, so a 23- or 25-hour day cannot make two days look like one.
  function test_day_ordinals_are_calendar_arithmetic() {
    compare(L.dayOrdinal(2026, 3, 8) - L.dayOrdinal(2026, 3, 7), 1, "US DST spring forward")
    compare(L.dayOrdinal(2026, 11, 1) - L.dayOrdinal(2026, 10, 31), 1, "DST fall back")
    compare(L.dayOrdinal(2024, 3, 1) - L.dayOrdinal(2024, 2, 29), 1, "leap day")
    compare(L.dayOrdinal(2027, 1, 1) - L.dayOrdinal(2026, 12, 31), 1, "year end")
    compare(L.dayOrdinal(2026, 9, 2) - L.dayOrdinal(2026, 9, 2), 0)
  }

  // --- the streak ------------------------------------------------------------

  function streakDay(p, ord) { return L.applyStreak(p, ord) }

  function test_the_streak_climbs_and_caps() {
    var p = L.mint({ claimedPet: false, nowMs: 0, clockReady: true })
    var day = 20000
    var total = 0
    for (var i = 0; i < 12; i++) {
      var r = streakDay(p, day + i)
      p = r.progress
      total += r.amount
    }
    compare(p.streak.count, 12)
    // 25 * min(N,10) for N = 1..12
    compare(total, 25 * (1 + 2 + 3 + 4 + 5 + 6 + 7 + 8 + 9 + 10 + 10 + 10))
  }

  function test_the_same_day_pays_once() {
    var p = L.mint({ claimedPet: false, nowMs: 0, clockReady: true })
    var a = streakDay(p, 20000); compare(a.amount, 25)
    var b = streakDay(a.progress, 20000); compare(b.amount, 0)
    compare(b.progress.streak.count, 1)
  }

  function test_a_missed_day_resets_the_streak() {
    var p = L.mint({ claimedPet: false, nowMs: 0, clockReady: true })
    p = streakDay(p, 20000).progress
    p = streakDay(p, 20001).progress
    compare(p.streak.count, 2)
    var r = streakDay(p, 20005)
    compare(r.progress.streak.count, 1)
    compare(r.amount, 25)
  }

  // A clock that moved backwards must not pay, reset, or restamp.
  function test_a_backwards_clock_does_nothing_at_all() {
    var p = L.mint({ claimedPet: false, nowMs: 0, clockReady: true })
    p = streakDay(p, 20000).progress
    p = streakDay(p, 20001).progress
    var r = streakDay(p, 19990)
    compare(r.amount, 0)
    compare(r.progress.streak.count, 2, "count untouched")
    compare(r.progress.streak.lastAwardedDay, 20001, "stamp untouched")
  }

  // --- daily caps ------------------------------------------------------------

  function test_an_award_truncates_at_its_daily_cap() {
    var p = L.mint({ claimedPet: false, nowMs: 0, clockReady: true })
    var r = L.applyDaily(p, "ki", 2000, 20000)
    compare(r.amount, L.DAILY_CAP.ki, "truncated, not dropped")
    compare(r.progress.daily.bySource.ki, L.DAILY_CAP.ki)
    compare(L.applyDaily(r.progress, "ki", 10, 20000).amount, 0)
  }

  function test_the_daily_ledger_resets_on_a_new_day_but_not_on_a_rollback() {
    var p = L.mint({ claimedPet: false, nowMs: 0, clockReady: true })
    p = L.applyDaily(p, "ki", 500, 20000).progress
    compare(L.applyDaily(p, "ki", 500, 20001).progress.daily.bySource.ki, 500,
            "a new day starts a fresh allowance")
    var back = L.applyDaily(p, "ki", 500, 19999)
    compare(back.progress.daily.bySource.ki, 1000,
            "a backwards clock must not mint a fresh allowance")
  }

  function test_the_published_ceiling_is_the_sum_of_the_caps() {
    var sum = L.DAILY_CAP.active + L.DAILY_CAP.ki + L.DAILY_CAP.care
              + L.DAILY_CAP.maint + L.DAILY_CAP.hunt + L.DAILY_CAP.over9000 + 250
    compare(sum, 5970, "section 2.1 of the spec is published against this number")
  }

  // --- care gating -----------------------------------------------------------

  function test_care_pays_once_per_kind_per_ten_minutes() {
    var p = L.mint({ claimedPet: false, nowMs: 0, clockReady: true })
    var t = 1700000000000
    var a = L.awardCare(p, "feed", t, 20000); compare(a.amount, 5)
    var b = L.awardCare(a.progress, "feed", t + 60000, 20000); compare(b.amount, 0)
    var c = L.awardCare(b.progress, "wash", t + 60000, 20000)
    compare(c.amount, 5, "a different kind is a different gesture")
    var d = L.awardCare(c.progress, "feed", t + 601000, 20000)
    compare(d.amount, 5, "ten minutes later it pays again")
  }

  function test_the_rolling_hourly_cap_survives_a_reload() {
    var p = L.mint({ claimedPet: false, nowMs: 0, clockReady: true })
    var t = 1700000000000
    var kinds = ["feed", "wash", "pet"]
    var paid = 0
    // Six rounds of all three gestures, eleven minutes apart: 18 gestures inside one hour,
    // every one of them past its own per-kind limit, so 90 XP is offered and 60 is the cap.
    for (var i = 0; i < 18; i++) {
      var r = L.awardCare(p, kinds[i % 3], t + Math.floor(i / 3) * 11 * 60000, 20000)
      p = r.progress
      paid += r.amount
    }
    compare(paid, 60, "60 XP an hour is the cap")
    // round-trip the ledger and confirm the cap is still spent
    var reloaded = L.load(JSON.parse(JSON.stringify(L.toSave(p))),
                          { claimedPet: false, nowMs: t, clockReady: true })
    compare(reloaded.mode, "live")
    compare(reloaded.progress.gate.window.length, p.gate.window.length)
  }

  // --- the save boundary -----------------------------------------------------

  function test_absent_means_absent_not_corrupt() {
    var r = L.load(undefined, { claimedPet: false, nowMs: 1000, clockReady: true })
    compare(r.mode, "absent")
    compare(r.progress, null)
  }

  function test_a_live_subtree_round_trips() {
    var p = L.mint({ claimedPet: false, nowMs: 1000, clockReady: true })
    p.xp = 12345
    var back = L.load(JSON.parse(JSON.stringify(L.toSave(p))),
                      { claimedPet: false, nowMs: 2000, clockReady: true })
    compare(back.mode, "live")
    compare(back.progress.xp, 12345)
    compare(back.progress.petId, p.petId)
  }

  // An unknown version is a save from a build we do not know. Zeroing it is how an older
  // shell permanently destroys a newer shell's progression on its next ordinary save.
  function test_an_unknown_version_is_frozen_and_preserved() {
    var raw = { v: 99, xp: 999999, somethingNew: { deep: [1, 2, 3] } }
    var r = L.load(raw, { claimedPet: true, nowMs: 1000, clockReady: true })
    compare(r.mode, "frozen")
    compare(JSON.stringify(L.toSave(r)), JSON.stringify(raw),
            "every key and value survives the round trip")
  }

  function test_an_unknown_curve_is_frozen_too() {
    var raw = { v: 1, curve: 99, xp: 50 }
    compare(L.load(raw, { claimedPet: true, nowMs: 1000, clockReady: true }).mode, "frozen")
  }

  // Revision 3 still replaced a corrupt subtree, throwing away both the XP and the only
  // forensic copy of what went wrong.
  function test_a_corrupt_subtree_is_preserved_read_only() {
    var raw = { v: 1, curve: 1, xp: 5000, cool: "not an object" }
    var r = L.load(raw, { claimedPet: true, nowMs: 1000, clockReady: true })
    compare(r.mode, "corrupt")
    compare(JSON.stringify(L.toSave(r)), JSON.stringify(raw))
  }

  // Admission ledgers fail CLOSED; statistics fail open. Zeroing a ledger reopens the
  // payout limit it existed to enforce.
  function test_a_malformed_ledger_freezes_but_a_malformed_statistic_does_not() {
    function withField(k, v) {
      var p = L.toSave(L.mint({ claimedPet: false, nowMs: 0, clockReady: true }))
      p[k] = v
      return L.load(p, { claimedPet: false, nowMs: 1000, clockReady: true })
    }
    compare(withField("gate", 7).mode, "corrupt", "gate is an admission ledger")
    compare(withField("cool", "x").mode, "corrupt")
    compare(withField("daily", []).mode, "corrupt")
    compare(withField("streak", 0).mode, "corrupt")
    compare(withField("xp", "5000").mode, "corrupt", "xp is authority")

    var stat = withField("wishes", "many")
    compare(stat.mode, "live", "a statistic must not freeze a whole pet's progression")
    compare(stat.progress.wishes, 0)
    var peak = withField("peakRawKiRung", 99)
    compare(peak.mode, "live")
    compare(peak.progress.peakRawKiRung, 0)
  }

  function test_hostile_input_cannot_throw() {
    var hostile = [null, undefined, 0, "", "xp", [], [1, 2], true,
                   { v: 1, curve: 1, petId: "z".repeat(5000) },
                   { v: 1, curve: 1, announced: ["not_a_move_id"] },
                   { v: 1, curve: 1, gate: { window: new Array(1000).join(",").split(","),
                                             last: {} } }]
    for (var i = 0; i < hostile.length; i++) {
      var r = L.load(hostile[i], { claimedPet: true, nowMs: 1000, clockReady: true })
      verify(["absent", "live", "frozen", "corrupt"].indexOf(r.mode) >= 0,
             "input " + i + " produced mode " + r.mode)
    }
  }

  // --- the award reducer -----------------------------------------------------

  // One heartbeat is ONE reducer call producing ONE progress. Per-source awards would mean
  // two full pet-save writes a minute.
  function test_one_heartbeat_pays_every_due_source_in_one_call() {
    var p = L.mint({ claimedPet: false, nowMs: 0, clockReady: true })
    var r = L.award(p, { kind: "heartbeat", resting: false, kiStatus: "ok",
                         rawKiIndex: 2, sample: true, sampled: 80 },
                    { nowMs: 1700000000000, dayOrdinal: 20000 })
    compare(r.progress.xp, 1 + 2 * 2, "the active minute and the ki rung")
    compare(r.awards.length, 2)
    compare(r.progress.peakRawKiRung, 2)
    compare(r.progress.care.countAll, 1)
    compare(r.progress.care.sumAll, 80)
  }

  function test_night_rest_pauses_the_trickle_but_not_the_machine() {
    var p = L.mint({ claimedPet: false, nowMs: 0, clockReady: true })
    var r = L.award(p, { kind: "heartbeat", resting: true, kiStatus: "ok",
                         rawKiIndex: 3, sample: false, sampled: 0 },
                    { nowMs: 1700000000000, dayOrdinal: 20000 })
    compare(r.progress.xp, 6, "ki keeps paying, the active minute does not")
  }

  function test_a_stale_ki_reading_pays_nothing_and_never_catches_up() {
    var p = L.mint({ claimedPet: false, nowMs: 0, clockReady: true })
    var r = L.award(p, { kind: "heartbeat", resting: false, kiStatus: "stale",
                         rawKiIndex: 3, sample: true, sampled: 50 },
                    { nowMs: 1700000000000, dayOrdinal: 20000 })
    compare(r.progress.xp, 1, "the active minute only")
    compare(r.progress.peakRawKiRung, 0, "an untrusted reading is not a peak")
  }

  // The reducer is mutation-only. It never notifies, never sounds, never writes.
  function test_the_reducer_returns_a_new_object_and_touches_nothing_else() {
    var p = L.mint({ claimedPet: false, nowMs: 0, clockReady: true })
    var before = JSON.stringify(L.toSave(p))
    L.award(p, { kind: "heartbeat", resting: false, kiStatus: "ok", rawKiIndex: 1,
                 sample: true, sampled: 90 }, { nowMs: 1, dayOrdinal: 20000 })
    compare(JSON.stringify(L.toSave(p)), before, "the input progress is not mutated")
  }
}
