import QtQuick
import Quickshell
import Quickshell.Io
import "cockpit.js" as Cockpit

// Reads the Omarchy Cockpit state document, which already sits local on this desktop and
// already measures the remote machine. That is why the distant-power readout and the fleet
// surges need no producer, no credential and no change to the machine being watched.
//
// ONE bounded read, no `stat`. Pairing a stat with a head would be a TOCTOU pair across
// Cockpit's atomic rename -- one inode's mtime with another inode's contents -- and it is
// unnecessary, because cockpit-stated stamps `fetched_at` with THIS machine's clock.
//
// The snapshot is held WHOLE. Mirroring it field by field is exactly how KiSource dropped
// acceptedPower and killed three features while every pure test passed.
Item {
  id: root
  visible: false

  // No fallback path: an unset HOME means "no source", which both readers already
  // handle by failing closed. A hard-coded home can never be right for someone else.
  readonly property string home: Quickshell.env("HOME") || ""
  property string sourcePath: home + "/.local/state/cockpit/state.json"

  // Injectable, so the integration harness never reads or replaces the live file.
  property int pollMs: 30000
  property int maxBytes: 65536
  property bool useSystemClock: true
  property real nowSecs: 0

  property var cockpitState: Cockpit.emptyState()
  property string lastLoggedStatus: ""

  readonly property string status: cockpitState.status
  readonly property bool trusted: cockpitState.trusted === true
  readonly property var gpu: cockpitState.gpu
  readonly property var fleet: cockpitState.fleet

  // null whenever the document is not currently trustworthy, which is what hides the
  // readout rather than freezing a number.
  readonly property var distantPowerW: gpu ? gpu.powerW : null
  readonly property string distantState: gpu ? gpu.state : "unknown"
  readonly property var fleetAgents: fleet ? fleet.agents : null

  function currentSecs() {
    return useSystemClock ? (Date.now() / 1000) : nowSecs
  }

  function apply(next) {
    cockpitState = next
    // Transition-only, like KiSource: a 30 s poll that logged every tick would bury the
    // journal, and the drop-reason discipline is what keeps it readable.
    if (lastLoggedStatus === next.status) return
    lastLoggedStatus = next.status
    console.log("omagoku: cockpit " + next.status
                + (next.status === "ok" && next.gpu ? " gpu=" + next.gpu.state : ""))
  }

  function read() {
    if (reader.running) return
    reader.running = true
  }

  Process {
    id: reader
    command: ["head", "-c", String(root.maxBytes + 1), root.sourcePath]
    stdout: StdioCollector { id: cockpitOut }
    onExited: function (exitCode) {
      var now = root.currentSecs()
      if (exitCode !== 0) {
        root.apply(Cockpit.parse("", undefined, now, root.cockpitState))
        return
      }
      var bytes = undefined
      try {
        if (cockpitOut.data !== undefined && cockpitOut.data !== null)
          bytes = cockpitOut.data.byteLength
      } catch (e) {
        bytes = undefined
      }
      root.apply(Cockpit.parse(cockpitOut.text, bytes, now, root.cockpitState))
    }
  }

  Timer {
    interval: root.pollMs
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.read()
  }
}
