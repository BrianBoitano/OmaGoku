import QtQuick
import QtTest
import "../display.js" as Display
import "../lines.js" as Lines

// The ONE resolver every surface consumes. displayForm, displayIndex, aura and kiExplain
// can never diverge again, and the machine-truth fields ride along untouched by costume.
TestCase {
  name: "Display"

  function base(over) {
    var p = {
      line: "goku", stage: "adult", form: "adult_ace",
      kiForm: "base", kiStatus: "ok",
      careAverage: 100, happiness: 100, careCount: 10,
      moonActive: false,
      // Phase 1: the resolver argument is built ONLY by Display.inputs(), and it always
      // carries these. A stub standing in for Service carries Service's property set.
      ceilingOverride: null, levelCapIndex: null, level: 1
    }
    for (var k in over) p[k] = over[k]
    return p
  }

  function stub(over) {
    var s = base(over)
    return s
  }

  // --- the level cap reaches the resolver (Phase 1) ---------------------------

  // Writing { levelCapIndex: s.levelCapIndex } creates a PRESENT key holding undefined, so
  // a presence check downstream passes and undefined reads as uncapped -- the fix failing
  // open in exactly the case it was written for. inputs() tests presence on its SOURCE.
  function test_inputs_flags_a_service_that_forgot_the_property() {
    var whole = Display.inputs(stub({ kiForm: "ui", levelCapIndex: 2 }))
    compare(whole.levelCapIndex, 2)

    var source = stub({ kiForm: "ui" })
    delete source.levelCapIndex
    var partial = Display.inputs(source)
    compare(partial.levelCapIndex, Display.MISSING, "an absent property is a sentinel")
    compare(Display.resolve(partial).displayIndex, 0, "and it fails CLOSED, not uncapped")
  }

  function test_inputs_is_the_only_constructor_and_carries_everything() {
    var p = Display.inputs(stub({ kiForm: "blue", levelCapIndex: 3, level: 42 }))
    var keys = ["line", "stage", "form", "kiForm", "kiStatus", "careAverage", "happiness",
                "careCount", "moonActive", "ceilingOverride", "levelCapIndex", "level"]
    for (var i = 0; i < keys.length; i++) verify(keys[i] in p, "inputs() must carry " + keys[i])
    compare(Display.resolve(p).displayIndex, 2, "and resolves through it")
  }

  // --- the explanation must not lie -------------------------------------------

  // A healthy adult below level 8 with a real Ultra Instinct reading is not run-down.
  function test_an_under_levelled_pet_is_told_the_truth() {
    var r = Display.resolve(Display.inputs(stub({ kiForm: "ui", levelCapIndex: 0, level: 5 })))
    compare(r.displayIndex, 0)
    compare(r.cause, "level")
    verify(r.kiExplain.indexOf("strong enough") >= 0, "got: " + r.kiExplain)
    verify(r.kiExplain.indexOf("5") >= 0, "and it names the level: " + r.kiExplain)
  }

  function test_too_young_outranks_too_weak() {
    var r = Display.resolve(Display.inputs(
      stub({ stage: "child", form: "child", kiForm: "ui", levelCapIndex: 0, level: 1 })))
    verify(r.kiExplain.indexOf("young") >= 0,
           "a child can do something about its age, not its level: " + r.kiExplain)
  }

  function test_run_down_still_reads_as_run_down() {
    var r = Display.resolve(Display.inputs(
      stub({ kiForm: "ui", careAverage: 10, happiness: 10, levelCapIndex: 3, level: 90 })))
    verify(r.kiExplain.indexOf("run-down") >= 0, "got: " + r.kiExplain)
  }

  // THE DEPLOY RISK. Service hands inputs() a real QObject, not a JS literal, and the whole
  // binding rests on `in` reporting a declared QML property. If it did not, every field
  // would become the sentinel, the pet would render as base and warn on every frame -- and
  // no pure test would have noticed, because a literal behaves differently.
  Item {
    id: qmlSource
    property string line: "goku"
    property string stage: "adult"
    property string form: "adult_ace"
    property string kiForm: "ui"
    property string kiStatus: "ok"
    property real careAverage: 95
    property real happiness: 95
    property int careCount: 50
    property bool moonActive: false
    property var ceilingOverride: null
    property var levelCapIndex: 2
    property int level: 25
  }

  Item {
    id: qmlSourceMissingCap
    property string line: "goku"
    property string stage: "adult"
    property string form: "adult_ace"
    property string kiForm: "ui"
    property string kiStatus: "ok"
    property real careAverage: 95
    property real happiness: 95
    property int careCount: 50
    property bool moonActive: false
    property var ceilingOverride: null
    property int level: 25
  }

  function test_inputs_reads_declared_properties_off_a_real_qml_object() {
    var p = Display.inputs(qmlSource)
    compare(p.levelCapIndex, 2, "`in` must see a declared QML property")
    compare(p.kiForm, "ui")
    compare(p.line, "goku")
    var r = Display.resolve(p)
    compare(r.displayIndex, 2, "and the cap must actually bind")
    compare(r.displayForm, "goku_blue", "a rung sprite is not stage-prefixed")
  }

  function test_a_qml_object_missing_the_property_fails_closed() {
    var p = Display.inputs(qmlSourceMissingCap)
    compare(p.levelCapIndex, Display.MISSING)
    compare(Display.resolve(p).displayIndex, 0)
  }

  function test_the_machine_truth_is_never_lowered_by_the_level_gate() {
    var r = Display.resolve(Display.inputs(stub({ kiForm: "ui", levelCapIndex: 0, level: 1 })))
    compare(r.rawKiIndex, 3, "the machine is still at Ultra Instinct and must say so")
    compare(r.effectiveRungIndex, 0)
  }

  function test_base_resolution_is_coherent() {
    var r = Display.resolve(base({}))
    compare(r.displayForm, "goku_adult_ace")
    compare(r.displayIndex, 0)
    compare(r.aura.enabled, false)
    compare(r.cause, "base")
    compare(r.rawKiIndex, 0)
    compare(r.effectiveRungIndex, 0)
  }

  function test_a_ki_rung_sets_every_field_together() {
    var r = Display.resolve(base({ kiForm: "blue" }))
    compare(r.displayForm, "goku_blue")
    compare(r.displayIndex, 2)
    compare(r.aura.enabled, true)
    compare(r.aura.color, "#66E0FF")
    compare(r.cause, "ki")
    compare(r.kiExplain, "Super Saiyan Blue")
    compare(r.rawKiIndex, 2)
    compare(r.effectiveRungIndex, 2)
  }

  function test_the_lunar_tuple_is_exactly_pinned() {
    var r = Display.resolve(base({ moonActive: true, kiForm: "ui" }))
    compare(r.displayForm, "goku_teen_scruffy")
    compare(r.displayIndex, 0)
    compare(r.aura.enabled, false)
    compare(r.cause, "moon")
    compare(r.kiExplain, "The moon is full. It is not itself tonight.")
  }

  function test_the_moon_cannot_touch_the_machine_truth() {
    var r = Display.resolve(base({ moonActive: true, kiForm: "ui" }))
    compare(r.rawKiIndex, 3)
    compare(r.effectiveRungIndex, 3)
  }

  function test_lunar_wins_over_every_rung_for_eligible_lines() {
    var rungs = ["base", "ssj", "blue", "ui"]
    for (var i = 0; i < rungs.length; i++) {
      var r = Display.resolve(base({ moonActive: true, kiForm: rungs[i] }))
      compare(r.cause, "moon", rungs[i])
      compare(r.displayForm, "goku_teen_scruffy", rungs[i])
    }
  }

  function test_only_oozaru_lines_transform() {
    var r = Display.resolve(base({ moonActive: true, line: "piccolo" }))
    compare(r.cause, "base")
    compare(r.displayForm, "piccolo_adult_ace")
  }

  function test_only_teens_and_adults_transform() {
    var r = Display.resolve(base({ moonActive: true, stage: "child", form: "child" }))
    compare(r.displayForm, "goku_child")
    compare(r.cause, "base")
  }

  function test_care_caps_the_effective_rung_not_the_raw_one() {
    var r = Display.resolve(base({ kiForm: "ui", careAverage: 60, happiness: 60 }))
    compare(r.rawKiIndex, 3)
    compare(r.effectiveRungIndex, 1)
    compare(r.displayIndex, 1)
    compare(r.kiExplain, "Super Saiyan")
  }

  function test_fallback_reasons_survive_the_move() {
    var r = Display.resolve(base({ kiForm: "ui", stage: "child", form: "child" }))
    compare(r.kiExplain, "Too young to transform")
    var r2 = Display.resolve(base({ kiForm: "ui", careAverage: 10, happiness: 10 }))
    compare(r2.kiExplain, "Too run-down to hold the form")
    var r3 = Display.resolve(base({ kiStatus: "stale" }))
    compare(r3.kiExplain, "Ki reading has gone stale")
    var r4 = Display.resolve(base({ kiStatus: "missing" }))
    compare(r4.kiExplain, "No ki reading")
  }

  function test_vegeta_uses_his_own_rung_labels() {
    var r = Display.resolve(base({ line: "vegeta", kiForm: "blue" }))
    compare(r.kiExplain, "Super Saiyan 2")
  }

  // --- the aura comes from the line, not a global table -----------------------

  function test_the_aura_is_the_pets_own_line_colour() {
    var goku = Display.resolve(Display.inputs(stub({ kiForm: "ssj" })))
    var picc = Display.resolve(Display.inputs(
      stub({ line: "piccolo", form: "adult_ace", kiForm: "ssj" })))
    compare(goku.aura.color, Lines.rungColor("goku", 1))
    compare(picc.aura.color, Lines.rungColor("piccolo", 1))
    verify(goku.aura.color !== picc.aura.color,
           "a green-haired Piccolo must not wear Goku's gold glow")
  }

  // The divergence guard, moved to where the aura now actually resolves: the glow must
  // always describe the rung the pet is SHOWING, never the one the machine is at.
  function test_the_aura_follows_every_cap() {
    var cases = [
      { over: { kiForm: "ui", levelCapIndex: 0, level: 1 }, want: 0 },
      { over: { kiForm: "ui", levelCapIndex: 1, level: 8 }, want: 1 },
      { over: { kiForm: "ui", levelCapIndex: 2, level: 20 }, want: 2 },
      { over: { kiForm: "ui", levelCapIndex: null }, want: 3 },
      { over: { kiForm: "blue", levelCapIndex: null }, want: 2 },
      { over: { kiForm: "ui", careAverage: 10, happiness: 10 }, want: 0 },
      { over: { kiForm: "ui", stage: "child", form: "child" }, want: 0 }
    ]
    for (var i = 0; i < cases.length; i++) {
      var r = Display.resolve(Display.inputs(stub(cases[i].over)))
      compare(r.displayIndex, cases[i].want, "case " + i + " index")
      compare(r.aura.color, Lines.auraFor("goku", cases[i].want).color, "case " + i + " aura")
      compare(r.aura.enabled, cases[i].want > 0, "case " + i + " enabled")
    }
  }
}
