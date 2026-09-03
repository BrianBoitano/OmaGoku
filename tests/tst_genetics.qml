import QtQuick
import QtTest
import "../genetics.js" as Gen
import "../lines.js" as Lines

// Breakable genetics: the bucket a bloodline has earned, derived on every read and never
// stored. Two rules govern everything here:
//
//   IT READS ONLY WHAT IS ON DISK. Service promotes lineageState solely on a matching
//   `saved`, so a row that has not landed is not part of the bloodline yet.
//
//   IT NEVER THROWS AND NEVER GUESSES. Every hostile shape resolves to the neutral bucket
//   with a reason, because this function feeds a sprite path.
TestCase {
  name: "Genetics"

  function entry(over) {
    var e = {
      progressMode: "live",
      petId: "0123456789abcdef0123456789abcdef",
      gen: 3, line: "goku", endedBy: "farewell", stage: "adult", form: "adult_ace",
      bornAt: 1700000000000, endedAt: 1700009000000,
      curve: 1, xp: 5000, peakKiRung: 2, ballsCollected: 4, wishesGranted: 1,
      careAverage: 60
    }
    for (var k in over) e[k] = over[k]
    return e
  }

  function input(entries, over) {
    var s = { ready: true, mode: "valid", record: { v: 1, entries: entries } }
    for (var k in over) s[k] = over[k]
    return s
  }

  // Three adult farewells whose care averages sum to `sum`, split as evenly as the integer
  // bounds allow, so a test can name the sum it means rather than three numbers.
  function windowOf(sum) {
    var a = Math.floor(sum / 3), b = Math.floor((sum - a) / 2)
    return [entry({ careAverage: a }), entry({ careAverage: b }),
            entry({ careAverage: sum - a - b })]
  }

  // --- totality --------------------------------------------------------------
  //
  // The output reaches an asset URL through Lines.variantSuffix, so "it cannot throw" is not
  // a nicety. Structural guards run BEFORE anything is iterated.

  function test_hostile_state_shapes_are_unreadable_not_thrown() {
    var hostile = [null, undefined, 42, "valid", [],
                   { ready: true, mode: "valid" },
                   { ready: true, mode: "valid", record: 7 },
                   { ready: true, mode: "valid", record: {} },
                   { ready: true, mode: "valid", record: { entries: "nope" } }]
    for (var i = 0; i < hostile.length; i++) {
      var r = Gen.bucket(hostile[i], "goku")
      compare(r.bucket, 2, "hostile state " + i + " must be neutral")
      compare(r.reason, "unreadable", "hostile state " + i)
    }
  }

  function test_hostile_entries_do_not_throw() {
    var r = Gen.bucket(input([null, "row", 5, [], entry({})]), "goku")
    compare(r.bucket, 2)
    compare(r.reason, "too-few-farewells", "junk is skipped, not counted as a farewell")
  }

  function test_an_unknown_line_is_unreadable() {
    compare(Gen.bucket(input(windowOf(300)), "nobody").reason, "unreadable")
    compare(Gen.bucket(input(windowOf(300)), "").reason, "unreadable")
    compare(Gen.bucket(input(windowOf(300)), null).reason, "unreadable")
  }

  // --- trust -----------------------------------------------------------------

  function test_not_ready_is_its_own_reason() {
    var r = Gen.bucket(input(windowOf(300), { ready: false }), "goku")
    compare(r.bucket, 2)
    compare(r.reason, "not-ready")
  }

  // A partial record is read-only because a row could not be READ -- and an unreadable row
  // carries no readable line, so it could have belonged inside any line's window.
  function test_partial_is_record_incomplete_even_with_a_perfect_window() {
    var r = Gen.bucket(input(windowOf(300), { mode: "partial" }), "goku")
    compare(r.bucket, 2)
    compare(r.reason, "record-incomplete")
  }

  function test_an_unrecognised_or_unreadable_mode_inherits_nothing() {
    var modes = ["corrupt", "something-new"]
    for (var i = 0; i < modes.length; i++)
      compare(Gen.bucket(input(windowOf(300), { mode: modes[i] }), "goku").reason,
              "unreadable", modes[i])
  }

  // A failed WRITE leaves the last record confirmed on disk sitting in memory, which is
  // exactly the input this function asks for. Calling it unreadable made a full disk change
  // the pet's colours -- a lie in the opposite direction from the one being avoided.
  function test_a_failed_write_still_reads_the_last_confirmed_record() {
    var r = Gen.bucket(input(windowOf(300), { mode: "write-failed" }), "goku")
    compare(r.reason, "inherited")
    compare(r.bucket, 4)
  }

  function test_missing_is_trusted_and_simply_has_no_history() {
    var r = Gen.bucket(input([], { mode: "missing" }), "goku")
    compare(r.reason, "too-few-farewells")
  }

  // --- the window: latest three FIRST, then trust ----------------------------
  //
  // Filtering for readable rows before taking three lets a recent frozen farewell disappear
  // as if it never happened, and reaches back into stale history for a fourth-oldest row.

  function test_a_recent_frozen_farewell_blocks_the_window() {
    var rows = [entry({ careAverage: 100 }), entry({ careAverage: 100 }),
                entry({ careAverage: 100 }),
                { progressMode: "frozen", petId: "0123456789abcdef0123456789abcdef",
                  gen: 4, line: "goku", endedBy: "farewell", stage: "adult",
                  form: "adult_ace", bornAt: null, endedAt: null }]
    var r = Gen.bucket(input(rows), "goku")
    compare(r.reason, "window-unreadable",
            "the newest farewell is unreadable, so the window is not trusted")
    compare(r.bucket, 2, "and it must NOT inherit bucket 4 from the three older rows")
  }

  function test_candidacy_uses_only_line_endedBy_and_stage() {
    var rows = [entry({ line: "vegeta", careAverage: 100 }),
                entry({ endedBy: "reset", careAverage: 100 }),
                entry({ stage: "teen", careAverage: 100 }),
                entry({ careAverage: 10 }), entry({ careAverage: 10 }),
                entry({ careAverage: 10 })]
    var r = Gen.bucket(input(rows), "goku")
    compare(r.reason, "inherited")
    compare(r.bucket, 0, "only the three neglected goku adult farewells count")
  }

  function test_fewer_than_three_is_not_a_bloodline_yet() {
    compare(Gen.bucket(input([]), "goku").reason, "too-few-farewells")
    compare(Gen.bucket(input([entry({}), entry({})]), "goku").reason, "too-few-farewells")
  }

  function test_a_never_sampled_row_in_the_window_is_named() {
    var rows = [entry({ careAverage: 90 }), entry({ careAverage: 90 }),
                entry({ careAverage: null })]
    var r = Gen.bucket(input(rows), "goku")
    compare(r.reason, "window-unsampled")
    compare(r.bucket, 2)
  }

  function test_the_window_is_the_LAST_three_by_position() {
    var rows = [entry({ careAverage: 0 }), entry({ careAverage: 0 }),
                entry({ careAverage: 100 }), entry({ careAverage: 100 }),
                entry({ careAverage: 100 })]
    compare(Gen.bucket(input(rows), "goku").bucket, 4,
            "the three newest, not the three oldest")
  }

  // --- classification, in integers -------------------------------------------
  //
  // The comparison is on the SUM of three integers, so no fractional mean can fall between
  // two ranges and no rounding rule has to be argued about.

  function test_bucket_boundaries_are_exact() {
    var cases = [[0, 0], [89, 0], [90, 1], [149, 1], [150, 2], [209, 2],
                 [210, 3], [254, 3], [255, 4], [300, 4]]
    for (var i = 0; i < cases.length; i++) {
      var sum = cases[i][0], want = cases[i][1]
      var r = Gen.bucket(input(windowOf(sum)), "goku")
      compare(r.bucket, want, "sum " + sum + " must be bucket " + want)
      compare(r.reason, "inherited", "sum " + sum)
    }
  }

  // --- the farm test, named --------------------------------------------------
  //
  // careAverage is a mean with no sample count, so a reset baby once weighed exactly as much
  // as a months-old adult and three throwaway pets could replace the whole window.

  function test_three_baby_resets_cannot_move_a_bloodline() {
    var rows = []
    for (var i = 0; i < 10; i++) rows.push(entry({ careAverage: 95 }))
    for (var j = 0; j < 3; j++)
      rows.push(entry({ endedBy: "reset", stage: "baby", form: "baby", careAverage: 0 }))
    var r = Gen.bucket(input(rows), "goku")
    compare(r.bucket, 4, "the ten adult farewells still own the window")
    compare(r.reason, "inherited")
  }

  function test_three_neglected_adult_farewells_DO_move_it() {
    var rows = []
    for (var i = 0; i < 10; i++) rows.push(entry({ careAverage: 95 }))
    for (var j = 0; j < 3; j++) rows.push(entry({ careAverage: 5 }))
    compare(Gen.bucket(input(rows), "goku").bucket, 0, "the line is breakable")
  }

  // --- the suffix ------------------------------------------------------------
  //
  // A clamp or a modulo would map an invalid bucket onto arbitrary VALID art, hiding the bug
  // behind a pet that looks fine. Invalid must fail to canonical.

  function test_only_four_buckets_produce_a_token() {
    compare(Lines.variantSuffix(0), "_g0")
    compare(Lines.variantSuffix(1), "_g1")
    compare(Lines.variantSuffix(2), "", "bucket 2 is the identity and reuses canonical art")
    compare(Lines.variantSuffix(3), "_g3")
    compare(Lines.variantSuffix(4), "_g4")
  }

  function test_every_invalid_bucket_falls_to_canonical() {
    var bad = [null, undefined, "3", 3.5, -1, 5, 100, NaN, Infinity, -Infinity, {}, []]
    for (var i = 0; i < bad.length; i++)
      compare(Lines.variantSuffix(bad[i]), "", "invalid bucket " + i + " must be canonical")
  }

  // The token must never look like a path or a form: it is appended to a filename that is
  // already line-prefixed, and Lineage.validEntry would drop every historical row if it ever
  // reached `line` or `form`.
  function test_the_token_is_inert() {
    for (var b = 0; b <= 4; b++) {
      var s = Lines.variantSuffix(b)
      verify(s.indexOf("/") < 0 && s.indexOf("..") < 0, "no path parts")
      verify(s === "" || /^_g[0-4]$/.test(s), "one pinned shape")
    }
  }
}
