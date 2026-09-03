import QtQuick
import QtTest
import "../scouter.js" as Scouter

// Reading one process and saying so honestly. The parse trap is measured, not theoretical:
// pid 338317 on the live desktop is named "npm exec @playw", and a naive whitespace split
// reports 7.1 GB for a 22 MB process.
TestCase {
  name: "Scouter"

  // Fields AFTER the close paren: state 0, utime 11, stime 12, starttime 19, rss 21.
  function stat(comm, state, starttime, rssPages) {
    var f = []
    for (var i = 0; i < 24; i++) f.push("0")
    f[0] = state
    f[19] = String(starttime)
    f[21] = String(rssPages)
    return "1234 (" + comm + ") " + f.join(" ") + "\n"
  }

  function test_a_normal_line_parses() {
    var r = Scouter.parseStat(stat("ghostty", "S", 99887, 40000), 1234, 4)
    compare(r.status, "ok")
    compare(r.starttime, 99887)
    compare(r.rssKb, 160000)
  }

  // THE trap: a comm with both a space AND a close paren must not shift the fields.
  function test_a_comm_with_a_space_and_a_paren_does_not_shift_the_fields() {
    var r = Scouter.parseStat(stat("npm exec @playw)", "S", 55555, 5500), 1234, 4)
    compare(r.status, "ok", "split after the LAST close paren")
    compare(r.starttime, 55555)
    compare(r.rssKb, 22000, "not the seven-gigabyte lie a naive split produces")
  }

  // Zombies parse cleanly with rss 0, so "did it parse" is not a sufficient check.
  function test_a_zombie_yields_no_number() {
    compare(Scouter.parseStat(stat("uwsm-app", "Z", 4242, 0), 1234, 4).rssKb, null)
    compare(Scouter.parseStat(stat("uwsm-app", "X", 4242, 100), 1234, 4).rssKb, null)
  }

  function test_zero_rss_is_never_bp_zero() {
    compare(Scouter.parseStat(stat("ghostty", "S", 1, 0), 1234, 4).rssKb, null)
  }

  function test_a_pid_mismatch_is_refused() {
    compare(Scouter.parseStat(stat("ghostty", "S", 1, 4000), 9999, 4).status, "error",
            "a recycled pid must not inherit the old reading")
  }

  function test_malformed_input_is_error_not_a_guess() {
    var bad = ["", "no parens here", "1234 (unclosed S 1 2 3", null]
    for (var i = 0; i < bad.length; i++)
      compare(Scouter.parseStat(bad[i], 1234, 4).status, "error", "case " + i)
  }

  function test_pid_validation_bounds_the_path() {
    var bad = [0, -1, 4194305, 2.5, "1234", null, undefined]
    for (var i = 0; i < bad.length; i++)
      compare(Scouter.validPid(bad[i]), false, "pid " + bad[i])
    compare(Scouter.validPid(1), true)
    compare(Scouter.validPid(4194304), true)
  }

  function test_power_is_rss_over_64_snapped_by_magnitude() {
    compare(Scouter.power(576000), 9000, "576 MiB is a real over-9000")
    verify(Scouter.power(160000) >= 2000 && Scouter.power(160000) <= 2600)
    compare(Scouter.power(null), null)
  }

  function test_a_value_is_adopted_only_after_it_repeats() {
    var st = null
    var r = Scouter.adopt(st, 2500); st = r.state
    compare(r.value, null, "one sample is not a reading")
    r = Scouter.adopt(st, 2500); st = r.state
    compare(r.value, 2500, "twice in a row is")
    r = Scouter.adopt(st, 2600); st = r.state
    compare(r.value, 2500, "a single jitter does not move it")
  }

  function test_control_and_bidi_characters_are_stripped() {
    var raw = "ab" + String.fromCharCode(7) + String.fromCharCode(0x202E) + "c"
              + String.fromCharCode(10) + "d e"
    var s = Scouter.sanitize(raw)
    compare(s.indexOf(String.fromCharCode(7)), -1, "C0 control")
    compare(s.indexOf(String.fromCharCode(0x202E)), -1, "bidi override")
    compare(s.indexOf(String.fromCharCode(10)), -1, "newline")
  }

  // The toast renderer is outside this plugin's control, so PlainText does not protect it.
  function test_markup_metacharacters_are_neutralised() {
    var s = Scouter.sanitize('<img src="x"> & more')
    compare(s.indexOf("<"), -1)
    compare(s.indexOf(">"), -1)
    compare(s.indexOf("&"), -1)
  }

  function test_length_is_capped_by_code_point() {
    var long = ""
    for (var i = 0; i < 200; i++) long += "e"
    compare(Array.from(Scouter.sanitize(long)).length, 64)
  }

  function test_whitespace_collapses() {
    compare(Scouter.sanitize("a    b  c"), "a b c")
  }

  function test_the_label_never_claims_the_window() {
    var s = Scouter.label("Brave", 8400, "Secret Doc - Brave", true)
    verify(s.toLowerCase().indexOf("one process") >= 0, "must say one process: " + s)
    compare(s.toLowerCase().indexOf("window"), -1)
    compare(s.toLowerCase().indexOf(" app"), -1)
    compare(s.toLowerCase().indexOf("total"), -1)
  }

  function test_titles_off_omits_the_clause_entirely() {
    var off = Scouter.label("Brave", 8400, "Secret Doc - Brave", false)
    compare(off.indexOf("Secret Doc"), -1)
    compare(off.indexOf('""'), -1, "omitted, not blanked")
    verify(Scouter.label("Brave", 8400, "Secret Doc", true).indexOf("Secret Doc") >= 0)
  }
}
