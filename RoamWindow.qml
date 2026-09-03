import QtQuick
import QtQuick.Effects
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import "lines.js" as Lines
import "rival.js" as Rival
import "dragonballs.js" as Balls

// The pet's playground: a transparent full-screen overlay where it wanders the
// bottom edge, climbs up the sides of windows whose top border leaves enough
// headroom, walks along their tops, and hops back down. Everything is
// click-through except the pet itself (mask), so the desktop stays usable.
//
// Window geometry comes from the Hyprland IPC via Quickshell — no shell
// commands. Coordinates are used as-is, which is correct at monitor scale 1;
// fractional scaling support is a known TODO.
PanelWindow {
  id: root

  required property var petService

  // RoamWindow, alone among the four sprite call sites, had no readiness property: the bar
  // has `serviceReady` and the panel has `ready`. Without one, this window binds the
  // service's form while the save file is still being parsed, so a hand-edited `form`
  // reaches PetSprite's asset URL before the service has validated it.
  readonly property bool serviceReady: !!petService && petService.initialized === true

  // Emitted when the pet lands hard enough to be stunned, carrying the landing point in
  // this window's coordinates. Separate from stunShock(), which is the service-side care
  // consequence: this one is about where it hit the ground.
  signal hardLanding(real x, real y)

  // The output named by the roamScreen setting, if it is currently connected.
  readonly property string preferredScreenName: {
    var name = petService && petService.settings ? petService.settings.roamScreen : ""
    return typeof name === "string" ? name : ""
  }

  // The playground, by priority: the screen pinned by the roamScreen setting,
  // else the screen Go play / Come home was clicked on, else the largest one.
  // Largest-only sent the pet to whichever monitor has the most pixels, which
  // on a mixed desk is often not the one being worked on — it looked like
  // "Go play" did nothing at all.
  screen: {
    var screens = Quickshell.screens
    var i
    if (preferredScreenName !== "") {
      for (i = 0; i < screens.length; i++)
        if (screens[i].name === preferredScreenName) return screens[i]
      // Named screen unplugged: fall through rather than leave the pet homeless.
    }
    var clicked = petService ? petService.requestedScreenName : ""
    if (clicked !== "") {
      for (i = 0; i < screens.length; i++)
        if (screens[i].name === clicked) return screens[i]
    }
    var best = null
    for (i = 0; i < screens.length; i++) {
      if (!best || screens[i].width * screens[i].height > best.width * best.height)
        best = screens[i]
    }
    return best
  }

  anchors {
    left: true
    right: true
    top: true
    bottom: true
  }
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.layer: WlrLayer.Top
  WlrLayershell.namespace: "omagoku"
  // Click-through everywhere except the pet — except mid-press, where the
  // whole window catches input: on an empty workspace Hyprland drops the
  // implicit grab on layer surfaces, so a cursor outrunning the sprite would
  // leave the input region and freeze the drag midair.
  mask: Region { item: grabArea.pressed ? root.contentItem : sprite }

  readonly property int petScale: {
    var value = petService && petService.settings
      ? Number(petService.settings.roamScale) : 3
    return value >= 2 && value <= 6 ? Math.round(value) : 3
  }
  readonly property int spriteSize: 16 * petScale
  // Headroom above a platform so the pet never pokes off-screen.
  readonly property int headroom: spriteSize + 12

  readonly property var hyprMonitor: Hyprland.monitorFor(root.screen)

  // The bar's reserved strip, so the floor sits above a bottom bar.
  readonly property real floorY: {
    var ipc = hyprMonitor ? hyprMonitor.lastIpcObject : null
    var reservedBottom = ipc && ipc.reserved && ipc.reserved.length > 3
      ? Number(ipc.reserved[3]) : 0
    return height - reservedBottom
  }

  // --- world model -----------------------------------------------------------

  // Walkable surfaces: window tops as {x1, x2, y, address}. The floor is the
  // implicit surface with address "".
  property var platforms: []
  // Current support: null = floor, else a platform object out of `platforms`.
  property var support: null

  function rebuildPlatforms() {
    if (!hyprMonitor) { platforms = []; validateSupport(); return }
    var meta = ({})
    var ws = hyprMonitor.activeWorkspace ? hyprMonitor.activeWorkspace.id : -1
    var list = []
    var toplevels = Hyprland.toplevels.values
    for (var i = 0; i < toplevels.length; i++) {
      var toplevel = toplevels[i]
      var ipc = toplevel.lastIpcObject
      if (!ipc || !ipc.at || !ipc.size) continue
      if (!toplevel.workspace || toplevel.workspace.id !== ws) continue
      if (ipc.hidden === true || ipc.mapped === false) continue
      if (ipc.fullscreen) continue
      var y = ipc.at[1] - hyprMonitor.y
      var x1 = ipc.at[0] - hyprMonitor.x
      var x2 = x1 + ipc.size[0]
      // Keep only tops the pet can stand on without leaving the screen, and
      // that are actually above the floor.
      if (y < root.headroom || y > root.floorY - 10) continue
      x1 = Math.max(0, x1)
      x2 = Math.min(root.width, x2)
      if (x2 - x1 < root.spriteSize * 2) continue
      // The scouter needs the client pid. Validated here, because it becomes a path
      // component in /proc/<pid>/stat and the fixed-argv invariant depends on it.
      var pid = (ipc.pid !== undefined && ipc.pid !== null) ? Number(ipc.pid) : -1
      if (!(isFinite(pid) && Math.floor(pid) === pid && pid >= 1 && pid <= 4194304)) pid = -1
      // Identity is keyed on Quickshell's `address`, which has NO 0x prefix, while
      // ipc.address is the hyprctl form (0x562ff09f8f30). Mixing them makes every cache
      // lookup silently miss and the bubble permanently blank.
      list.push({ x1: x1, x2: x2, y: y, address: toplevel.address, pid: pid })
      meta[toplevel.address] = { cls: ipc["class"] || "", title: ipc.title || "" }
    }
    platforms = list
    // Ephemeral, rebuilt every pass: an address that has gone takes its metadata with it.
    platformMeta = meta
    validateSupport()
  }

  // --- the dragon balls -------------------------------------------------------
  //
  // Deliberately NOT in the click mask. Quickshell's Region takes child regions, so adding
  // them is one line away -- and a masked ball sitting over a window would swallow desktop
  // clicks. The panel drives the interaction instead.

  readonly property var ballIndexes: (petService && petService.ballsOn)
    ? Balls.visibleIndexes(petService.ballState,
                           petService.activeWorkspaceId, petService.nowMs) : []
  function ballX(i) {
    return petService.ballState.items[i].x * root.width
  }

  // The fetch command: a latest-wins slot, consumed once, with the full admission predicate
  // re-run at every transition rather than only when it was accepted.
  property int fetchToken: 0
  property int fetchIndex: -1
  property string fetchPhase: "none"

  function fetchAdmissible() {
    if (!petService || !petService.ballsOn || !visible) return false
    if (petService.farewellPending || petService.returnRequested) return false
    if (petService.sleeping) return false
    if (action === "held" || action === "beamup") return false
    if (fetchIndex < 0 || fetchIndex >= petService.ballState.items.length) return false
    var it = petService.ballState.items[fetchIndex]
    return !it.collected && it.ws === petService.activeWorkspaceId
  }
  function cancelFetch() { fetchPhase = "none"; fetchIndex = -1 }

  Connections {
    target: root.petService ? root.petService : null
    function onFetchBallChanged() {
      var cmd = root.petService.fetchBall
      if (!cmd || cmd.nonce === root.fetchToken) return
      root.fetchToken = cmd.nonce
      root.fetchIndex = cmd.index
      // Refused outright rather than queued into a delayed surprise.
      root.fetchPhase = root.fetchAdmissible() ? "descend" : "none"
      if (root.fetchPhase === "none") root.fetchIndex = -1
    }
  }

  // Descent is its own sequence, not one fall: the existing physics can land the pet on
  // another window, or stun it, and an immediate walk would clobber that.
  function advanceFetch() {
    if (fetchPhase === "none") return
    // The token must still be the latest accepted one -- latest-wins replaces the SLOT, but
    // a command already mid-descent would otherwise finish walking to a superseded ball.
    if (!petService.fetchBall || petService.fetchBall.nonce !== fetchToken) { cancelFetch(); return }
    if (!fetchAdmissible()) { cancelFetch(); return }
    if (action === "stunned") return          // wait it out, never overwrite it
    if (fetchPhase === "descend") {
      if (action !== "idle") return
      if (support !== null) { startFall(); return }
      startWalkTo(root.ballX(fetchIndex) - root.spriteSize / 2, null)
      fetchPhase = "walk"
      return
    }
    if (fetchPhase === "walk" && action === "idle") cancelFetch()
  }

  // Collection: geometry AND lifecycle, so a stunned or beaming pet cannot collect by
  // happening to be in the right place.
  function tryCollect() {
    if (!petService || !petService.ballsOn || !visible) return
    if (support !== null) return
    if (action !== "idle" && action !== "walk") return
    if (petService.sleeping || petService.farewellPending || petService.returnRequested) return
    var mid = root.petX + root.spriteSize / 2
    for (var k = 0; k < ballIndexes.length; k++) {
      var i = ballIndexes[k]
      if (Math.abs(mid - root.ballX(i)) <= root.spriteSize) {
        petService.collectBall(i)
        return
      }
    }
  }

  Repeater {
    model: root.ballIndexes
    Image {
      required property var modelData
      source: Qt.resolvedUrl("assets/sprites/decor_dragonball.png")
      width: Math.round(root.spriteSize * 0.55)
      height: width
      x: Math.max(0, Math.min(root.width - width, root.ballX(modelData) - width / 2))
      y: root.floorY - height
      smooth: false
      mipmap: false
      visible: status === Image.Ready
    }
  }

  // --- the signature moves ----------------------------------------------------
  //
  // Deliberately NOT in the click mask, same rule as the dragon balls: Region takes child
  // regions, so adding one is a line away, and a masked beam over a window would swallow
  // desktop clicks.
  //
  // The pet's own sprite is UNTOUCHED for the whole move. A charge pose would have to be
  // drawn for every display form -- three adults, two teens and three rungs -- and making
  // `charge` a form instead would erase the pet's ki rung and Oozaru silhouette during its
  // own signature technique.

  property var activeMove: null
  property int moveToken: 0
  property int moveNonceSeen: 0
  property string movePhase: "none"          // none | charge | action | fade
  property real moveProgress: 0              // 0..1 through the action phase
  readonly property bool moveActive: activeMove !== null

  // This surface owns `action` and `support`; the service owns the rest. Both halves are
  // checked before anything is committed, and this half is re-checked on every change.
  function moveEligible() {
    if (!petService || !petService.movesReady) return false
    if (!visible || !screensSettled) return false
    if (action !== "idle") return false
    if (support !== null) return false        // on the floor, not riding a window
    if (fetchPhase !== "none") return false
    return true
  }

  // Every predicate dependency in one place, so a change to ANY of them invalidates the
  // running move. Two checkpoints at phase boundaries would leave a cancelled Kamehameha on
  // screen for the whole 1.2 s travel.
  readonly property bool moveGuard: moveEligible()

  onMoveGuardChanged: if (!moveGuard) cancelMove(moveToken)

  // The ONE function that clears moveActive, and only for a matching token: a stale
  // callback must never unstick a newer move and strand the wandering brain.
  function cancelMove(token) {
    if (token !== moveToken || activeMove === null) return
    chargeTimer.stop()
    travelAnim.stop()
    fadeTimer.stop()
    staticHold.stop()
    activeMove = null
    movePhase = "none"
    moveProgress = 0
  }

  Connections {
    target: root.petService ? root.petService : null
    function onMoveCommandChanged() {
      var cmd = root.petService.moveCommand
      if (!cmd || cmd.nonce === root.moveNonceSeen) return
      root.moveNonceSeen = cmd.nonce
      root.beginMove(cmd.id)
    }
    // Reduced motion turned on mid-move must replace the running animation with its static
    // representation immediately, not let the admitted one finish.
    function onReducedMotionChanged() {
      if (!root.moveActive) return
      // Bare ids: these are file-scope declarations, not properties of root, and writing
      // root.chargeTimer would resolve to nothing at runtime.
      chargeTimer.stop()
      travelAnim.stop()
      fadeTimer.stop()
      root.movePhase = "action"
      root.moveProgress = 0
      staticHold.interval = 1200
      staticHold.restart()
    }
  }

  function beginMove(id) {
    if (moveActive) return
    if (!moveEligible()) return
    // The handshake. The service re-checks its own half and the roster membership, and the
    // cooldown is spent only on an admitted move.
    var m = petService.tryMove(id)
    if (!m) return
    moveToken += 1
    activeMove = m
    moveProgress = 0
    if (m.reduced) {
      // A static hold, then an instantaneous hide. No animated property at all.
      movePhase = "action"
      staticHold.interval = m.timeline.total
      staticHold.restart()
      return
    }
    movePhase = "charge"
    chargeTimer.interval = m.timeline.charge
    chargeTimer.restart()
  }

  Timer {
    id: chargeTimer
    onTriggered: {
      if (!root.moveActive || root.movePhase !== "charge") return
      root.movePhase = "action"
      travelAnim.duration = root.activeMove.timeline.action
      travelAnim.restart()
    }
  }
  NumberAnimation {
    id: travelAnim
    target: root
    property: "moveProgress"
    from: 0
    to: 1
    onFinished: {
      if (!root.moveActive || root.movePhase !== "action") return
      root.movePhase = "fade"
      fadeTimer.interval = root.activeMove.timeline.fade
      fadeTimer.restart()
    }
  }
  Timer {
    id: fadeTimer
    onTriggered: root.cancelMove(root.moveToken)
  }
  Timer {
    id: staticHold
    onTriggered: root.cancelMove(root.moveToken)
  }

  // The pieces. A multi-piece geometry (Hellzone, Scattering) draws ONE sprite several
  // times along an arc rather than baking a formation into an asset.
  Repeater {
    model: root.moveActive ? root.activeMove.shape.count : 0
    delegate: Item {
      id: piece
      required property int index

      readonly property var mv: root.activeMove
      readonly property bool travels: piece.mv ? piece.mv.shape.travels : false
      readonly property bool substituted: piece.mv ? (piece.mv.reduced && piece.mv.substitute.substitute) : false

      // A piece.substituted flash sits at the shoulder at half size: "not animated" is not the
      // same as "safe", and an instant full-size flare is the luminance step reduced motion
      // is asking to be spared.
      readonly property real longSide: piece.mv
        ? root.spriteSize * (piece.substituted ? piece.mv.substitute.scale : piece.mv.shape.scale) : 0
      readonly property real shortSide: piece.mv
        ? root.spriteSize * (piece.substituted ? piece.mv.substitute.scale : piece.mv.shape.thickness) : 0

      // Staggered pieces start later, so the arc arrives as a volley.
      readonly property real localProgress: {
        if (!piece.mv || piece.mv.shape.count <= 1) return root.moveProgress
        var delay = (piece.mv.shape.stagger / Math.max(1, piece.mv.timeline.action)) * piece.index
        return Math.max(0, Math.min(1, (root.moveProgress - delay) / Math.max(0.01, 1 - delay)))
      }

      // The arc a volley fans out along, centred on the pet's facing direction.
      readonly property real spread: {
        if (!piece.mv || piece.mv.shape.count <= 1) return 0
        var half = (piece.mv.shape.count - 1) / 2
        return (piece.index - half) * root.spriteSize * 0.9
      }

      readonly property real originX: root.facingLeft
        ? root.petX - piece.longSide : root.petX + root.spriteSize
      readonly property real reach: root.facingLeft
        ? -(piece.originX + piece.longSide) : (root.width - piece.originX)

      width: piece.longSide
      height: piece.travels ? piece.shortSide : piece.longSide
      // Stationary geometries are centred ON the pet and never leave it. Giving them a
      // travel path would have slid a Kaioken aura off the monitor.
      x: piece.travels
        ? piece.originX + piece.reach * piece.localProgress
        : root.petX + root.spriteSize / 2 - piece.width / 2
        + (piece.substituted ? root.spriteSize * 0.6 * (root.facingLeft ? -1 : 1) : 0)
      y: piece.travels
        ? root.petY - root.spriteSize / 2 - piece.height / 2 + piece.spread
        : root.petY - root.spriteSize / 2 - piece.height / 2
      // The aura swells rather than piece.travels; the flash does neither.
      scale: (!piece.travels && piece.mv && piece.mv.geometry === "aura" && !piece.substituted)
        ? 1.0 + 0.6 * root.moveProgress : 1.0
      rotation: (piece.mv && piece.mv.geometry === "ring") ? root.moveProgress * 720
        : ((piece.mv && piece.mv.geometry === "spiral") ? root.moveProgress * 360 : 0)
      visible: root.moveActive && root.movePhase !== "none"
      opacity: {
        if (!root.moveActive) return 0
        if (root.activeMove.reduced) return piece.substituted ? 0.5 : 0.9
        if (root.movePhase === "charge") return 0.9 * (piece.travels ? 0.5 : 1.0)
        if (root.movePhase === "fade") return 0
        return 0.9
      }
      Behavior on opacity {
        enabled: root.moveActive && !root.activeMove.reduced
        NumberAnimation { duration: root.moveActive ? root.activeMove.timeline.fade : 0 }
      }

      Image {
        id: moveImage
        anchors.fill: parent
        source: root.moveActive
          ? Qt.resolvedUrl("assets/sprites/" + root.activeMove.sprite + ".png") : ""
        smooth: false
        mipmap: false
        fillMode: Image.Stretch
        visible: false
      }
      MultiEffect {
        anchors.fill: moveImage
        source: moveImage
        // The line's colour, applied at RUNTIME: decor assets are generated once with the
        // global palette, so this is the only place a move becomes Goku's blue or Frieza's
        // magenta. It flattens the sprite to one colour, which is why the grids are
        // silhouettes.
        colorization: 1
        colorizationColor: root.moveActive ? root.activeMove.color : "#FFFFFF"
      }
    }
  }

  // --- the rival --------------------------------------------------------------
  //
  // A second, much simpler entity: position, walk target, facing. No climbing, no support
  // tracking, no grab. It may READ the surface's geometry but must never write the pet's
  // state, and it must never enter the mask Region -- Region takes child regions, so the
  // wrong thing is one line away and would make the rival steal clicks from the desktop.

  property var rivalState: Rival.emptyState()
  readonly property string rivalPhase: rivalState.phase

  // `abort` cannot be evaluated inside the physics tick, because that timer stops when
  // visible goes false. So the abort conditions reset the rival SYNCHRONOUSLY from their
  // own handlers, and the tick only advances phases.
  // Merged into the EXISTING onVisibleChanged / onScreenChanged below: QML allows a
  // property or signal handler to be set only once, and a second declaration makes the
  // whole component unavailable.
  function resetRival() { rivalState = Rival.emptyState() }

  Connections {
    target: root.petService ? root.petService : null
    function onFarewellPendingChanged() { root.resetRival() }
    function onReturnRequestedChanged() { root.resetRival() }
    function onFullscreenActiveChanged() {
      if (root.petService && root.petService.fullscreenActive) root.resetRival()
    }
  }

  // Window class and title, keyed by the same address the platforms use. Never persisted,
  // never paired with a sample from a different address.
  property var platformMeta: ({})

  // The window the pet is sizing up. During a climb `support` is still the window being
  // LEFT, so the target is the pending destination -- and it reads null on the floor and
  // whenever the pet is not in a position to be reading anything.
  readonly property var scouterTarget: {
    if (action === "beamup" || action === "held" || action === "stunned") return null
    if (action === "climb" && pendingClimb) return pendingClimb.platform
    return support
  }
  readonly property var scouterMeta: {
    var t = scouterTarget
    return (t && platformMeta[t.address]) ? platformMeta[t.address] : null
  }

  // The world changed under the pet's feet: follow the window it stands on
  // (windows are rideable!), or fall if it vanished or slid away.
  function validateSupport() {
    if (!support) return
    for (var i = 0; i < platforms.length; i++) {
      var p = platforms[i]
      if (p.address === support.address) {
        support = p
        if (action !== "climb" && action !== "fall") {
          petY = p.y
          if (petX < p.x1 || petX + spriteSize > p.x2) startFall()
        }
        return
      }
    }
    support = null
    if (action !== "fall") startFall()
  }

  // --- pet state -------------------------------------------------------------

  property real petX: 0
  property real petY: 0            // the pet's feet line
  property string action: "idle"   // idle | walk | climb | fall
  property real targetX: 0
  property real targetY: 0
  property var pendingClimb: null  // {wallX, platform} after the walk phase
  property bool facingLeft: false

  readonly property real walkSpeed: petScale * 22   // px/s
  readonly property real climbSpeed: petScale * 16
  readonly property real fallSpeed: petScale * 110

  function currentSurfaceBounds() {
    return support
      ? { x1: support.x1, x2: support.x2 }
      : { x1: 0, x2: root.width }
  }

  function landingBelow(x, fromY) {
    var best = { y: floorY, platform: null }
    var center = x + spriteSize / 2
    for (var i = 0; i < platforms.length; i++) {
      var p = platforms[i]
      if (p.y > fromY + 1 && p.y < best.y && center >= p.x1 && center <= p.x2)
        best = { y: p.y, platform: p }
    }
    return best
  }

  // Falls from higher than this fraction of the screen leave the pet seeing
  // stars for a few seconds.
  readonly property real stunFallFraction: 0.4
  property real fallStartY: 0
  // A deliberate jump (dropping out of the panel) lands on its feet, however
  // high it was — only accidents leave the pet seeing stars.
  property bool gentleFall: false

  // Tractor beam for panel trips: a translucent cone from the card's bottom
  // that carries the pet down (and, someday, back up). Origin is frozen at
  // handoff time; the cone's mouth follows the pet's feet.
  property bool beamActive: false
  property real beamX: 0
  property real beamTopY: 0

  function startFall() {
    pendingClimb = null
    if (action !== "fall") fallStartY = petY
    action = "fall"
  }

  // The way home: the beam reaches down from the card's bottom edge and
  // pulls the pet up, wherever it is. Without a usable anchor (panel on
  // another screen), it just pops home like before.
  function startReturn() {
    var svc = petService
    if (!svc) return
    if (!(svc.handoffX >= 0) || !screen || svc.handoffScreen !== screen.name) {
      finishReturn()
      return
    }
    pendingClimb = null
    support = null
    gentleFall = false
    beamX = Math.max(spriteSize / 2,
      Math.min(width - spriteSize / 2, svc.handoffX))
    beamTopY = svc.handoffY
    // The pet pops onto the beam's axis at floor level and rides straight
    // up — the beam stays perfectly vertical.
    petX = beamX - spriteSize / 2
    petY = Math.max(beamTopY + 1, floorY)
    beamActive = true
    action = "beamup"
  }

  function finishReturn() {
    var svc = petService
    beamActive = false
    action = "idle"
    if (svc) {
      svc.returnRequested = false
      svc.handoffX = -1
      svc.handoffY = -1
      svc.handoffScreen = ""
      svc.arrivedHome()
      svc.setRoamEnabled(false)
    }
  }

  Connections {
    target: root.petService
    function onReturnRequestedChanged() {
      if (!root.petService.returnRequested || !root.visible) return
      if (root.screen && root.petService.handoffScreen === root.screen.name) {
        root.startReturn()
        return
      }
      // A cross-screen Come home first moves the playground onto the panel's
      // screen, and that surface hop is asynchronous — wait for it to land
      // before anchoring the beam instead of popping home on the mismatch.
      returnWait.tries = 0
      returnWait.restart()
    }
  }

  Timer {
    id: returnWait
    interval: 100
    repeat: true
    property int tries: 0
    onTriggered: {
      var svc = root.petService
      if (!svc || !svc.returnRequested) { stop(); return }
      if (root.screen && svc.handoffScreen === root.screen.name) {
        stop()
        root.startReturn()
      } else if (++tries > 15) {
        // The playground never made it over: pop home like before.
        stop()
        root.finishReturn()
      }
    }
  }

  Timer {
    id: stunTimer
    interval: 3000
    onTriggered: if (root.action === "stunned") root.action = "idle"
  }

  function startWalkTo(x, climb) {
    var bounds = currentSurfaceBounds()
    targetX = Math.max(bounds.x1, Math.min(bounds.x2 - spriteSize, x))
    pendingClimb = climb || null
    facingLeft = targetX < petX
    action = "walk"
  }

  // Climbable walls from here: edges of platforms strictly above whose base
  // is reachable by walking on the current surface.
  function climbCandidates() {
    var bounds = currentSurfaceBounds()
    var found = []
    for (var i = 0; i < platforms.length; i++) {
      var p = platforms[i]
      if (support && p.address === support.address) continue
      if (p.y >= petY - spriteSize) continue
      if (p.x1 >= bounds.x1 && p.x1 <= bounds.x2 - spriteSize)
        found.push({ wallX: p.x1, platform: p })
      else if (p.x2 - spriteSize >= bounds.x1 && p.x2 <= bounds.x2)
        found.push({ wallX: p.x2 - spriteSize, platform: p })
    }
    return found
  }

  // --- physics ---------------------------------------------------------------

  Timer {
    id: physics
    interval: 40
    running: root.visible
    repeat: true
    onTriggered: {
      var dt = interval / 1000
      // The rival rides THIS tick as a second branch: one clock, one visibility gate. It
      // reads the pet's position and never writes any of the pet's state.
      if (root.petService && root.petService.rivalPossible) {
        root.rivalState = Rival.next(root.rivalState, root.petX, interval,
                                     root.petService.rivalEncounter,
                                     root.petService.farewellPending === true
                                     || root.petService.fullscreenActive === true)
      } else if (root.rivalState.phase !== "none") {
        root.resetRival()
      }

      root.advanceFetch()
      root.tryCollect()

      if (root.action === "walk") {
        var step = root.walkSpeed * dt
        if (Math.abs(root.targetX - root.petX) <= step) {
          root.petX = root.targetX
          if (root.pendingClimb) {
            root.targetY = root.pendingClimb.platform.y
            root.action = "climb"
          } else {
            root.action = "idle"
          }
        } else {
          root.petX += root.petX < root.targetX ? step : -step
        }
      } else if (root.action === "climb") {
        var rise = root.climbSpeed * dt
        if (root.petY - root.targetY <= rise) {
          root.petY = root.targetY
          root.support = root.pendingClimb ? root.pendingClimb.platform : root.support
          root.pendingClimb = null
          root.action = "idle"
        } else {
          root.petY -= rise
        }
      } else if (root.action === "beamup") {
        var pull = root.fallSpeed * dt
        if (root.petY - root.beamTopY <= pull) root.finishReturn()
        else root.petY -= pull
      } else if (root.action === "fall") {
        var landing = root.landingBelow(root.petX, root.petY)
        var drop = root.fallSpeed * dt
        if (landing.y - root.petY <= drop) {
          root.petY = landing.y
          root.support = landing.platform
          if (!root.gentleFall
              && root.petY - root.fallStartY > root.height * root.stunFallFraction) {
            root.action = "stunned"
            stunTimer.restart()
            if (root.petService) root.petService.stunShock()
            root.hardLanding(root.petX + root.spriteSize / 2, root.petY)
          } else {
            root.action = "idle"
          }
          root.gentleFall = false
          root.beamActive = false
        } else {
          root.petY += drop
        }
      }
    }
  }

  // --- the farewell walk -----------------------------------------------------
  // Phases: 0 get down to the floor and head for the nearest corner,
  // 1 arrived — say goodbye, 2 walk off the screen, then the service
  // hatches the next generation.
  property int leavingPhase: 0
  property real leavingCornerX: 0

  function advanceFarewell() {
    var svc = petService
    if (!svc || !svc.farewellPending) { leavingPhase = 0; return }
    if (action !== "idle") return
    if (leavingPhase === 0) {
      if (support) { startFall(); return }
      leavingCornerX = petX + spriteSize / 2 < width / 2 ? 0 : width - spriteSize
      leavingPhase = 1
      if (Math.abs(leavingCornerX - petX) > 1) startWalkTo(leavingCornerX, null)
    } else if (leavingPhase === 1) {
      leavingPhase = 2
      facingLeft = leavingCornerX > 0
      svc.playSound(svc.farewellSoundEvent())
      goodbyeTimer.restart()
    } else if (leavingPhase === 3) {
      leavingPhase = 0
      svc.sendOff()
    }
  }

  Timer {
    id: goodbyeTimer
    interval: 1800
    onTriggered: {
      if (root.leavingPhase !== 2) return
      root.leavingPhase = 3
      // Past the clamp on purpose: the target is just beyond the edge.
      root.targetX = root.leavingCornerX > 0 ? root.width + 4 : -root.spriteSize - 4
      root.facingLeft = root.leavingCornerX === 0
      root.pendingClimb = null
      root.action = "walk"
    }
  }

  Timer {
    interval: 200
    running: root.visible && !!root.petService && root.petService.farewellPending
    repeat: true
    onTriggered: root.advanceFarewell()
  }

  Connections {
    target: root.petService
    function onFarewellPendingChanged() {
      if (!root.petService.farewellPending) root.leavingPhase = 0
    }
  }

  // --- the wandering brain ---------------------------------------------------

  Timer {
    id: brain
    interval: 1500
    running: root.visible && root.action === "idle" && !root.moveActive
      && !(root.petService && (root.petService.sleeping || root.petService.farewellPending))
    repeat: true
    onTriggered: {
      interval = 2500 + Math.floor(Math.random() * 5000)
      var roll = Math.random()
      var climbs = root.climbCandidates()

      if (roll < 0.25 && climbs.length > 0) {
        var pick = climbs[Math.floor(Math.random() * climbs.length)]
        root.startWalkTo(pick.wallX, pick)
      } else if (roll < 0.40 && root.support) {
        // Hop off the current window.
        root.startFall()
      } else if (roll < 0.85) {
        var bounds = root.currentSurfaceBounds()
        var span = Math.max(0, bounds.x2 - bounds.x1 - root.spriteSize)
        root.startWalkTo(bounds.x1 + Math.random() * span, null)
      }
      // else: lazing around is also living.
    }
  }

  // --- keeping up with the compositor ---------------------------------------

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      switch (event.name) {
      case "openwindow":
      case "closewindow":
      case "movewindow":
      case "movewindowv2":
      case "resizewindow":
      case "workspace":
      case "workspacev2":
      case "changefloatingmode":
      case "fullscreen":
      case "focusedmon":
        refreshDebounce.restart()
      }
    }
  }

  Timer {
    id: refreshDebounce
    interval: 250
    onTriggered: {
      Hyprland.refreshToplevels()
      rebuildDelay.restart()
    }
  }
  // lastIpcObject updates arrive shortly after the refresh request.
  Timer {
    id: rebuildDelay
    interval: 350
    onTriggered: root.rebuildPlatforms()
  }
  // Fallback sweep for anything the event filter misses.
  Timer {
    interval: 7000
    running: root.visible
    repeat: true
    onTriggered: refreshDebounce.restart()
  }

  function resetPosition() {
    support = null
    pendingClimb = null
    var svc = petService
    var w = width > 0 ? width : (screen ? screen.width : 0)
    if (svc && svc.returnRequested) {
      // Mid Come-home hop between screens: the freshly landed surface must
      // not mistake the pending handoff for an exit (beam-in) — stand by on
      // the floor and leave the handoff for the return sequence to consume.
      beamActive = false
      petX = Math.max(0, w / 2 - spriteSize / 2)
      petY = floorY
      action = "idle"
      refreshDebounce.restart()
      return
    }
    if (svc && svc.handoffX >= 0 && screen && svc.handoffScreen === screen.name) {
      // The pet just dropped out of its panel: continue that fall from right
      // under the card instead of teleporting to the floor.
      petX = Math.max(0, Math.min(w - spriteSize, svc.handoffX - spriteSize / 2))
      petY = Math.max(headroom, Math.min(floorY > 0 ? floorY : svc.handoffY, svc.handoffY))
      beamX = petX + spriteSize / 2
      beamTopY = svc.handoffY
      beamActive = true
      gentleFall = true
      startFall()
    } else {
      beamActive = false
      petX = Math.max(0, w / 2 - spriteSize / 2)
      petY = floorY
      action = "idle"
    }
    if (svc) {
      svc.handoffX = -1
      svc.handoffY = -1
      svc.handoffScreen = ""
    }
    refreshDebounce.restart()
  }

  // The window can be born visible, so onVisibleChanged alone never fires;
  // and the real height only arrives once the surface is mapped, so the floor
  // glue keeps the pet grounded instead of hovering at y 0.
  Component.onCompleted: resetPosition()
  onVisibleChanged: { if (visible) resetPosition(); else { leavingPhase = 0; resetRival() } }
  onFloorYChanged: {
    if (action === "idle" && !support && Math.abs(petY - floorY) > 1)
      petY = floorY
  }

  // --- the pet ---------------------------------------------------------------

  // The tractor beam: a soft cone widening from the card's bottom edge down
  // to the pet's feet, spaceship style. Purely visual — the click mask only
  // covers the sprite, so the beam stays click-through.
  Shape {
    id: beam
    anchors.fill: parent
    visible: opacity > 0.01
    // The fade target must stay constant while active: feeding an animated
    // value through the Behavior restarts it every frame and the fade
    // livelocks at 0. The shimmer lives in the gradient alpha instead.
    opacity: root.beamActive ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 300 } }
    preferredRendererType: Shape.CurveRenderer

    // A slow breathing shimmer while the beam is on.
    property real beamPulse: 1
    SequentialAnimation {
      running: root.beamActive
      loops: Animation.Infinite
      NumberAnimation { target: beam; property: "beamPulse"; to: 0.7; duration: 500 }
      NumberAnimation { target: beam; property: "beamPulse"; to: 1.0; duration: 500 }
      onStopped: beam.beamPulse = 1
    }

    ShapePath {
      strokeWidth: -1
      fillGradient: LinearGradient {
        x1: root.beamX; y1: root.beamTopY
        x2: root.beamX; y2: root.petY
        GradientStop { position: 0; color: Qt.alpha(Color.accent, 0.5 * beam.beamPulse) }
        GradientStop { position: 1; color: Qt.alpha(Color.accent, 0.08 * beam.beamPulse) }
      }
      startX: root.beamX - root.spriteSize * 0.3
      startY: root.beamTopY
      PathLine { x: root.beamX + root.spriteSize * 0.3; y: root.beamTopY }
      PathLine { x: root.beamX + root.spriteSize * 0.9; y: root.petY }
      PathLine { x: root.beamX - root.spriteSize * 0.9; y: root.petY }
    }
  }

  // --- the Yamcha crater -----------------------------------------------------
  // One crater at a time: a second hard landing MOVES it rather than littering the screen
  // with every dent the pet has ever made. It fades on its own so a pet having a bad
  // afternoon does not permanently scar the desktop.
  Image {
    id: crater
    source: Qt.resolvedUrl("assets/sprites/decor_crater.png")
    smooth: false
    fillMode: Image.PreserveAspectFit
    width: root.spriteSize * 1.6
    height: width * (implicitHeight > 0 ? implicitHeight / implicitWidth : 0.33)
    // Anchored on the impact point, sunk slightly so the pet's feet sit inside the rim.
    x: craterX - width / 2
    y: craterY - height * 0.6
    z: sprite.z - 1
    visible: opacity > 0
    opacity: 0

    property real craterX: 0
    property real craterY: 0

    function markAt(px, py) {
      craterX = px
      craterY = py
      opacity = 0.85
      craterLife.restart()
    }

    // Two stages so the dent sits there long enough to be noticed, then leaves quietly.
    Behavior on opacity { NumberAnimation { duration: 900; easing.type: Easing.InOutQuad } }
  }

  Timer {
    id: craterLife
    interval: 12000
    repeat: false
    onTriggered: crater.opacity = 0
  }

  Connections {
    target: root
    function onHardLanding(x, y) { crater.markAt(x, y) }
  }

  // A crater belongs to the ground it was made in. When the window moves to another output
  // -- roamScreen changed, or the named screen was unplugged and the binding fell through
  // -- the old dent is on a surface that is no longer here, so it goes with it.
  onScreenChanged: {
    resetRival()
    crater.opacity = 0
    craterLife.stop()
  }

  PetSprite {
    id: sprite
    width: root.spriteSize
    height: root.spriteSize
    x: root.petX
    y: root.petY - height
    // Dedicated climb frames are drawn upright (back to us, arms reaching);
    // only the walk-frame fallback needs the old -90° tilt.
    rotation: root.action === "climb" && sprite.resolvedAnim !== "climb" ? -90
      : (root.action === "held" ? 12 : 0)
    Behavior on rotation { NumberAnimation { duration: 150 } }

    Image {
      id: halo
      source: Qt.resolvedUrl("assets/sprites/decor_halo.png")
      smooth: false
      fillMode: Image.PreserveAspectFit
      width: parent.width * 0.55
      height: width * (implicitHeight > 0 ? implicitHeight / implicitWidth : 0.4)
      x: (parent.width - width) / 2
      y: -height * 1.2
      // Only while out cold. It rides the sprite, so it tilts with the held/climb rotation.
      visible: root.action === "stunned"
      opacity: visible ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 250 } }
    }

    readonly property bool asleep: root.petService && root.petService.sleeping
    form: root.serviceReady ? root.petService.displayForm : Lines.PLACEHOLDER_SPRITE
    baseForm: root.serviceReady ? root.petService.baseSprite : Lines.PLACEHOLDER_SPRITE
    variantSuffix: root.serviceReady ? root.petService.variantSuffix : ""
    colorize: false
    auraEnabled: root.serviceReady && root.petService.auraEnabled
    auraColor: root.serviceReady ? root.petService.auraColor : "transparent"
    auraPulse: root.serviceReady && root.petService.auraPulse
    // The roaming pet is the biggest it gets and has the whole screen to glow into.
    auraPadding: 16
    anim: {
      if (asleep) return "sleep"
      switch (root.action) {
      case "walk":
      case "fall":
      case "held": return "walk" // held: legs kicking in protest
      case "climb": return "climb"
      case "stunned": return "stunned"
      default: return root.petService.transientAnim !== ""
        ? root.petService.transientAnim
        : root.petService.stateAnim
      }
    }
    // A climb without its dedicated sprite reuses the walk frames (rotated).
    fallbackAnim: root.action === "climb" ? "walk" : "idle"
    frameMs: asleep ? 1200 : (root.action === "idle" ? 500 : 220)
    tint: Color.foreground
    mirrored: root.facingLeft

    // Click = pet; press-and-move = pick it up by the scruff and carry it.
    // Once pressed, the Wayland implicit grab keeps pointer events coming to
    // this surface even when the cursor leaves the click mask, so the drag
    // survives crossing other windows.
    MouseArea {
      id: grabArea
      anchors.fill: parent
      // A stunned pet is too dizzy to be petted or picked up, and the
      // tractor beam's pull is irresistible.
      enabled: root.action !== "stunned" && root.action !== "beamup"
        && !(root.petService && root.petService.farewellPending)
      cursorShape: root.action === "held" ? Qt.ClosedHandCursor : Qt.PointingHandCursor

      property real grabDx: 0
      property real grabDy: 0
      property real pressGlobalX: 0
      property real pressGlobalY: 0
      property bool dragging: false

      onPressed: function(mouse) {
        var p = mapToItem(root.contentItem, mouse.x, mouse.y)
        pressGlobalX = p.x
        pressGlobalY = p.y
        grabDx = p.x - root.petX
        grabDy = p.y - (root.petY - root.spriteSize)
        dragging = false
      }
      onPositionChanged: function(mouse) {
        if (!pressed) return
        var p = mapToItem(root.contentItem, mouse.x, mouse.y)
        if (!dragging) {
          if (Math.abs(p.x - pressGlobalX) < 8 && Math.abs(p.y - pressGlobalY) < 8) return
          dragging = true
          root.action = "held"
          root.pendingClimb = null
          root.support = null
          root.gentleFall = false
          root.beamActive = false
          if (root.petService) {
            root.petService.wakeUp()
            root.petService.playSound("grab")
          }
        }
        root.petX = Math.max(0, Math.min(root.width - root.spriteSize, p.x - grabDx))
        root.petY = Math.max(root.headroom,
          Math.min(root.floorY, p.y - grabDy + root.spriteSize))
      }
      onReleased: {
        if (dragging) {
          dragging = false
          // A small lift so a drop aimed at a window border lands on it
          // instead of slipping just past its top edge.
          root.petY = Math.max(root.headroom, root.petY - 6)
          root.startFall()
        } else {
          if (root.petService) root.petService.petThePet()
          heart.pop()
        }
      }
      // A grab broken by the compositor must not leave the pet floating
      // midair in the held pose.
      onCanceled: {
        if (dragging) {
          dragging = false
          root.startFall()
        }
      }
    }
  }

  // The shared emote bubble: one 16x16 white glyph per state, floating above
  // the head, tinted urgent when the need turns critical. A missing emote
  // file simply hides the bubble (Image.Error), so they can land one by one.
  // While stunned, the complaint bubble yields to the orbiting stars.
  readonly property string emoteName: {
    if (!petService || action === "stunned") return ""
    return petService.emoteName
  }

  // The rival. Its own line's BASE form only: the remote feed reports free/resident_idle/
  // generating, not a ki rung, so rendering it transformed would assert a power level
  // nobody measured -- on a second entity, breaking the honesty rule twice over.
  PetSprite {
    id: rivalSprite
    visible: root.rivalState.phase !== "none" && root.petService
      && root.petService.rivalPossible
    width: root.spriteSize
    height: root.spriteSize
    x: root.rivalState.rivalX
    y: root.floorY - root.spriteSize
    // Guarded on rivalPossible, which requires BOTH a line and a form. Checking only the
    // line composed "piccolo_" + "" during startup -- stage is still the default "egg"
    // before the save loads, so formFor() returns nothing -- and asked for
    // "piccolo__walk_a". An empty component in a sprite name is the same class of bug that
    // shipped twice before, and it is only ever visible in the journal.
    form: root.petService && root.petService.rivalPossible
      ? root.petService.rivalLine + "_" + root.petService.rivalForm
      : Lines.PLACEHOLDER_SPRITE
    baseForm: form
    colorize: false
    // Idle while not possible: the placeholder has no walk frames, so asking for them is
    // journal noise for a sprite nobody can see.
    anim: (root.petService && root.petService.rivalPossible
           && root.rivalState.phase !== "facing") ? "walk" : "idle"
    fallbackAnim: "idle"
    frameMs: root.rivalState.phase === "facing" ? 500 : 220
    tint: Color.foreground
    mirrored: root.rivalState.facingLeft
  }

  // The scouter bubble. PlainText is not optional: a window title is attacker-controlled by
  // any page a tab visits, and nothing else in this plugin sets textFormat.
  Item {
    id: scouterBubble
    visible: root.petService && root.petService.scouterLabel !== ""
      && root.action !== "held" && root.action !== "stunned"
    width: scouterText.implicitWidth + 8
    height: scouterText.implicitHeight + 4
    x: Math.max(0, Math.min(root.width - width,
                            root.petX + Math.round(root.spriteSize * 0.5)))
    y: root.petY - root.spriteSize - height - 4

    Rectangle {
      anchors.fill: parent
      radius: 3
      color: "#B0000000"
    }
    Text {
      id: scouterText
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: root.petService ? root.petService.scouterLabel : ""
      color: "#66E0FF"
      font.pixelSize: Math.max(8, Math.round(root.spriteSize / 4))
      renderType: Text.NativeRendering
    }
  }

  Item {
    id: emote
    visible: root.emoteName !== "" && root.action !== "held"
      && emoteImage.status === Image.Ready
    width: Math.round(root.spriteSize * 0.75)
    height: width
    x: root.petX + Math.round(root.spriteSize * 0.7)
    y: root.petY - root.spriteSize - height + bob

    property real bob: 0
    SequentialAnimation on bob {
      running: emote.visible
      loops: Animation.Infinite
      NumberAnimation { from: 0; to: -4; duration: 900; easing.type: Easing.InOutQuad }
      NumberAnimation { from: -4; to: 0; duration: 900; easing.type: Easing.InOutQuad }
    }

    Image {
      id: emoteImage
      anchors.fill: parent
      source: root.emoteName !== ""
        ? Qt.resolvedUrl("assets/sprites/" + root.emoteName + ".png") : ""
      smooth: false
      mipmap: false
      fillMode: Image.PreserveAspectFit
      visible: false
    }

    MultiEffect {
      anchors.fill: emoteImage
      source: emoteImage
      colorization: 1
      // Same tint as the pet, one creature one color.
      colorizationColor: Color.foreground
    }
  }

  // Knocked-out stars: three copies of the star sprite orbiting the head on a
  // flattened ellipse, phased 120° apart. The one swinging "behind" the head
  // shrinks and dims for depth. Pure code — the artist only drew one star.
  Item {
    id: stunStars
    visible: root.action === "stunned"

    property real angle: 0
    NumberAnimation on angle {
      running: stunStars.visible
      from: 0; to: 360
      duration: 1100
      loops: Animation.Infinite
    }

    Repeater {
      model: 3

      Item {
        id: star
        required property int index
        readonly property real theta: (stunStars.angle + star.index * 120) * Math.PI / 180
        readonly property real depth: (Math.sin(theta) + 1) / 2 // 0 = behind, 1 = front

        width: Math.round(root.spriteSize * 0.35)
        height: width
        x: root.petX + root.spriteSize / 2 + Math.cos(theta) * root.spriteSize * 0.6 - width / 2
        y: root.petY - root.spriteSize - height / 2 + Math.sin(theta) * root.spriteSize * 0.16
        opacity: 0.4 + 0.6 * depth
        scale: 0.7 + 0.3 * depth

        Image {
          id: starImage
          anchors.fill: parent
          source: Qt.resolvedUrl("assets/sprites/emote_stunned.png")
          smooth: false
          mipmap: false
          fillMode: Image.PreserveAspectFit
          visible: false
        }

        MultiEffect {
          anchors.fill: starImage
          source: starImage
          colorization: 1
          colorizationColor: Color.foreground
        }
      }
    }
  }

  Text {
    text: "z z Z"
    visible: root.petService && root.petService.sleeping
    color: Color.foreground
    font.pixelSize: Math.max(11, root.spriteSize / 3)
    x: root.petX + root.spriteSize
    y: root.petY - root.spriteSize - height / 2

    SequentialAnimation on opacity {
      running: visible
      loops: Animation.Infinite
      NumberAnimation { from: 0.25; to: 1; duration: 1300 }
      NumberAnimation { from: 1; to: 0.25; duration: 1300 }
    }
  }

  // A small thank-you heart when petted. The overlay is full-screen now, so
  // it has all the headroom it wants.
  Text {
    id: heart
    text: "♥"
    color: Color.accent
    font.pixelSize: Math.max(12, root.spriteSize / 3)
    x: root.petX + root.spriteSize / 2 - width / 2
    opacity: 0

    property real rise: 0
    y: root.petY - root.spriteSize - height - rise

    function pop() { heartAnimation.restart() }

    ParallelAnimation {
      id: heartAnimation
      NumberAnimation { target: heart; property: "rise"; from: 0; to: root.spriteSize; duration: 700 }
      SequentialAnimation {
        NumberAnimation { target: heart; property: "opacity"; from: 0; to: 1; duration: 150 }
        NumberAnimation { target: heart; property: "opacity"; to: 0; duration: 550 }
      }
    }
  }
}
