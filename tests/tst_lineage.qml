import QtQuick
import QtTest
import "../lineage.js" as Lin

// The lineage record. Its whole purpose is to survive resetPet(), so the one thing it must
// never do is prevent a pet from ending -- and the second thing is destroy the history it
// exists to keep.
TestCase {
  name: "Lineage"

  function liveCtx(over) {
    var c = {
      progressMode: "live",
      petId: "0123456789abcdef0123456789abcdef",
      gen: 3, line: "goku", curve: 1, endedBy: "farewell",
      stage: "adult", form: "adult_ace",
      bornAt: 1700000000000, endedAt: 1700009000000,
      xp: 54321, peakKiRung: 3, careAverage: 78,
      ballsCollected: 14, wishesGranted: 2
    }
    for (var k in over) c[k] = over[k]
    return c
  }

  function reader(status, text) {
    return { status: status, text: text === undefined ? "" : text,
             bytes: text === undefined ? 0 : text.length }
  }

  // --- the reader statuses ---------------------------------------------------

  // A permission failure arriving as an empty string and becoming a CREATABLE empty history
  // is the same destruction the read-only rule exists to prevent, through another door.
  function test_only_a_confirmed_not_found_is_creatable() {
    compare(Lin.load(reader("missing")).mode, "missing")
    compare(Lin.load(reader("ok", "")).mode, "missing", "an empty file is a fresh start")
    compare(Lin.load(reader("error")).mode, "corrupt", "a read failure is NOT an empty file")
    compare(Lin.load(reader("error", "")).mode, "corrupt")
  }

  function test_a_valid_record_loads() {
    var rec = { v: 1, entries: [] }
    var r = Lin.load(reader("ok", JSON.stringify(rec)))
    compare(r.mode, "valid")
    compare(r.record.entries.length, 0)
  }

  function test_a_corrupt_record_is_read_only() {
    var bad = ["{not json", "[]", "null", "3", JSON.stringify({ v: 99, entries: [] }),
               JSON.stringify({ v: 1, entries: "nope" })]
    for (var i = 0; i < bad.length; i++) {
      var r = Lin.load(reader("ok", bad[i]))
      compare(r.mode, "corrupt", "input " + i)
      compare(Lin.canWrite(r.mode), false, "a corrupt record must never be rewritten")
    }
    compare(Lin.canWrite("valid"), true)
    compare(Lin.canWrite("missing"), true)
  }

  function test_an_oversized_record_is_corrupt_without_being_parsed() {
    compare(Lin.load({ status: "ok", text: "", bytes: 999999 }).mode, "corrupt")
  }

  // --- the discriminated union ----------------------------------------------

  function test_a_live_ending_writes_a_full_entry() {
    var e = Lin.buildEntry(liveCtx({}))
    compare(e.progressMode, "live")
    compare(e.xp, 54321)
    compare(e.curve, 1)
    compare(e.peakKiRung, 3)
    compare(e.wishesGranted, 2)
    verify(Lin.validEntry(e))
  }

  // An absent field says "not recorded". A null field invites a chart to plot it as zero.
  function test_a_frozen_ending_writes_a_partial_entry_with_no_progression_fields() {
    var e = Lin.buildEntry(liveCtx({ progressMode: "frozen" }))
    compare(e.progressMode, "frozen")
    var forbidden = ["curve", "xp", "peakKiRung", "careAverage",
                     "ballsCollected", "wishesGranted"]
    for (var i = 0; i < forbidden.length; i++)
      verify(!(forbidden[i] in e), forbidden[i] + " must be ABSENT, not null")
    compare(e.petId, "0123456789abcdef0123456789abcdef")
    compare(e.stage, "adult")
    verify(Lin.validEntry(e))
  }

  function test_each_shape_rejects_the_other() {
    var full = Lin.buildEntry(liveCtx({}))
    var partial = Lin.buildEntry(liveCtx({ progressMode: "corrupt" }))
    var mixed = {}
    for (var k in partial) mixed[k] = partial[k]
    mixed.xp = 5
    verify(!Lin.validEntry(mixed), "a partial entry carrying xp is incoherent")
    var stripped = {}
    for (var j in full) if (j !== "xp") stripped[j] = full[j]
    verify(!Lin.validEntry(stripped), "a live entry missing xp is incoherent")
  }

  // --- when NOT to write a row ----------------------------------------------

  function test_an_unclaimed_pod_is_never_recorded() {
    compare(Lin.buildEntry(liveCtx({ progressMode: "absent", line: "" })), null)
    compare(Lin.buildEntry(liveCtx({ progressMode: "absent" })), null)
  }

  // Minting a fallback id would defeat the upsert: a crash after the write and before the
  // reset mints a different id on retry and appends a second ending for the same pet.
  function test_a_partial_ending_with_no_stable_id_writes_nothing() {
    compare(Lin.buildEntry(liveCtx({ progressMode: "corrupt", petId: null })), null)
    compare(Lin.buildEntry(liveCtx({ progressMode: "corrupt", petId: "short" })), null)
  }

  function test_an_unknown_line_or_ending_is_refused() {
    compare(Lin.buildEntry(liveCtx({ line: "trunks" })), null)
    compare(Lin.buildEntry(liveCtx({ endedBy: "murdered" })), null)
    compare(Lin.buildEntry(liveCtx({ stage: "elderly" })), null)
    compare(Lin.buildEntry(liveCtx({ form: "../../etc/passwd" })), null)
  }

  function test_an_untrusted_clock_records_an_honest_null() {
    var e = Lin.buildEntry(liveCtx({ bornAt: null, endedAt: null }))
    compare(e.bornAt, null)
    compare(e.endedAt, null)
    verify(Lin.validEntry(e))
  }

  // --- the upsert ------------------------------------------------------------

  function test_the_same_pet_ending_twice_is_one_row() {
    var rec = Lin.emptyRecord()
    var e = Lin.buildEntry(liveCtx({}))
    rec = Lin.upsert(rec, e)
    rec = Lin.upsert(rec, e)
    compare(rec.entries.length, 1, "a crash between the write and the reset must not double")
  }

  function test_a_later_ending_for_the_same_pet_replaces_the_row() {
    var rec = Lin.emptyRecord()
    rec = Lin.upsert(rec, Lin.buildEntry(liveCtx({ xp: 10 })))
    rec = Lin.upsert(rec, Lin.buildEntry(liveCtx({ xp: 99 })))
    compare(rec.entries.length, 1)
    compare(rec.entries[0].xp, 99)
  }

  function test_the_record_is_capped_at_one_hundred_oldest_first() {
    var rec = Lin.emptyRecord()
    for (var i = 0; i < 130; i++) {
      var id = ("0000000" + i).slice(-7) + "89abcdef0123456789abcdef0"
      rec = Lin.upsert(rec, Lin.buildEntry(liveCtx({ petId: id, gen: i })))
    }
    compare(rec.entries.length, Lin.MAX_ENTRIES)
    compare(rec.entries[0].gen, 30, "the oldest thirty were dropped")
    compare(rec.entries[rec.entries.length - 1].gen, 129)
  }

  // --- hostile input ---------------------------------------------------------

  // A row this build cannot read is NOT dropped and NOT written over: the record goes
  // READ-ONLY and the bytes on disk are left exactly as they are. Dropping them was the
  // shipped behaviour, and because the writer serialises the record it LOADED, the next
  // ending destroyed them permanently. A value that has been through JSON.parse cannot be
  // re-emitted byte-identically either -- 9007199254740993 comes back as ...992 -- so not
  // writing the file is the only honest form of "preserved".
  function test_a_row_we_cannot_read_makes_the_record_read_only() {
    var rec = { v: 1, entries: [
      null, 3, "x", [], {},
      { progressMode: "live", petId: "zz", gen: 1 },
      { progressMode: "live", petId: "0123456789abcdef0123456789abcdef", gen: 1,
        line: "goku", curve: 1, endedBy: "farewell", stage: "adult", form: "adult_ace",
        bornAt: null, endedAt: null, xp: 1, peakKiRung: 0, careAverage: null,
        ballsCollected: 0, wishesGranted: 0 }
    ] }
    var r = Lin.load(reader("ok", JSON.stringify(rec)))
    compare(r.mode, "partial")
    compare(Lin.canWrite(r.mode), false, "no ending may overwrite a record with unread rows")
    compare(r.record.entries.length, 1, "the readable row is still shown")
    compare(r.unreadableRows, 6, "and the rest are counted, not silently gone")
  }

  function test_a_record_whose_rows_all_parse_stays_writable() {
    var rec = { v: 1, entries: [
      { progressMode: "live", petId: "0123456789abcdef0123456789abcdef", gen: 1,
        line: "goku", curve: 1, endedBy: "farewell", stage: "adult", form: "adult_ace",
        bornAt: null, endedAt: null, xp: 1, peakKiRung: 0, careAverage: null,
        ballsCollected: 0, wishesGranted: 0 }
    ] }
    var r = Lin.load(reader("ok", JSON.stringify(rec)))
    compare(r.mode, "valid")
    compare(r.unreadableRows, 0)
    compare(r.droppedByCap, 0)
  }

  // The cap runs on the RAW array, before validation. Validating first and capping the
  // survivors gives 100 readable rows PLUS an unreadable one against a cap of 100 -- 101
  // retained -- and counts an unreadable row the cap should already have evicted.
  function test_the_cap_is_applied_before_validation() {
    var entries = []
    for (var i = 0; i < 100; i++)
      entries.push({ progressMode: "live",
        petId: ("00000000000000000000000000000000" + i).slice(-32),
        gen: i + 1, line: "goku", curve: 1, endedBy: "farewell", stage: "adult",
        form: "adult_ace", bornAt: null, endedAt: null, xp: 1, peakKiRung: 0,
        careAverage: 50, ballsCollected: 0, wishesGranted: 0 })
    entries.push("junk")
    var r = Lin.load(reader("ok", JSON.stringify({ v: 1, entries: entries })))
    compare(r.droppedByCap, 1, "the oldest row is evicted by the cap, not by validation")
    compare(r.record.entries.length, 99)
    compare(r.unreadableRows, 1)
    compare(r.record.entries.length + r.unreadableRows, Lin.MAX_ENTRIES,
            "never more than MAX_ENTRIES positions are retained")
  }

  // Every write gate in this file is an allowlist, so a mode nobody anticipated is refused
  // by default. canWipe is the one that may act on an unwritable record, and it must still
  // refuse `corrupt`: a file we cannot read at all may be all that is left.
  function test_canWipe_is_an_allowlist() {
    compare(Lin.canWipe("valid"), true)
    compare(Lin.canWipe("missing"), true)
    compare(Lin.canWipe("partial"), true, "the escape hatch out of read-only")
    compare(Lin.canWipe("write-failed"), true, "our write failing is not evidence the file matters")
    compare(Lin.canWipe("corrupt"), false)
    compare(Lin.canWipe("something-new"), false)
    compare(Lin.canWipe(undefined), false)
  }

  // --- defects found by the Phase 2 recon, in code shipped 2026-09-02 ----------

  // The writer drops from the FRONT (upsert's shift), so the array is oldest-first. The
  // loader scanned FORWARD and stopped at 100, which keeps the OLDEST hundred and silently
  // discards the newest -- the generations a person actually remembers.
  function test_an_oversized_record_keeps_the_NEWEST_hundred() {
    var entries = []
    for (var i = 0; i < 150; i++) {
      var id = ("0000000" + i).slice(-7) + "89abcdef0123456789abcdef0"
      entries.push(Lin.buildEntry(liveCtx({ petId: id, gen: i })))
    }
    var r = Lin.load(reader("ok", JSON.stringify({ v: 1, entries: entries })))
    compare(r.mode, "valid")
    compare(r.record.entries.length, Lin.MAX_ENTRIES)
    compare(r.record.entries[0].gen, 50, "the oldest fifty are the ones dropped")
    compare(r.record.entries[r.record.entries.length - 1].gen, 149,
            "the newest ending must survive a reload")
  }

  // Written through safeInt(c.peakKiRung, 3) but validated on read against 1e8, so a
  // hand-edited file could carry rung 500 -- and Lines.rungLabel maps anything out of range
  // to the LOWEST rung, so it would render as "Base" rather than as unknown.
  function test_an_out_of_range_rung_is_refused_on_read() {
    var e = Lin.buildEntry(liveCtx({}))
    e.peakKiRung = 500
    verify(!Lin.validEntry(e), "a rung index above the ladder is not a rung")
    e.peakKiRung = 3
    verify(Lin.validEntry(e))
  }

  // The pet save preflights its size and refuses; the lineage write had no guard at all, so
  // a full record plus one more field is a silent one-way trip to a permanently unreadable
  // file -- the stat probe marks anything over the cap corrupt, and corrupt is read-only.
  function test_the_record_is_trimmed_to_fit_the_byte_cap() {
    var rec = Lin.emptyRecord()
    for (var i = 0; i < 100; i++) {
      var id = ("0000000" + i).slice(-7) + "89abcdef0123456789abcdef0"
      rec = Lin.upsert(rec, Lin.buildEntry(liveCtx({ petId: id, gen: i })))
    }
    var tiny = Lin.fit(rec, 2000)
    verify(tiny.entries.length < rec.entries.length, "it drops entries to fit")
    verify(Lin.byteLength(Lin.toText(tiny)) < 2000, "and the result actually fits")
    compare(tiny.entries[tiny.entries.length - 1].gen, 99, "dropping from the OLDEST end")

    var roomy = Lin.fit(rec, 65536)
    compare(roomy.entries.length, rec.entries.length, "a record that fits is untouched")
  }

  // A record that cannot be trimmed small enough must refuse rather than write a file the
  // reader will reject forever.
  function test_a_record_that_cannot_fit_at_all_refuses() {
    var rec = Lin.upsert(Lin.emptyRecord(), Lin.buildEntry(liveCtx({})))
    compare(Lin.fit(rec, 50), null, "no honest trim exists, so there is no record to write")
  }

  function test_byteLength_counts_utf8_not_characters() {
    compare(Lin.byteLength("abc"), 3)
    compare(Lin.byteLength("\u6c17"), 3)
    compare(Lin.byteLength("\ud83d\ude00"), 4)
  }

  function test_the_line_must_be_one_of_the_known_families() {
    var e = Lin.buildEntry(liveCtx({ line: "goku" }))
    verify(e.line.length <= 32)
    var r = Lin.load(reader("ok", JSON.stringify({ v: 1, entries: [
      { progressMode: "frozen", petId: "0123456789abcdef0123456789abcdef",
        gen: 1, line: "g".repeat(500), endedBy: "reset",
        stage: "adult", form: "adult_ace", bornAt: null, endedAt: null }
    ] })))
    compare(r.record.entries.length, 0, "an over-long line id is not a known line")
  }
}
