import QtQuick
import Quickshell
import Quickshell.Io
import "ki.js" as Ki

// Reads the machine's ki from saiyan-ki's ki.json, so Goku's transformation follows the
// desktop's measured power level.
//
// ONE OWNER. The Service instantiates exactly one of these and exposes derived properties.
// One per PetSprite call site would mean four watchers, four timers and four snapshots that
// can disagree with each other.
//
// FileView is used for CHANGE NOTIFICATION ONLY and never reads the file: a FileView length
// check happens after the whole file is already in memory, which is not a bounded read. The
// read is a fixed-argv `head -c` Process, the same bounded pattern upstream uses for its own
// state (Service.qml:731-741).
//
// THE READ IS DRIVEN BY THE TIMER, not by the watcher. It runs on completion and every
// pollMs regardless; a change event only accelerates the next read. A watcher-only design
// never recovers from a ki.json that is absent at startup, because a missing file emits no
// change event when it later appears.
//
// Everything fails closed to "base". A stale, missing, malformed, oversized or unrecognised
// reading must never show a power level the machine is not actually at -- that is the same
// honesty rule the screensaver board follows, and the reason `status` exists is so that
// "fell back to base" is distinguishable from "is genuinely base".
Item {
  id: root
  visible: false

  // No fallback path: an unset HOME means "no source", which both readers already
  // handle by failing closed. A hard-coded home can never be right for someone else.
  readonly property string home: Quickshell.env("HOME") || ""
  property string sourcePath: home + "/.local/state/saiyan-os/ki.json"
  property string reducedMotionPath: home + "/.local/state/saiyan-os/reduced-motion"

  // Injectable for tests, so the suite never reads or replaces the live files.
  property int pollMs: 5000
  property int maxBytes: 65536
  property int staleS: 300
  property int futureSkewS: 120
  property bool useSystemClock: true
  property real nowSecs: 0

  readonly property var forms: Ki.FORMS

  // THE WHOLE SNAPSHOT, held as one object. It used to be three mirrored properties, and the
  // mirror silently dropped acceptedPower when it was added -- powerOf() read undefined
  // forever, so the BP readout, the over-9000 alert and the sparkline were all dead in
  // production while every ki.js test passed. One object cannot drift from itself.
  property var kiState: Ki.emptyState()
  property string lastLoggedStatus: ""
  property bool reducedMotionFile: false

  // ok | stale | missing | malformed. Logged on TRANSITION only: a 5s poll that logged
  // every tick would bury the desktop's journal.
  readonly property string status: kiState.status
  readonly property real acceptedTs: kiState.acceptedTs
  readonly property string acceptedForm: kiState.acceptedForm

  // The only thing callers should use. Anything not currently trustworthy reads as base.
  readonly property string kiForm: Ki.formOf(kiState)
  readonly property int kiIndex: Ki.indexOf(kiForm)
  // Battle power, validated independently of the form: a malformed power hides the readout
  // without rejecting a snapshot that carries a valid form. null means "no reading".
  readonly property var kiPower: Ki.powerOf(kiState)

  function apply(next) {
    // null means "this read told us nothing new" -- an out-of-order snapshot, or freshness
    // that has not actually changed. Not a rejection, so nothing is cleared.
    if (!next) return
    kiState = next
    if (lastLoggedStatus === next.status) return
    lastLoggedStatus = next.status
    console.log("omagoku: ki " + next.status
                + (next.status === "ok" ? " form=" + next.acceptedForm : ""))
  }

  readonly property var limits: ({
    staleS: root.staleS, futureSkewS: root.futureSkewS, maxBytes: root.maxBytes
  })

  function snapshot() {
    return kiState
  }

  // Through ki.js, so the rejected shape is defined in exactly one place.
  function reject(why) {
    apply(Ki.rejected(why))
  }

  function accept(text, byteLength) {
    apply(Ki.evaluate(snapshot(), text, byteLength, currentSecs(), limits))
  }

  function currentSecs() {
    return useSystemClock ? (Date.now() / 1000) : nowSecs
  }

  function refreshFreshness() {
    apply(Ki.refreshed(snapshot(), currentSecs(), limits))
  }

  function read() {
    if (reader.running) return
    reader.running = true
  }

  Process {
    id: reader
    command: ["head", "-c", String(root.maxBytes + 1), root.sourcePath]
    stdout: StdioCollector { id: kiOut }
    onExited: function (exitCode) {
      if (exitCode !== 0) { root.reject("missing"); return }
      var bytes = undefined
      try {
        if (kiOut.data !== undefined && kiOut.data !== null)
          bytes = kiOut.data.byteLength
      } catch (e) {
        bytes = undefined
      }
      root.accept(kiOut.text, bytes)
    }
  }

  Process {
    id: motionProbe
    command: ["test", "-e", root.reducedMotionPath]
    onExited: function (exitCode) { root.reducedMotionFile = (exitCode === 0) }
  }

  // Notification only. No preload, no reload(), no text() -- the shell never maps this file.
  FileView {
    path: root.sourcePath
    preload: false
    watchChanges: true
    printErrors: false
    onFileChanged: root.read()
  }

  Timer {
    interval: root.pollMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: {
      root.read()
      root.refreshFreshness()
      if (!motionProbe.running) motionProbe.running = true
    }
  }

  Component.onCompleted: {
    read()
    motionProbe.running = true
  }
}
