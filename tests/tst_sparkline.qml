import QtQuick
import QtTest
import "../ki.js" as Ki

// 144 five-minute buckets, twelve hours. A bucket keeps THE COMPLETE max-power sample --
// never independent maxima, which could combine a power and a rung from different moments
// into a state that never existed. A bucket renders only once it closes; gaps stay gaps.
TestCase {
  name: "Sparkline"

  // An exact bucket boundary (divisible by 300000).
  readonly property real t0: 1788220800000

  function test_a_bucket_keeps_the_complete_max_power_sample() {
    var m = {}
    Ki.bucketUpsert(m, t0, 100, 0)
    Ki.bucketUpsert(m, t0 + 1000, 900, 2)
    Ki.bucketUpsert(m, t0 + 2000, 500, 3)
    var s = Ki.bucketSeries(m, t0 + 300000)
    var last = s[143]
    compare(last.power, 900)
    compare(last.rung, 2, "the rung travels with its own sample")
  }

  function test_series_covers_144_closed_buckets() {
    compare(Ki.bucketSeries({}, t0).length, 144)
  }

  function test_the_open_bucket_is_not_in_the_series() {
    var m = {}
    Ki.bucketUpsert(m, t0, 700, 1)
    var during = Ki.bucketSeries(m, t0 + 1000)
    compare(during[143], null, "a bucket renders only once it closes")
    var after = Ki.bucketSeries(m, t0 + 300000)
    compare(after[143].power, 700)
  }

  function test_empty_buckets_are_gaps_never_carried_forward() {
    var m = {}
    Ki.bucketUpsert(m, t0, 700, 1)
    var s = Ki.bucketSeries(m, t0 + 3 * 300000)
    compare(s[141].power, 700)
    compare(s[142], null)
    compare(s[143], null)
  }

  function test_null_power_never_enters_a_bucket() {
    var m = {}
    Ki.bucketUpsert(m, t0, null, 2)
    var s = Ki.bucketSeries(m, t0 + 300000)
    compare(s[143], null)
  }

  function test_old_buckets_are_pruned() {
    var m = {}
    Ki.bucketUpsert(m, t0, 700, 1)
    Ki.bucketUpsert(m, t0 + 200 * 300000, 100, 0)
    var keys = 0
    for (var k in m) keys++
    compare(keys, 1, "a bucket outside the 144 window is dropped")
  }
}
