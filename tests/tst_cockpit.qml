import QtQuick
import QtTest
import "../cockpit.js" as Cockpit

// The Cockpit state document is the ONE off-machine feed. Everything here is about not
// rendering a number the machine is not currently at: two same-clock freshness detectors,
// a stall detector that fails closed on cold start, and per-source status gating.
TestCase {
  name: "Cockpit"

  readonly property real now: 1788304400

  function doc(over) {
    var d = {
      schema_version: 1, generated_at: 1788304380,
      collector: { host: "workstation", stale_source_limit: 7200 },
      sources: {
        gpu: { status: "ok", last_ok: 1788304380,
               data: { state: "generating", power_w: 187.4 } },
        agents: { status: "ok", last_ok: 1788304380,
                  data: { total: 6, sessions: [] } }
      }
    }
    for (var k in over) d[k] = over[k]
    return d
  }
  function wrap(over, inner) {
    var w = { schema_version: 1, fetched_at: now - 5, source: "aggregator",
              doc: inner === undefined ? doc({}) : inner }
    for (var k in over) w[k] = over[k]
    return JSON.stringify(w)
  }
  // Two reads with an advancing generated_at: the only way to become trusted.
  function trusted() {
    var s = Cockpit.parse(wrap({}, doc({ generated_at: 1788304000 })), undefined, now - 60, null)
    return Cockpit.parse(wrap({}), undefined, now, s)
  }

  function test_the_snapshot_field_set_is_pinned() {
    var want = Cockpit.SNAPSHOT_KEYS.slice().sort().join(",")
    function keysOf(o) { var k = []; for (var n in o) k.push(n); return k.sort().join(",") }
    compare(keysOf(Cockpit.emptyState()), want, "emptyState")
    compare(keysOf(Cockpit.parse("", undefined, now, null)), want, "empty read")
    compare(keysOf(trusted()), want, "ok read")
  }

  function test_an_empty_read_renders_nothing() {
    compare(Cockpit.parse("", undefined, now, null).status, "empty")
    compare(Cockpit.parse(null, undefined, now, null).status, "empty")
  }

  function test_oversize_and_unparseable_are_malformed() {
    compare(Cockpit.parse(wrap({}), 65537, now, null).status, "malformed")
    compare(Cockpit.parse("{nope", undefined, now, null).status, "malformed")
  }

  function test_outer_schema_and_fetched_at_are_validated() {
    compare(Cockpit.parse(wrap({ schema_version: 2 }), undefined, now, null).status, "malformed")
    compare(Cockpit.parse(wrap({ fetched_at: "soon" }), undefined, now, null).status, "malformed")
    compare(Cockpit.parse(wrap({ fetched_at: now + 121 }), undefined, now, null).status, "malformed")
  }

  // An UNKNOWN source is not a degraded one -- but degraded must stay REACHABLE.
  function test_the_source_allowlist_keeps_degraded_reachable() {
    compare(Cockpit.parse(wrap({ source: "who-knows" }), undefined, now, null).status, "malformed")
    var d = Cockpit.parse(wrap({ source: "degraded", doc: null }), undefined, now, null)
    compare(d.status, "degraded")
    compare(d.gpu, null, "a degraded read may be said in words, never as a power reading")
  }

  function test_a_dead_fetcher_reads_grey() {
    compare(Cockpit.parse(wrap({ fetched_at: now - 91 }), undefined, now, null).status, "grey")
    compare(Cockpit.parse(wrap({ fetched_at: now - 89 }), undefined, now, null).status !== "grey",
            true)
  }

  function test_inner_schema_and_limits_are_validated() {
    compare(Cockpit.parse(wrap({}, doc({ schema_version: 9 })), undefined, now, null).status,
            "malformed")
    compare(Cockpit.parse(wrap({}, doc({ generated_at: -1 })), undefined, now, null).status,
            "malformed")
    var bad = doc({}); bad.collector = { stale_source_limit: Infinity }
    compare(Cockpit.parse(wrap({}, bad), undefined, now, null).status, "malformed")
    var bad2 = doc({}); bad2.collector = { stale_source_limit: 86401 }
    compare(Cockpit.parse(wrap({}, bad2), undefined, now, null).status, "malformed")
  }

  function test_cold_start_fails_closed() {
    var s = Cockpit.parse(wrap({}), undefined, now, null)
    compare(s.trusted, false, "a first read can never be dated")
    compare(s.gpu, null, "and therefore renders no measurement")
  }

  function test_trust_arrives_only_on_a_strict_advance() {
    var s = trusted()
    compare(s.trusted, true)
    compare(s.gpu.powerW, 187.4)
    compare(s.gpu.state, "generating")
    compare(s.fleet.agents, 6)
  }

  function test_a_frozen_collector_stalls_after_300s() {
    var s = trusted()
    // fetched_at keeps advancing (the fetcher is alive) but generated_at does not.
    var later = Cockpit.parse(wrap({ fetched_at: now + 200 }), undefined, now + 200, s)
    compare(later.status, "ok", "still inside the stall window")
    var stalled = Cockpit.parse(wrap({ fetched_at: now + 400 }), undefined, now + 400, later)
    compare(stalled.status, "stalled")
    compare(stalled.gpu, null, "a stalled document renders no measurement")
  }

  function test_an_outage_does_not_buy_a_second_grace_period() {
    var s = trusted()
    var blip = Cockpit.parse("{corrupt", undefined, now + 100, s)
    compare(blip.lastGen, s.lastGen, "the trusted generation survives an outage")
    compare(blip.lastGenSeenAt, s.lastGenSeenAt, "and so does its local stamp")
    var stalled = Cockpit.parse(wrap({ fetched_at: now + 400 }), undefined, now + 400, blip)
    compare(stalled.status, "stalled", "the 300s clock was not reset by the blip")
  }

  function test_a_rollback_starts_a_new_untrusted_epoch() {
    var s = trusted()
    var back = Cockpit.parse(wrap({}, doc({ generated_at: 1788303000 })), undefined, now + 10, s)
    compare(back.trusted, false, "a clock correction must re-earn trust")
    compare(back.gpu, null)
    compare(back.lastGen, 1788303000, "and re-baseline silently rather than mute forever")
    var fwd = Cockpit.parse(wrap({}, doc({ generated_at: 1788303001 })), undefined, now + 20, back)
    compare(fwd.trusted, true, "one strict advance restores it")
  }

  function test_an_errored_source_is_unusable_despite_a_plausible_payload() {
    var s = trusted()
    var d = doc({})
    d.sources.gpu = { status: "error", last_ok: 1788304380,
                      data: { state: "generating", power_w: 999 } }
    var r = Cockpit.parse(wrap({}, d), undefined, now + 10, s)
    compare(r.status, "ok", "the document itself is fine")
    compare(r.gpu, null, "but last week's wattage is not a reading")
  }

  function test_source_age_uses_within_document_timestamps() {
    var s = trusted()
    var d = doc({ generated_at: 1788304390 })
    d.sources.gpu.last_ok = 1788304390 - 7201
    compare(Cockpit.parse(wrap({}, d), undefined, now + 10, s).gpu, null)
  }

  function test_a_null_last_ok_fails_closed() {
    var s = trusted()
    var d = doc({})
    d.sources.gpu.last_ok = null
    compare(Cockpit.parse(wrap({}, d), undefined, now + 10, s).gpu, null)
    var d2 = doc({})
    delete d2.sources.gpu.last_ok
    compare(Cockpit.parse(wrap({}, d2), undefined, now + 10, s).gpu, null,
            "NaN comparisons must not fail open")
  }

  function test_power_w_is_bounded_and_finite() {
    var s = trusted()
    var bad = [-1, 2001, "187", null, Infinity]
    for (var i = 0; i < bad.length; i++) {
      var d = doc({})
      d.sources.gpu.data.power_w = bad[i]
      compare(Cockpit.parse(wrap({}, d), undefined, now + 10, s).gpu, null, "power_w " + bad[i])
    }
  }

  function test_gpu_state_is_allowlisted() {
    var s = trusted()
    var d = doc({})
    d.sources.gpu.data.state = "melting"
    compare(Cockpit.parse(wrap({}, d), undefined, now + 10, s).gpu.state, "unknown",
            "an unrecognised state is unknown, never 'some other state'")
  }

  function test_agent_total_is_a_bounded_integer() {
    var s = trusted()
    var bad = [-1, 1001, 2.5, "6", null]
    for (var i = 0; i < bad.length; i++) {
      var d = doc({})
      d.sources.agents.data.total = bad[i]
      compare(Cockpit.parse(wrap({}, d), undefined, now + 10, s).fleet, null, "total " + bad[i])
    }
  }

  function test_sessions_must_be_an_array_to_be_used() {
    var s = trusted()
    var d = doc({})
    d.sources.agents.data.sessions = { error: "docker exec timed out" }
    var r = Cockpit.parse(wrap({}, d), undefined, now + 10, s)
    compare(r.fleet.agents, 6, "total still works; the fleet signal never reads sessions")
    compare(r.fleet.sessions, null, "and the non-array is refused rather than indexed")
  }

  function test_a_missing_gpu_source_renders_nothing_not_a_placeholder() {
    var s = trusted()
    var d = doc({})
    delete d.sources.gpu
    compare(Cockpit.parse(wrap({}, d), undefined, now + 10, s).gpu, null)
  }
}
