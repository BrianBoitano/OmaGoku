import QtQuick
import QtTest
import "../lines.js" as L

TestCase {
  name: "Lines"

  function test_the_roster_is_the_five_agreed_lines() {
    compare(L.ids(), ["goku", "vegeta", "piccolo", "krillin", "frieza"])
  }

  // A line id becomes a path component in every sprite URL.
  function test_only_roster_ids_are_trusted() {
    var bad = ["../../etc/passwd", "", "goku/../frieza", "GOKU", "saiyan",
               null, undefined, 3, {}]
    for (var i = 0; i < bad.length; i++)
      verify(!L.has(bad[i]), "has() accepted " + bad[i])
    var ids = L.ids()
    for (var j = 0; j < ids.length; j++) verify(L.has(ids[j]), ids[j])
  }

  function test_each_line_has_its_own_succession() {
    compare(L.nameFor("goku", 1), "Goku")
    compare(L.nameFor("goku", 2), "Gohan")
    compare(L.nameFor("goku", 4), "Goku Jr.")
    compare(L.nameFor("vegeta", 1), "Vegeta")
    compare(L.nameFor("vegeta", 3), "Bulla")
    compare(L.nameFor("piccolo", 2), "Piccolo Jr.")
    compare(L.nameFor("krillin", 2), "Marron")
    compare(L.nameFor("frieza", 2), "Kuriza")
  }

  // Shorter lines wrap sooner. Vegeta has three members, so gen 4 starts pass two.
  function test_a_line_repeats_with_the_pass_number_appended() {
    compare(L.nameFor("goku", 5), "Goku II")
    compare(L.nameFor("vegeta", 4), "Vegeta II")
    compare(L.nameFor("piccolo", 3), "Piccolo II")
    compare(L.nameFor("krillin", 5), "Krillin III")
  }

  function test_every_line_survives_a_hand_edited_generation() {
    var bad = [0, -3, NaN, undefined, null, "", "seven", 1.7]
    var ids = L.ids()
    for (var i = 0; i < ids.length; i++) {
      for (var j = 0; j < bad.length; j++) {
        var p = L.profile(ids[i], bad[j])
        verify(p.name !== undefined && p.name !== "", ids[i] + " " + bad[j])
        verify(p.room !== undefined && p.room !== "", ids[i] + " " + bad[j])
        verify(p.generation >= 1)
      }
    }
  }

  // The panel prints these. A missing rung would show "undefined" to a person.
  function test_every_line_names_all_four_rungs() {
    var ids = L.ids()
    for (var i = 0; i < ids.length; i++) {
      for (var r = 0; r < 4; r++) {
        var label = L.rungLabel(ids[i], r)
        verify(typeof label === "string" && label.length > 0,
               ids[i] + " rung " + r)
        verify(label !== String(r), ids[i] + " rung " + r + " is a raw index")
      }
    }
    compare(L.rungLabel("goku", 1), "Super Saiyan")
    compare(L.rungLabel("vegeta", 2), "Super Saiyan 2")
    compare(L.rungLabel("piccolo", 3), "Orange Piccolo")
    compare(L.rungLabel("frieza", 0), "First Form")
  }

  function test_an_out_of_range_rung_never_returns_undefined() {
    var bad = [-1, 4, 99, NaN, undefined, null, "1"]
    for (var i = 0; i < bad.length; i++) {
      var label = L.rungLabel("goku", bad[i])
      verify(typeof label === "string" && label.length > 0, "rung " + bad[i])
    }
  }

  function test_every_line_declares_all_five_rates() {
    var keys = ["hunger", "dirt", "tired", "fun", "lonely"]
    var ids = L.ids()
    for (var i = 0; i < ids.length; i++) {
      var r = L.ratesFor(ids[i])
      for (var k = 0; k < keys.length; k++) {
        var v = r[keys[k]]
        verify(typeof v === "number" && isFinite(v) && v > 0,
               ids[i] + "." + keys[k] + " = " + v)
      }
    }
    compare(L.ratesFor("goku").hunger, 1.0)
    compare(L.ratesFor("piccolo").hunger, 0.4)
    compare(L.ratesFor("vegeta").fun, 1.5)
  }

  function test_an_unknown_line_falls_back_rather_than_throwing() {
    compare(L.ratesFor("nope").hunger, L.ratesFor(L.DEFAULT_LINE).hunger)
    compare(L.nameFor("nope", 1), L.nameFor(L.DEFAULT_LINE, 1))
  }

  function test_base_sprite_is_prefixed_and_injection_free() {
    compare(L.baseSprite("vegeta", "adult", "adult_ace"), "vegeta_adult_ace")
    compare(L.baseSprite("goku", "egg", "pod"), "goku_pod")
    var forms = ["pod", "baby", "child", "teen_neat", "teen_scruffy",
                 "adult_ace", "adult_ok", "adult_gremlin"]
    var ids = L.ids()
    for (var i = 0; i < ids.length; i++) {
      for (var f = 0; f < forms.length; f++) {
        var s = L.baseSprite(ids[i], "adult", forms[f])
        verify(s.indexOf("/") < 0 && s.indexOf("..") < 0, s)
        compare(s, ids[i] + "_" + forms[f])
      }
    }
    // An unknown line must not become a path component either.
    verify(L.baseSprite("../../x", "adult", "adult_ace").indexOf("..") < 0)
  }

  function test_rooms_cycle_three_per_line() {
    compare(L.roomFor("goku", 1), "kame")
    compare(L.roomFor("goku", 4), "kame")
    compare(L.roomFor("vegeta", 1), "gravity")
    var ids = L.ids()
    for (var i = 0; i < ids.length; i++) {
      var seen = {}
      for (var n = 1; n <= 3; n++) seen[L.roomFor(ids[i], n)] = true
      compare(Object.keys(seen).length, 3, ids[i] + " needs three distinct rooms")
    }
  }

  function test_every_line_has_a_blurb_for_the_selector() {
    var ids = L.ids()
    for (var i = 0; i < ids.length; i++) {
      var b = L.blurbFor(ids[i])
      verify(typeof b === "string" && b.length > 10, ids[i])
      verify(b.indexOf("—") < 0, ids[i] + " blurb contains an em dash")
    }
  }

  // Only Saiyan lines turn into a Great Ape; the others just have a neglected teen.
  function test_only_saiyan_lines_are_oozaru_lines() {
    verify(L.isOozaruLine("goku"))
    verify(L.isOozaruLine("vegeta"))
    verify(!L.isOozaruLine("piccolo"))
    verify(!L.isOozaruLine("krillin"))
    verify(!L.isOozaruLine("frieza"))
  }

  // Line rates MULTIPLY the per-stage rates; they never replace them, or a Piccolo baby
  // would stop napping and a Vegeta teen would stop raiding the fridge.
  function test_line_rates_compose_with_stage_rates() {
    var stage = { hunger: 2, dirt: 1, tired: 0.8, fun: 0.5 }
    var goku = L.composeRates(stage, "goku")
    compare(goku.hunger, 2)
    compare(goku.fun, 0.5)

    var piccolo = L.composeRates(stage, "piccolo")
    compare(piccolo.hunger, 0.8)          // 2 * 0.4
    compare(piccolo.fun, 0.25)            // 0.5 * 0.5

    var vegeta = L.composeRates(stage, "vegeta")
    compare(vegeta.hunger, 2.8)           // 2 * 1.4
    compare(vegeta.tired, 0.64)           // 0.8 * 0.8
  }

  // Loneliness has no per-stage rate upstream, so it comes from the line alone.
  function test_loneliness_comes_from_the_line_alone() {
    var stage = { hunger: 1, dirt: 1, tired: 1, fun: 1 }
    compare(L.composeRates(stage, "krillin").lonely, 1.2)
    compare(L.composeRates(stage, "frieza").lonely, 0.3)
  }

  function test_composed_rates_are_never_nan_for_a_bad_stage_table() {
    var composed = L.composeRates({}, "goku")
    var keys = ["hunger", "dirt", "tired", "fun", "lonely"]
    for (var i = 0; i < keys.length; i++)
      verify(isFinite(composed[keys[i]]), keys[i] + " is not finite")
  }

  // Regression, final review. A rung sprite is line-prefixed exactly like a life sprite.
  // An unprefixed rung name resolves to a file that does not exist, and PetSprite's
  // fallback chain then renders the untransformed pet while the ki reading says otherwise.
  function test_a_rung_sprite_is_line_prefixed_like_a_life_sprite() {
    compare(L.baseSprite("goku", "adult", "ssj"), "goku_ssj")
    compare(L.baseSprite("vegeta", "adult", "blue"), "vegeta_blue")
    compare(L.baseSprite("piccolo", "adult", "ui"), "piccolo_ui")
    var ids = L.ids()
    var rungs = ["ssj", "blue", "ui"]
    for (var i = 0; i < ids.length; i++)
      for (var r = 0; r < rungs.length; r++)
        compare(L.baseSprite(ids[i], "adult", rungs[r]), ids[i] + "_" + rungs[r])
    // An empty or corrupt line must never produce a bare or traversal-shaped path.
    verify(L.baseSprite("", "adult", "ssj").indexOf("_ssj") > 0)
    verify(L.baseSprite("../../x", "adult", "ssj").indexOf("..") < 0)
  }

  // Regression. Eight call sites used a bare "pod" as their not-ready placeholder, which
  // the per-line sprite rename turned into a file that does not exist, so the pet
  // rendered nothing at all until the service loaded.
  function test_the_placeholder_sprite_is_line_prefixed() {
    compare(L.PLACEHOLDER_SPRITE, "goku_pod")
    verify(L.PLACEHOLDER_SPRITE.indexOf("_") > 0)
  }

  // --- the aura is the line's OWN rung colour ---------------------------------
  //
  // transform.js used to hold one global AURA table while the transformation hair is baked
  // per line in palettes.tsv, so four of five lines wore a glow that contradicted their own
  // hair: piccolo's green Super Saiyan inside a gold aura, vegeta's blue Blue Evolution
  // inside a silver one, frieza's Golden form inside silver. Two sources for one truth.

  function test_every_line_declares_all_three_rung_colours() {
    var ids = L.ids()
    for (var i = 0; i < ids.length; i++) {
      for (var r = 1; r <= 3; r++) {
        var c = L.rungColor(ids[i], r)
        verify(/^#[0-9A-Fa-f]{6}$/.test(c),
               ids[i] + " rung " + r + " must be a hex colour, got " + c)
      }
    }
  }

  function test_the_aura_is_the_lines_own_rung_colour() {
    var ids = L.ids()
    for (var i = 0; i < ids.length; i++) {
      for (var r = 1; r <= 3; r++) {
        var a = L.auraFor(ids[i], r)
        compare(a.color, L.rungColor(ids[i], r), ids[i] + " rung " + r)
        compare(a.enabled, true)
        compare(a.pulse, true)
      }
    }
  }

  // The regression, named: these two used to be the same gold.
  function test_piccolos_super_saiyan_glow_is_not_gokus() {
    verify(L.rungColor("piccolo", 1) !== L.rungColor("goku", 1),
           "piccolo's first rung is green; it must not glow gold")
    verify(L.rungColor("frieza", 3) !== L.rungColor("goku", 3),
           "golden frieza must not glow silver")
    verify(L.rungColor("vegeta", 3) !== L.rungColor("goku", 3),
           "blue evolution must not glow silver")
  }

  function test_base_and_nonsense_have_no_aura() {
    compare(L.auraFor("goku", 0).enabled, false)
    compare(L.auraFor("goku", 0).color, "#00000000")
    // An unknown id falls back to DEFAULT_LINE rather than throwing, exactly as nameFor,
    // roomFor and rungLabel do -- Lines.has() is the only thing that makes an id
    // trustworthy, and a throw inside a QML binding is silent.
    compare(L.auraFor("trunks", 2).color, L.rungColor(L.DEFAULT_LINE, 2),
            "an unknown line falls back like every other accessor here")
    compare(L.rungColor("trunks", 1), L.rungColor(L.DEFAULT_LINE, 1))
    compare(L.auraFor("goku", 9).enabled, false, "there is no fourth rung")
    compare(L.auraFor("goku", -1).enabled, false)
    compare(L.rungColor("goku", 0), null)
  }
}
