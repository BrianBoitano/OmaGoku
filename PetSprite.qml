import QtQuick
import QtQuick.Effects

// One animated sprite: the two frames (a/b) of `anim` for `form`.
//
// CHANGED FROM UPSTREAM, three things:
//
// 1. COLOUR. Upstream wrapped every sprite in MultiEffect with colorization: 1, which
//    replaces every non-transparent pixel with `tint` and discards the art's own colour.
//    `colorize` now controls that, defaulting to TRUE so every existing call site (emotes,
//    decor, panel chrome) keeps its theme tinting untouched. The pet's four call sites pass
//    false and render the palette art.
//
// 2. AURA. A blurred, slightly scaled, zero-offset shadow behind the sprite reads as ki.
//    The expansion is taken through MultiEffect.paddingRect ONLY. Growing this item instead
//    would change bar layout, roaming physics (which measure the sprite to place feet and
//    walls) and the click mask.
//
// 3. A FINITE FALLBACK CHAIN. Upstream's applyFallback() flipped resolvedAnim between
//    fallbackAnim and idle on every load error, so when both were missing and different it
//    oscillated forever -- the opposite of the "sprites can land gradually without ever
//    breaking a view" it promised. It also had no form-level fallback at all, so a
//    transformation whose grid failed to generate rendered nothing.
//
//    Now: one deduplicated ordered list of (form, anim) candidates, each tried at most once.
//    Animation alternatives within the requested form are exhausted BEFORE dropping to the
//    base life form, so a transformed pet degrades to a differently-animated transformed pet
//    before it degrades to an untransformed one. When the list runs out the item hides and
//    says so once, instead of looping.
Item {
  id: root

  property string form: "pod"
  // The pet's underlying life form (e.g. "adult_ace"). The last resort when a transformed
  // form has no art. Defaults to `form`, so single-form callers behave as before.
  property string baseForm: ""
  property string anim: "idle"
  // What to try when `anim`'s frames are missing (e.g. "walk" for a climb).
  property string fallbackAnim: "idle"
  property int frameMs: 500
  property bool playing: true
  property color tint: "white"
  property bool mirrored: false

  // The genetic variant token, appended to the whole FILENAME. Empty means canonical, and
  // bucket 2 -- the identity -- is deliberately empty, so an undrifted pet builds exactly
  // the candidate list it built before genetics existed.
  property string variantSuffix: ""

  property bool colorize: true
  property bool auraEnabled: false
  property color auraColor: "#FFD24A"
  property bool auraPulse: false
  property real auraPadding: 6

  property int frame: 0

  // The order encodes which truths matter most: COLOUR degrades first, then ANIMATION,
  // then RUNG. So the variant/canonical choice is the innermost loop, the animation the
  // middle, and the form the outermost.
  //
  // Getting this backwards is subtle and was caught in review: with the colour tier
  // outermost, a missing WALK variant falls through to the idle variant before it reaches
  // the canonical WALK, and the pet slides across the screen visibly standing still. Every
  // resolved-form candidate still precedes every base-form one, so a missing variant never
  // degrades to the base life form while the machine is at Super Saiyan.
  //
  // With an empty suffix each pair collapses under the dedup below, so an undrifted pet
  // produces exactly the sequence this component produced before genetics existed.
  readonly property var candidates: {
    var out = []
    var add = function (f, a, s) {
      if (!f || !a) return
      for (var i = 0; i < out.length; i++)
        if (out[i].f === f && out[i].a === a && out[i].s === s) return
      out.push({ f: f, a: a, s: s })
    }
    var forms = [root.form, root.baseForm || root.form]
    var anims = [root.anim, root.fallbackAnim, "idle"]
    for (var fi = 0; fi < forms.length; fi++)
      for (var ai = 0; ai < anims.length; ai++) {
        add(forms[fi], anims[ai], root.variantSuffix)
        add(forms[fi], anims[ai], "")
      }
    return out
  }

  property int candidateIndex: 0

  readonly property bool spriteMissing: candidateIndex >= candidates.length
  readonly property string resolvedForm: spriteMissing ? "" : candidates[candidateIndex].f
  // RoamWindow reads this to decide whether a climb needs the walk-frame tilt.
  readonly property string resolvedAnim: spriteMissing ? "idle" : candidates[candidateIndex].a
  readonly property string resolvedSuffix: spriteMissing ? "" : candidates[candidateIndex].s

  function restart() {
    candidateIndex = 0
    frame = 0
  }

  // Reset from the LIST rather than from a list of inputs. Four separate handlers meant
  // fallbackAnim -- which is an input to `candidates` and changes on every climb -- was the
  // one nobody remembered, so candidateIndex kept pointing into the previous list after it
  // had been rebuilt and possibly shortened by the dedup.
  onCandidatesChanged: restart()

  function advanceCandidate() {
    if (image.status !== Image.Error) return
    if (candidateIndex < candidates.length) candidateIndex++
    if (spriteMissing)
      console.warn("omagoku: no sprite for form=" + root.form
                   + " baseForm=" + root.baseForm + " anim=" + root.anim
                   + " variant='" + root.variantSuffix + "'")
  }

  Image {
    id: image
    anchors.fill: parent
    source: root.spriteMissing ? "" : Qt.resolvedUrl(
      "assets/sprites/" + root.resolvedForm + "_" + root.resolvedAnim
      + "_" + (root.frame === 0 ? "a" : "b") + root.resolvedSuffix + ".png")
    // Nearest-neighbour scaling keeps the pixels crisp.
    smooth: false
    mipmap: false
    fillMode: Image.PreserveAspectFit
    mirror: root.mirrored
    visible: false

    // Deferred: writing candidateIndex during the source evaluation that triggered the
    // status change would be a binding loop.
    onStatusChanged: if (status === Image.Error) Qt.callLater(root.advanceCandidate)
  }

  MultiEffect {
    id: fx
    anchors.fill: image
    source: image
    visible: !root.spriteMissing

    colorization: root.colorize ? 1 : 0
    colorizationColor: root.tint

    shadowEnabled: root.auraEnabled
    shadowColor: root.auraColor
    shadowBlur: 1.0
    shadowScale: 1.15
    shadowHorizontalOffset: 0
    shadowVerticalOffset: 0
    shadowOpacity: root.auraEnabled ? 0.9 : 0
    blurMax: 32

    // The aura is drawn outside the source rect, so the effect needs room that the item
    // itself must NOT grow into. Without this the glow is clipped at the room edge, the
    // bar edge and the screen edge.
    paddingRect: root.auraEnabled
      ? Qt.rect(-root.auraPadding, -root.auraPadding,
                width + root.auraPadding * 2, height + root.auraPadding * 2)
      : Qt.rect(0, 0, width, height)

    SequentialAnimation on shadowOpacity {
      running: root.auraEnabled && root.auraPulse && root.visible
      loops: Animation.Infinite
      NumberAnimation { to: 0.55; duration: 900; easing.type: Easing.InOutSine }
      NumberAnimation { to: 0.95; duration: 900; easing.type: Easing.InOutSine }
    }
  }

  Timer {
    interval: root.frameMs
    running: root.playing && root.visible && !root.spriteMissing
    repeat: true
    onTriggered: root.frame = root.frame === 0 ? 1 : 0
  }
}
