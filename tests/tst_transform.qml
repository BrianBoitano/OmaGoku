import QtQuick
import QtTest
import "../transform.js" as T

TestCase {
  name: "Transform"

  function test_ladder_is_what_the_producer_emits() {
    compare(T.FORMS, ["base", "ssj", "blue", "ui"])
  }

  function test_unknown_form_is_base_not_an_error() {
    compare(T.formIndex("ssj4"), 0)
    compare(T.formIndex("../../etc/passwd"), 0)
    compare(T.formIndex(""), 0)
  }

  // Regression: a boolean stageAllows coerces to 1 and caps everyone at ssj.
  function test_stage_cap_is_an_index_not_a_boolean() {
    compare(T.stageCapIndex("teen"), 3)
    compare(T.stageCapIndex("adult"), 3)
    compare(T.stageCapIndex("child"), 0)
    compare(T.stageCapIndex("baby"), 0)
    compare(T.stageCapIndex("egg"), 0)
    verify(T.stageCapIndex("adult") !== true)
  }

  function test_child_never_transforms_however_hot_the_machine() {
    compare(T.displayIndex("ui", "child", 100, 100, 50), 0)
    compare(T.displayIndex("ui", "baby", 100, 100, 50), 0)
    compare(T.displayIndex("ui", "egg", 100, 100, 50), 0)
  }

  // The decision called out as the most important one in the design.
  function test_starving_goku_cannot_transform_even_at_max_ki() {
    // stage-long average still high, but current condition is dire
    compare(T.displayIndex("ui", "adult", 95, 10, 50), 0)
  }

  function test_well_cared_for_goku_reaches_the_machines_form() {
    compare(T.displayIndex("ui", "adult", 95, 95, 50), 3)
    compare(T.displayIndex("blue", "adult", 95, 95, 50), 2)
    compare(T.displayIndex("ssj", "adult", 95, 95, 50), 1)
  }

  function test_ki_is_a_ceiling_care_cannot_exceed_it() {
    compare(T.displayIndex("ssj", "adult", 100, 100, 50), 1)
  }

  // Regression: careAverage returns 100 at zero samples, which evolve() causes every time.
  function test_freshly_evolved_starving_pet_is_not_treated_as_perfectly_cared_for() {
    compare(T.displayIndex("ui", "adult", 100, 5, 0), 0)
    compare(T.ceilingIndex(100, 5, 0), 0)
    compare(T.ceilingIndex(100, 90, 0), 3)
  }

  function test_base_index_resolves_to_the_life_sprite_not_a_missing_base_sprite() {
    compare(T.displayIndex("base", "adult", 100, 100, 50), 0)
    compare(T.displayIndex("ui", "adult", 10, 10, 50), 0)
  }

  function test_care_thresholds() {
    compare(T.ceilingIndex(85, 85, 5), 3)
    compare(T.ceilingIndex(84, 84, 5), 2)
    compare(T.ceilingIndex(70, 70, 5), 2)
    compare(T.ceilingIndex(69, 69, 5), 1)
    compare(T.ceilingIndex(50, 50, 5), 1)
    compare(T.ceilingIndex(49, 49, 5), 0)
  }

  // The aura moved to lines.js, because the transformation hair is baked PER LINE and a
  // single global table contradicted four of the five. transform.js decides which RUNG the
  // pet is on; the line decides what that rung looks like.
  function test_transform_no_longer_owns_the_aura() {
    verify(T.AURA === undefined,
           "transform.js must not hold a global aura table; lines.js owns rung colour")
    verify(T.auraFor === undefined,
           "transform.js must not expose auraFor; Display.resolve resolves the aura")
  }

  // Regression. transform.js used to expose displayForm(), which returned a BARE rung name
  // like "ssj". Every sprite is line-prefixed, so that produced a path that does not exist
  // and PetSprite silently fell back to rendering the untransformed pet. Service.qml now
  // composes the name through Lines.baseSprite() instead. The function is gone so nobody
  // reaches for it again.
  function test_transform_no_longer_returns_bare_rung_names() {
    verify(T.displayForm === undefined,
           "transform.js must not expose displayForm; rung names are line-prefixed by lines.js")
  }

  // --- the Shenron ceiling wish (idea 9) --------------------------------------

  // An INDEX or null, never a boolean. `true` coerces to 1 inside Math.min and would CAP an
  // honest Blue or Ultra Instinct reading at Super Saiyan -- the exact inverse of the grant,
  // and the same coercion trap stageCapIndex already carries a comment about.
  function test_the_override_lifts_the_care_ceiling_without_inventing_power() {
    // Run down: care would normally cap this pet at base.
    compare(T.displayIndex("ui", "adult", 10, 10, 5), 0)
    compare(T.displayIndex("ui", "adult", 10, 10, 5, 3), 3,
            "the wish lifts the cap to the real reading")
    compare(T.displayIndex("ssj", "adult", 10, 10, 5, 3), 1,
            "but never above what the machine actually reported")
    compare(T.displayIndex("ui", "child", 10, 10, 5, 3), 0,
            "and the stage cap still binds")
  }

  function test_a_boolean_override_is_refused() {
    compare(T.displayIndex("ui", "adult", 100, 100, 5, true), 3,
            "true must not silently become the index 1")
    compare(T.displayIndex("ui", "adult", 100, 100, 5, "3"), 3)
    compare(T.displayIndex("ui", "adult", 100, 100, 5, 99), 3)
  }

  // --- the level cap (Phase 1) ------------------------------------------------

  function test_caps_names_the_constraint_that_actually_lowered_the_rung() {
    var lvl = T.caps("ui", "adult", 95, 95, 50, null, 1)
    compare(lvl.effective, 1)
    compare(lvl.binding, "level")
    compare(T.caps("ui", "adult", 30, 30, 50, null, 3).binding, "care")
    compare(T.caps("ui", "child", 95, 95, 50, null, 3).binding, "stage")
  }

  // A cap that merely EQUALS the measured rung did not lower anything, and reporting it
  // would tell a level-8 pet showing an honest Super Saiyan it is not strong enough.
  function test_binding_is_null_when_a_cap_only_equals_the_reading() {
    var c = T.caps("ssj", "adult", 95, 95, 50, null, 1)
    compare(c.effective, 1)
    compare(c.binding, null)
    compare(T.caps("base", "adult", 95, 95, 50, null, 0).binding, null)
  }

  // The opposite direction to ceilingOverride, on purpose: null means UNCAPPED here, so
  // failing open would switch progression gating off.
  function test_the_level_cap_fails_closed_on_anything_invalid() {
    compare(T.displayIndex("ui", "adult", 95, 95, 50, null, 3), 3)
    compare(T.displayIndex("ui", "adult", 95, 95, 50, null, null), 3, "null is uncapped")
    compare(T.displayIndex("ui", "adult", 95, 95, 50, null, undefined), 3, "omitted too")
    compare(T.displayIndex("ui", "adult", 95, 95, 50, null, true), 0)
    compare(T.displayIndex("ui", "adult", 95, 95, 50, null, "2"), 0)
    compare(T.displayIndex("ui", "adult", 95, 95, 50, null, -1), 0)
    compare(T.displayIndex("ui", "adult", 95, 95, 50, null, 4), 0)
  }

  function test_the_gate_only_ever_lowers_the_rung() {
    compare(T.displayIndex("ssj", "adult", 95, 95, 50, null, 3), 1,
            "a high cap cannot invent power the machine is not at")
    compare(T.displayIndex("ui", "child", 95, 95, 50, null, 3), 0, "stage still binds")
    compare(T.displayIndex("ui", "adult", 10, 10, 50, null, 3), 0, "care still binds")
  }

  function test_the_five_argument_form_is_unchanged() {
    compare(T.displayIndex("blue", "adult", 100, 100, 5), 2)
    compare(T.displayIndex("blue", "adult", 60, 60, 5), 1)
    compare(T.displayIndex("base", "adult", 100, 100, 5), 0)
  }
}
