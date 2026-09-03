import QtQuick
import QtTest
import "../dragonballs.js" as Balls

// The first feature to persist state INSIDE the pet's save file, which resets a pet to a
// fresh egg when it cannot be understood. Every test here is ultimately about one thing: a
// game object must never be able to trigger that.
TestCase {
  name: "DragonBalls"

  readonly property real t0: 1788300000000
  readonly property int gen: 3

  function items(over) {
    var a = []
    for (var i = 0; i < 7; i++)
      a.push({ ws: 1 + (i % 3), x: 0.1 + i * 0.1, placedAt: t0, lastSeenAt: t0,
               collected: false })
    if (over) for (var k in over) a[k] = over[k]
    return a
  }
  function full(over) {
    var s = { v: 1, scatteredAt: t0, items: items(), wish: null, keepsake: null, summon: null }
    for (var k in over) s[k] = over[k]
    return s
  }

  // --- the boundary -----------------------------------------------------------

  function test_the_state_field_set_is_pinned() {
    var want = Balls.STATE_KEYS.slice().sort().join(",")
    function keysOf(o) { var k = []; for (var n in o) k.push(n); return k.sort().join(",") }
    compare(keysOf(Balls.emptyState()), want, "emptyState")
    compare(keysOf(Balls.fromSave(undefined, t0, gen)), want, "absent")
    compare(keysOf(Balls.fromSave(full({}), t0, gen)), want, "valid")
  }

  // Every save on disk today has no balls field. That is migration, not corruption.
  function test_an_absent_field_is_normal_migration() {
    var s = Balls.fromSave(undefined, t0, gen)
    compare(s.pending, true)
    compare(s.items.length, 0, "it cannot place without workspace data")
    compare(s.scatteredAt, null, "and must not stamp a boot-clock timestamp")
  }

  // fromSave is a TOTAL function: it is called outside the biography try, so it may never
  // throw for any input at all.
  function test_it_never_throws_for_any_input() {
    var hostile = [null, 0, "", "nope", [], {}, { items: "no" }, { items: [1, 2] },
                   { v: 2 }, { items: items(), scatteredAt: "soon" },
                   { items: [null, null, null, null, null, null, null] }]
    for (var i = 0; i < hostile.length; i++) {
      var s = Balls.fromSave(hostile[i], t0, gen)
      verify(s !== null && typeof s === "object", "case " + i)
      verify(s.items.length === 0 || s.items.length === 7, "case " + i + " canonical")
    }
  }

  // --- the three subtrees degrade independently -------------------------------

  function test_a_broken_hunt_does_not_delete_a_valid_wish() {
    var s = Balls.fromSave({ v: 1, scatteredAt: t0, items: "garbage",
                             wish: { kind: "care_ceiling", grantedAt: t0,
                                     expiresAt: t0 + 86400000 },
                             keepsake: gen, summon: null }, t0 + 1000, gen)
    compare(s.pending, true, "the hunt is discarded")
    verify(s.wish !== null, "but the wish survives")
    compare(s.keepsake, gen, "and so does the keepsake")
  }

  function test_a_broken_wish_does_not_scatter_a_valid_hunt() {
    var s = Balls.fromSave(full({ wish: { kind: "immortality", grantedAt: t0 } }), t0, gen)
    compare(s.items.length, 7, "the hunt survives")
    compare(s.pending, false)
    compare(s.wish, null, "only the wish is dropped")
  }

  function test_the_wish_kind_is_allowlisted_and_its_duration_exact() {
    var bad = [
      { kind: "care_ceiling", grantedAt: t0, expiresAt: t0 + 86400001 },
      { kind: "care_ceiling", grantedAt: "0", expiresAt: 86400000 },
      { kind: "full_recovery", grantedAt: t0, expiresAt: t0 + 86400000 },
      { kind: "care_ceiling", grantedAt: -1, expiresAt: 86399999 }
    ]
    for (var i = 0; i < bad.length; i++)
      compare(Balls.fromSave(full({ wish: bad[i] }), t0, gen).wish, null, "wish " + i)
    var ok = { kind: "care_ceiling", grantedAt: t0, expiresAt: t0 + 86400000 }
    verify(Balls.fromSave(full({ wish: ok }), t0, gen).wish !== null)
  }

  // A keepsake for another generation is corruption scheduling decor for a pet that does
  // not exist yet.
  function test_a_keepsake_belongs_to_exactly_this_generation() {
    compare(Balls.fromSave(full({ keepsake: gen }), t0, gen).keepsake, gen)
    compare(Balls.fromSave(full({ keepsake: gen + 1 }), t0, gen).keepsake, null)
    compare(Balls.fromSave(full({ keepsake: "3" }), t0, gen).keepsake, null)
  }

  // A summon belonging to a hunt that no longer exists would restore a menu nobody earned.
  function test_a_summon_must_belong_to_this_hunt() {
    var good = Balls.fromSave(full({ summon: { hunt: t0, notified: false } }), t0, gen)
    verify(good.summon !== null)
    var bad = Balls.fromSave(full({ summon: { hunt: t0 - 5, notified: false } }), t0, gen)
    compare(bad.summon, null)
    compare(Balls.fromSave(full({ summon: { hunt: t0, notified: "yes" } }), t0, gen).summon,
            null, "notified must be a strict boolean")
  }

  // A valid summon outranks a broken hunt, or a corrupt items array would start a fresh
  // week underneath a Shenron the pet genuinely earned.
  function test_a_valid_summon_suppresses_hunt_repair() {
    var s = Balls.fromSave({ v: 1, scatteredAt: t0, items: "garbage", wish: null,
                             keepsake: null, summon: { hunt: t0, notified: true } },
                           t0 + 1000, gen)
    verify(s.summon !== null, "the summon survives")
    compare(s.suppressed, true, "and repair is suspended while it stands")
  }

  // --- structural validation carries no wall-clock bound ----------------------

  function test_a_future_timestamp_is_preserved_not_erased() {
    // The desktop's clock is wrong for the first minute after every boot, which is exactly
    // when the shell starts. Rejecting these would delete a real week-long hunt.
    var s = Balls.fromSave(full({ scatteredAt: t0 + 900000 }), t0, gen)
    compare(s.scatteredAt, t0 + 900000, "kept verbatim")
    compare(s.items.length, 7, "and the hunt is not discarded")
    compare(Balls.findableCount(s, t0), 0, "it is merely ineligible until the clock settles")
  }

  function test_a_future_granted_wish_is_suppressed_not_cancelled() {
    var w = { kind: "care_ceiling", grantedAt: t0 + 600000, expiresAt: t0 + 600000 + 86400000 }
    var s = Balls.fromSave(full({ wish: w }), t0, gen)
    verify(s.wish !== null, "the record is left alone")
    compare(Balls.wishCeiling(s, t0), null, "but it does not apply yet")
    compare(Balls.wishCeiling(s, t0 + 700000), 3, "and applies once the clock passes it")
  }

  function test_scattered_at_is_bounded_for_six_safe_day_additions() {
    var huge = 9007199254740991 - 1000
    compare(Balls.fromSave(full({ scatteredAt: huge }), t0, gen).pending, true)
  }

  // --- the hunt ---------------------------------------------------------------

  function test_ball_i_becomes_findable_on_day_i() {
    var s = Balls.fromSave(full({}), t0, gen)
    compare(Balls.findableCount(s, t0), 1, "ball 0 is findable immediately")
    compare(Balls.findableCount(s, t0 + 86400000 - 1), 1)
    compare(Balls.findableCount(s, t0 + 86400000), 2)
    compare(Balls.findableCount(s, t0 + 6 * 86400000), 7, "the hunt spans six days")
    compare(Balls.findableCount(s, t0 + 99 * 86400000), 7, "and stops at seven")
  }

  function test_relocation_needs_48_unseen_hours_and_never_the_active_workspace() {
    var s = Balls.fromSave(full({}), t0, gen)
    var later = t0 + 49 * 3600000
    // ball 0 is on ws 1. With ws 1 ACTIVE it must never relocate, whatever the timestamps.
    var kept = Balls.relocate(s, later, 1, [1, 2, 3])
    compare(kept.items[0].ws, 1, "a ball in plain view never relocates")
    var moved = Balls.relocate(s, later, 2, [1, 2, 3])
    compare(moved.items[0].ws, 2, "unseen for 48h, it moves to the active workspace")
    compare(moved.items[0].lastSeenAt, later, "and its stamps are set together")
    compare(moved.items[0].placedAt, later)
  }

  function test_relocation_skips_collected_and_unfindable_balls() {
    var s = Balls.fromSave(full({}), t0, gen)
    s = Balls.collectAt(s, 0, t0)
    var later = t0 + 49 * 3600000
    var r = Balls.relocate(s, later, 2, [1, 2, 3])
    compare(r.items[0].ws, 1, "a collected ball stays put")
    compare(r.items[6].ws, s.items[6].ws, "and one that is not findable yet is not moved")
  }

  function test_no_eligible_workspace_leaves_state_untouched() {
    var s = Balls.fromSave(full({}), t0, gen)
    var r = Balls.relocate(s, t0 + 49 * 3600000, -1, [])
    compare(r.items[0].ws, s.items[0].ws, "guessing would be worse than waiting")
  }

  function test_placement_spreads_across_the_workspace_set() {
    var s = Balls.place(Balls.emptyState(), t0, [1, 2, 3, 4, 5, 6, 7], function () { return 0 })
    compare(s.items.length, 7)
    compare(s.pending, false)
    compare(s.scatteredAt, t0)
    var seen = {}
    for (var i = 0; i < 7; i++) seen[s.items[i].ws] = true
    var n = 0; for (var k in seen) n++
    compare(n, 7, "seven workspaces, seven different homes")
    for (var j = 0; j < 7; j++) {
      verify(s.items[j].x >= 0 && s.items[j].x <= 1, "x is a normalised centre")
    }
  }

  function test_placement_repeats_only_when_there_are_too_few_workspaces() {
    var s = Balls.place(Balls.emptyState(), t0, [1, 2], function () { return 0 })
    compare(s.items.length, 7)
    for (var i = 0; i < 7; i++) verify(s.items[i].ws === 1 || s.items[i].ws === 2)
  }

  // --- collection, summon, wishes ---------------------------------------------

  function test_collection_is_idempotent_per_index() {
    var s = Balls.fromSave(full({}), t0, gen)
    s = Balls.collectAt(s, 0, t0)
    compare(s.items[0].collected, true)
    var again = Balls.collectAt(s, 0, t0)
    compare(Balls.collectedCount(again), 1, "recollecting the same ball changes nothing")
  }

  function test_the_target_is_the_lowest_findable_ball_on_the_active_workspace() {
    var s = Balls.fromSave(full({}), t0 + 6 * 86400000, gen)
    // items 0,3,6 are on ws 1; 1,4 on ws 2; 2,5 on ws 3.
    compare(Balls.targetIndex(s, 2, t0 + 6 * 86400000), 1,
            "a lower-index ball on another workspace must not block this one")
    s = Balls.collectAt(s, 1, t0 + 6 * 86400000)
    compare(Balls.targetIndex(s, 2, t0 + 6 * 86400000), 4)
    compare(Balls.targetIndex(s, 9, t0 + 6 * 86400000), -1, "nothing here")
  }

  function test_shenron_needs_all_seven_and_dusk() {
    var s = Balls.fromSave(full({}), t0, gen)
    for (var i = 0; i < 6; i++) s = Balls.collectAt(s, i, t0)
    compare(Balls.canSummon(s, 19), false, "six is not seven")
    s = Balls.collectAt(s, 6, t0)
    compare(Balls.canSummon(s, 19), true)
    compare(Balls.canSummon(s, 12), false, "and only at dusk")
    s = Balls.recordSummon(s, t0)
    compare(Balls.canSummon(s, 19), false, "one summon per hunt, latched")
  }

  function test_full_recovery_and_keepsake_persist_correctly() {
    var s = Balls.fromSave(full({}), t0, gen)
    var rec = Balls.applyWish(s, "full_recovery", t0, gen)
    compare(rec.wish, null, "an instantaneous wish persists nothing")
    compare(rec.pending, true, "and the balls scatter")
    var keep = Balls.applyWish(s, "keepsake", t0, gen)
    compare(keep.keepsake, gen)
    var ceil = Balls.applyWish(s, "care_ceiling", t0, gen)
    compare(ceil.wish.expiresAt, t0 + 86400000)
    compare(Balls.wishCeiling(ceil, t0 + 1000), 3)
    compare(Balls.wishCeiling(ceil, t0 + 86400001), null, "and it lapses")
  }

  function test_an_unknown_wish_changes_nothing() {
    var s = Balls.fromSave(full({}), t0, gen)
    var r = Balls.applyWish(s, "immortality", t0, gen)
    compare(r.pending, false, "the hunt is not spent on a wish that does not exist")
    compare(r.wish, null)
  }

  // --- what gets written back --------------------------------------------------

  function test_pending_persists_the_wish_and_keepsake_but_no_items() {
    var s = Balls.applyWish(Balls.fromSave(full({}), t0, gen), "care_ceiling", t0, gen)
    var out = Balls.toSave(s)
    compare(out.items, undefined, "no half-built hunt on disk")
    compare(out.scatteredAt, undefined)
    verify(out.wish !== undefined && out.wish !== null,
           "but an earned wish is never discarded by a pending hunt")
  }
}
