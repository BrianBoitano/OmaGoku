import QtQuick
import QtTest
import "../localki.js" as Local

// The local ki producer. It exists so the pet can transform on a machine that does not run
// a separate ki daemon, and its whole risk is claiming a power level the machine is not at.
TestCase {
  name: "LocalKi"

  function stat(user, nice, sys, idle, iowait) {
    return "cpu  " + user + " " + nice + " " + sys + " " + idle + " " + iowait
         + " 0 0 0 0 0\ncpu0 1 2 3 4 5 0 0 0 0 0\nintr 12345\n"
  }

  function test_a_kernel_line_parses_into_total_and_idle() {
    var s = Local.parse(stat(100, 0, 50, 800, 50))
    compare(s.total, 1000)
    compare(s.idle, 850, "idle AND iowait are both idle")
  }

  function test_anything_that_is_not_proc_stat_is_null() {
    var bad = ["", "nope", "cpuX 1 2 3", null, 42, undefined,
               "cpu  a b c d e 0 0 0 0 0", "cpu  -1 0 0 0 0 0 0 0 0 0", "cpu  0 0 0 0 0"]
    for (var i = 0; i < bad.length; i++)
      compare(Local.parse(bad[i]), null, "input " + i + " must not parse")
  }

  // A tenth column in some future kernel must not change the arithmetic, because total is
  // the sum of everything rather than a fixed list.
  function test_extra_kernel_columns_do_not_shift_the_maths() {
    var s = Local.parse("cpu  100 0 50 800 50 0 0 0 0 0 7\n")
    compare(s.total, 1007)
    compare(s.idle, 850)
  }

  function test_the_first_sample_is_not_a_reading() {
    compare(Local.busyFraction(null, { total: 10, idle: 5 }), null)
    compare(Local.busyFraction(Local.emptySample(), { total: 10, idle: 5 }), null)
    var st = Local.state(null)
    compare(st.status, "warming", "one sample is not base, it is nothing yet")
    compare(st.form, "base")
    compare(st.power, null)
  }

  function test_busy_fraction_is_the_work_between_two_samples() {
    var a = { total: 1000, idle: 800 }
    var b = { total: 2000, idle: 1400 }
    compare(Local.busyFraction(a, b), 0.4, "400 of 1000 ticks were work")
  }

  // A counter going backwards is a reboot or a rollover. Reporting the difference would
  // show a spike the machine never had.
  function test_counters_going_backwards_are_refused() {
    compare(Local.busyFraction({ total: 2000, idle: 1400 }, { total: 1000, idle: 800 }), null)
    compare(Local.busyFraction({ total: 1000, idle: 900 }, { total: 2000, idle: 800 }), null)
    compare(Local.busyFraction({ total: 1000, idle: 800 }, { total: 1000, idle: 800 }), null,
            "no time passed, so nothing can be said")
  }

  function test_the_rungs_are_wide_enough_not_to_flicker() {
    compare(Local.formFor(0.0), "base")
    compare(Local.formFor(0.29), "base")
    compare(Local.formFor(0.30), "ssj")
    compare(Local.formFor(0.54), "ssj")
    compare(Local.formFor(0.55), "blue")
    compare(Local.formFor(0.79), "blue")
    compare(Local.formFor(0.80), "ui")
    compare(Local.formFor(1.0), "ui")
  }

  function test_an_unusable_fraction_reads_as_base_not_as_a_transformation() {
    var bad = [null, undefined, NaN, Infinity, "0.9"]
    for (var i = 0; i < bad.length; i++) {
      compare(Local.formFor(bad[i]), "base", "input " + i)
      compare(Local.powerFor(bad[i]), 0, "input " + i)
    }
  }

  function test_over_nine_thousand_means_the_machine_is_actually_working() {
    verify(Local.powerFor(0.40) < 9000, "a 40% busy machine is not over 9000")
    verify(Local.powerFor(0.42) > 9000, "a 42% busy machine is")
    compare(Local.powerFor(1.0), 22000)
    compare(Local.powerFor(0), 0)
  }

  // Rises quickly, falls slowly: a pet that drops out of Super Saiyan between keystrokes
  // is noise, not a power level.
  function test_smoothing_rises_faster_than_it_falls() {
    var up = Local.smooth(0.2, 1.0) - 0.2
    var down = 0.8 - Local.smooth(0.8, 0.0)
    verify(up > down, "ramps up harder than it calms down")
    compare(Local.smooth(null, 0.5), 0.5, "the first reading is taken as-is")
    compare(Local.smooth(NaN, 0.5), 0.5)
  }

  function test_the_snapshot_matches_the_producer_contract() {
    var st = Local.state(0.9)
    compare(st.status, "ok")
    compare(st.form, "ui")
    compare(st.power, 19800)
    compare(st.fraction, 0.9)
  }
}
