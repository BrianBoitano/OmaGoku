import QtQuick
import QtTest
import ".."

// The candidate chain is the thing upstream got wrong, so it is the thing under test.
// Runs headless: /usr/lib/qt6/bin/qmltestrunner -input plugin/tests, QT_QPA_PLATFORM=offscreen.
TestCase {
  name: "FallbackChain"

  Component {
    id: spriteComp
    PetSprite {}
  }

  function keys(s) {
    var out = []
    for (var i = 0; i < s.candidates.length; i++)
      out.push(s.candidates[i].f + "/" + s.candidates[i].a)
    return out
  }

  // The full key, variant token included.
  function vkeys(s) {
    var out = []
    for (var i = 0; i < s.candidates.length; i++)
      out.push(s.candidates[i].f + "/" + s.candidates[i].a + "/" + s.candidates[i].s)
    return out
  }

  // --- genetics: colour degrades first, then animation, then rung ------------

  // The ordering defect this component was reviewed into: with the colour tier outermost,
  // a missing walk VARIANT reaches the idle variant before the canonical WALK, and the pet
  // slides across the screen visibly standing still. Rung still outranks both -- every
  // resolved-form candidate precedes every base-form one.
  function test_a_missing_walk_variant_reaches_the_canonical_WALK_before_any_idle() {
    var s = createTemporaryObject(spriteComp, this, {
      form: "ssj", baseForm: "adult_ace", anim: "walk", fallbackAnim: "idle",
      variantSuffix: "_g4" })
    var k = vkeys(s)
    compare(k[0], "ssj/walk/_g4")
    compare(k[1], "ssj/walk/", "the SAME animation in canonical colours comes next")
    verify(k.indexOf("ssj/walk/") < k.indexOf("ssj/idle/_g4"),
           "animation truth outranks colour truth")
    verify(k.indexOf("ssj/idle/") < k.indexOf("adult_ace/walk/_g4"),
           "and rung truth outranks both")
  }

  function test_the_full_order_is_pinned() {
    var s = createTemporaryObject(spriteComp, this, {
      form: "ssj", baseForm: "adult_ace", anim: "climb", fallbackAnim: "walk",
      variantSuffix: "_g0" })
    compare(vkeys(s), ["ssj/climb/_g0", "ssj/climb/",
                       "ssj/walk/_g0", "ssj/walk/",
                       "ssj/idle/_g0", "ssj/idle/",
                       "adult_ace/climb/_g0", "adult_ace/climb/",
                       "adult_ace/walk/_g0", "adult_ace/walk/",
                       "adult_ace/idle/_g0", "adult_ace/idle/"])
  }

  // Bucket 2 is the identity and produces no token, so an undrifted pet must build exactly
  // the list this component built before genetics existed. Asserted as SEQUENCE EQUALITY
  // across a matrix, not as a fixed length: the dedup already yields between one and six
  // candidates depending on whether form equals base and whether the anims coincide.
  function test_an_empty_suffix_reproduces_the_pre_genetics_sequence() {
    var cases = [
      { form: "ssj", baseForm: "adult_ace", anim: "climb", fallbackAnim: "walk",
        want: ["ssj/climb", "ssj/walk", "ssj/idle",
               "adult_ace/climb", "adult_ace/walk", "adult_ace/idle"] },
      { form: "child", baseForm: "child", anim: "walk", fallbackAnim: "idle",
        want: ["child/walk", "child/idle"] },
      { form: "baby", baseForm: "baby", anim: "idle", fallbackAnim: "idle",
        want: ["baby/idle"] },
      { form: "pod", baseForm: "", anim: "idle", fallbackAnim: "idle",
        want: ["pod/idle"] },
      { form: "blue", baseForm: "adult_ok", anim: "walk", fallbackAnim: "walk",
        want: ["blue/walk", "blue/idle", "adult_ok/walk", "adult_ok/idle"] }
    ]
    for (var i = 0; i < cases.length; i++) {
      var c = cases[i]
      var s = createTemporaryObject(spriteComp, this, {
        form: c.form, baseForm: c.baseForm, anim: c.anim, fallbackAnim: c.fallbackAnim,
        variantSuffix: "" })
      compare(keys(s), c.want, "case " + i + " must match the pre-genetics sequence")
    }
  }

  function test_changing_the_variant_restarts_the_chain() {
    var s = createTemporaryObject(spriteComp, this, {
      form: "ssj", baseForm: "adult_ace", anim: "idle", fallbackAnim: "idle" })
    s.candidateIndex = 1
    s.variantSuffix = "_g3"
    compare(s.candidateIndex, 0, "a new bucket must not resume mid-chain")
  }

  function test_transformed_tries_own_anims_before_base_form() {
    var s = createTemporaryObject(spriteComp, this, {
      form: "ssj", baseForm: "adult_ace", anim: "climb", fallbackAnim: "walk" })
    compare(keys(s), ["ssj/climb", "ssj/walk", "ssj/idle",
                      "adult_ace/climb", "adult_ace/walk", "adult_ace/idle"])
  }

  function test_deduplicates_when_base_equals_form() {
    var s = createTemporaryObject(spriteComp, this, {
      form: "child", baseForm: "child", anim: "walk", fallbackAnim: "idle" })
    compare(keys(s), ["child/walk", "child/idle"])
  }

  function test_deduplicates_when_anim_is_idle() {
    var s = createTemporaryObject(spriteComp, this, {
      form: "baby", baseForm: "baby", anim: "idle", fallbackAnim: "idle" })
    compare(keys(s), ["baby/idle"])
  }

  function test_missing_baseForm_falls_back_to_form() {
    var s = createTemporaryObject(spriteComp, this, {
      form: "egg", anim: "idle", fallbackAnim: "idle" })
    compare(keys(s), ["egg/idle"])
  }

  // Upstream oscillated forever here. The chain must be finite and terminate.
  function test_chain_terminates_instead_of_oscillating() {
    var s = createTemporaryObject(spriteComp, this, {
      form: "ssj", baseForm: "adult_ace", anim: "climb", fallbackAnim: "walk" })
    var n = s.candidates.length
    verify(n > 0)
    for (var i = 0; i < n; i++) {
      verify(!s.spriteMissing)
      s.candidateIndex = s.candidateIndex + 1
    }
    verify(s.spriteMissing)
    compare(s.resolvedAnim, "idle")   // safe value once exhausted
  }

  function test_changing_form_restarts_the_chain() {
    var s = createTemporaryObject(spriteComp, this, {
      form: "ssj", baseForm: "adult_ace", anim: "walk", fallbackAnim: "idle" })
    s.candidateIndex = 2
    s.form = "blue"
    compare(s.candidateIndex, 0)
    verify(!s.spriteMissing)
  }

  function test_upstream_callers_keep_theme_tinting_by_default() {
    var s = createTemporaryObject(spriteComp, this, {})
    compare(s.colorize, true)     // emotes and decor must be unaffected
    compare(s.auraEnabled, false)
  }
}
