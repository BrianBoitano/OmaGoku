import QtQuick
import QtTest
import "../probes.js" as Probes

// Parsing for the probe pack, pure. Every probe result carries a status, and unknown must
// remove the effect, so the parsers reject anything they do not fully understand rather
// than guessing a number.
TestCase {
  name: "Probes"

  // df --output=source,target,pcent: one header line, then one row per filesystem.
  readonly property string dfTwo:
    "Filesystem Mounted on Use%\n/dev/nvme0n1p2 / 42%\n/dev/sda1 /home 91%\n"
  readonly property string dfDup:
    "Filesystem Mounted on Use%\n/dev/nvme0n1p2 / 42%\n/dev/nvme0n1p2 /home 42%\n"

  function test_df_reports_the_worst_filesystem_with_its_mount() {
    var r = Probes.parseDf(dfTwo)
    compare(r.status, "ok")
    compare(r.worst.pcent, 91)
    compare(r.worst.target, "/home")
  }

  function test_df_dedupes_by_filesystem_identity() {
    // /home on the same device as / must not double-report the root filesystem.
    var r = Probes.parseDf(dfDup)
    compare(r.status, "ok")
    compare(r.worst.pcent, 42)
    compare(r.worst.target, "/")
  }

  function test_df_garbage_is_error_not_zero() {
    compare(Probes.parseDf("").status, "error")
    compare(Probes.parseDf("head -c: no such file").status, "error")
    compare(Probes.parseDf("Filesystem Mounted on Use%\n/dev/x / notapercent\n").status,
            "error")
  }

  function test_failed_units_counts_plain_rows() {
    var out = "foo.service loaded failed failed A broken thing\n" +
              "bar.timer loaded failed failed Another\n"
    var r = Probes.parseFailedUnits(out)
    compare(r.status, "ok")
    compare(r.count, 2)
    compare(Probes.parseFailedUnits("").status, "ok")
    compare(Probes.parseFailedUnits("").count, 0)
  }

  function test_failed_units_garbage_is_error() {
    compare(Probes.parseFailedUnits("!!!\n").status, "error")
  }

  function test_combined_count_needs_both_managers() {
    var okA = { status: "ok", count: 1 }
    var okB = { status: "ok", count: 2 }
    var bad = { status: "error", count: 0 }
    compare(Probes.combineFailed(okA, okB).status, "ok")
    compare(Probes.combineFailed(okA, okB).count, 3)
    // A half-known count displayed as complete would be a quiet lie.
    compare(Probes.combineFailed(okA, bad).status, "unknown")
    compare(Probes.combineFailed(bad, okB).status, "unknown")
    compare(Probes.combineFailed(null, okB).status, "unknown")
  }

  function test_a_probe_result_expires_on_ttl() {
    var probe = { status: "ok", sampledAtMs: 1000000 }
    compare(Probes.fresh(probe, 1000000 + 3599999, 3600000), true)
    compare(Probes.fresh(probe, 1000000 + 3600001, 3600000), false)
    compare(Probes.fresh(null, 5, 10), false)
  }
}
