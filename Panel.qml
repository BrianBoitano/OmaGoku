pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import QtQuick.Shapes
import Quickshell
import qs.Commons
import qs.Ui
import "lines.js" as Lines
import "lineagepane.js" as LineagePane
import "room.js" as Room

// The pet's home: a card with the pet front and center, its needs as bars,
// and the care actions. Every action maps to real system maintenance.
Panel {
  id: root
  moduleName: "brianboitano.omagoku"

  // One panel instance exists per bar; only the largest screen's instance
  // claims the IPC target, so `qs ipc call brianboitano.omagoku toggle` acts
  // on a predictable panel instead of whichever instance registered first.
  readonly property var panelScreen: anchorItem && anchorItem.QsWindow.window
    ? anchorItem.QsWindow.window.screen : null
  readonly property var mainScreen: {
    var best = null
    var screens = Quickshell.screens
    for (var i = 0; i < screens.length; i++) {
      if (!best || screens[i].width * screens[i].height > best.width * best.height)
        best = screens[i]
    }
    return best
  }
  ipcTarget: panelScreen && panelScreen === mainScreen ? moduleName : ""

  property var anchorItem: null
  property var hostWidget: null
  property var petService: null
  readonly property var barIdentity: hostWidget || root

  readonly property bool ready: !!petService && petService.initialized === true
  // Out roaming = not home: the plate stays empty while it plays outside.
  readonly property bool petIsOut: ready && petService.roaming === true
  readonly property bool lineChosen: ready && petService.line !== ""
  // ONE property, so the list does not grow by twelve bindings every time a pane is added.
  // settingsControl.open is never reset when the panel closes, so without explicit mutual
  // exclusion both flags could be true at once.
  readonly property bool anyPaneOpen: settingsControl.open || lineagePane.open
  readonly property color foreground: Color.popups.text
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property var needs: ready ? [
    { label: "Hunger", value: petService.hunger,
      hint: petService.pendingUpdates > 0
        ? "rising faster: " + petService.pendingUpdates + " updates pending"
        : "rises over time",
      action: "feed", actionLabel: "Senzu bean", needsHome: true,
      actionTip: petService.stage === "egg" ? "Still in the pod — nothing to feed yet"
        : petService.eating ? "Nom nom nom…"
        : petIsOut ? "It's out training — call it home first"
        : "One senzu bean, hunger back to zero" },
    { label: "Healing tank", value: petService.dirtiness,
      hint: petIsOut ? "top it up at home: press and scrub it with your mouse"
        : "press and scrub it with your mouse to run the tank",
      action: "", actionLabel: "", actionTip: "" },
    { label: "Gravity chamber", value: petService.tiredness,
      hint: petService.sleeping
        ? "resting in the Hyperbolic Time Chamber…" : "sleeps it off when spent",
      action: "", actionLabel: "", actionTip: "" },
    { label: "Fun", value: petService.boredom, hint: "the Nimbus cures boredom",
      action: "", actionLabel: "", actionTip: "" },
    { label: "Sparring", value: petService.loneliness, hint: "click the pet!",
      action: "", actionLabel: "", actionTip: "" }
  ] : []

  // Going out is staged: the pet visibly slides down out of its room, drops
  // through the card, and only then does roaming actually start — with the
  // exit spot handed to RoamWindow so the fall continues under the panel.
  // Coming home mirrors it: the beam pulls the pet up to the card, then it
  // rises back into its room.
  property bool exiting: false
  property bool entering: false

  // "90h 56m" reads badly past a few days: break the age into y/mo/d/h/m
  // from the largest non-zero unit. Pet time: a month is 30 active days and
  // a year is 12 of those, so units always roll over cleanly.
  function ageLabel(minutes) {
    var left = Math.floor(minutes)
    var units = [
      { size: 518400, suffix: "y" },
      { size: 43200, suffix: "mo" },
      { size: 1440, suffix: "d" },
      { size: 60, suffix: "h" },
      { size: 1, suffix: "m" }
    ]
    var parts = []
    for (var i = 0; i < units.length; i++) {
      var n = Math.floor(left / units[i].size)
      left -= n * units[i].size
      if (parts.length === 0 && n === 0 && i < units.length - 1) continue
      parts.push(n + units[i].suffix)
    }
    return parts.join(" ")
  }

  function runAction(kind) {
    if (!ready) return
    if (kind === "feed") petService.feedNow()
    else if (kind === "roam") {
      if (petService.settings.roamEnabled === true) beginReturn()
      else beginExit()
    }
  }

  function beginReturn() {
    if (petService.returnRequested) return
    // Same anchor as the exit: the beam hangs from the card's bottom edge,
    // centered under the room.
    var center = petRoom.mapToItem(null, petRoom.width / 2, 0)
    var cardBottom = keyCatcher.mapToItem(null, 0, keyCatcher.height).y
    petService.handoffX = center.x
    petService.handoffY = cardBottom
    petService.handoffScreen = panelScreen ? panelScreen.name : ""
    // Declare the return BEFORE pulling the playground onto this screen:
    // the surface hop replays resetPosition, which must already know a
    // return is pending or it mistakes the handoff for an exit beam-in.
    petService.returnRequested = true
    petService.requestedScreenName = petService.handoffScreen
    petService.playBeamSound(true)
  }

  Connections {
    target: root.ready ? root.petService : null
    function onArrivedHome() { root.playEntrance() }
  }

  function playEntrance() {
    if (!opened || !ready) return
    entering = true
    exitPet.x = (petRoom.width - exitPet.width) / 2
    exitPet.y = petRoom.height
    enterAnim.restart()
  }

  function beginExit() {
    if (exiting || !ready) return
    petService.wakeUp()
    exiting = true
    petService.playBeamSound()
    var start = petRoom.mapToItem(exitOverlay,
      (petRoom.width - exitPet.width) / 2, (petRoom.height - exitPet.height) / 2)
    exitPet.x = start.x
    exitPet.y = start.y
    exitPet.slideToY = petRoom.mapToItem(exitOverlay, 0, petRoom.height).y
    exitAnim.restart()
  }

  function finishExit() {
    if (!exiting) return
    exiting = false
    if (!ready) return
    // The panel surface is a full-screen layer shell, so scene coordinates
    // are screen coordinates. The sprite disappeared behind the card at the
    // room's edge, so the fall resumes under the card's bottom, not where
    // the sprite actually stopped.
    var feetX = exitPet.mapToItem(null, exitPet.width / 2, 0).x
    var cardBottom = keyCatcher.mapToItem(null, 0, keyCatcher.height).y
    petService.handoffX = feetX
    petService.handoffY = cardBottom
    petService.handoffScreen = panelScreen ? panelScreen.name : ""
    // The pet goes out on the screen it was sent out from.
    petService.requestedScreenName = petService.handoffScreen
    petService.setRoamEnabled(true)
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    padding: Style.space(14)
    contentWidth: panel.fittedContentWidth(Style.space(410))
    // The card sizes itself from the actual content, plus breathing room at
    // the bottom. fittedContentHeight adds the card's own padding and border
    // inset — contentHeight includes them, so feeding it a raw content height
    // silently shaves that inset off the content area instead.
    contentHeight: panel.fittedContentHeight(contentColumn.implicitHeight + Style.space(16))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: contentColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // The roster. Shown only while the pod is unclaimed; choosing is what starts the
        // pet's clock, so there is nothing else to show here.
        ColumnLayout {
          width: parent.width
          visible: root.ready && root.petService.line === ""
          spacing: Style.space(8)

          Text {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            text: "A pod has landed. Whose is it?"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.Wrap
            renderType: Text.NativeRendering
          }

          Repeater {
            model: Lines.ids()
            delegate: Rectangle {
              id: lineCard
              required property string modelData
              Layout.fillWidth: true
              // Grows with the wrapped blurb; a fixed height clipped the second line.
              Layout.preferredHeight: Math.max(Style.space(44),
                                               cardText.implicitHeight + Style.space(12))
              color: cardMouse.containsMouse
                ? Qt.alpha(Color.accent, 0.18) : Qt.alpha(root.foreground, 0.06)
              border.color: cardMouse.containsMouse
                ? Color.accent : Qt.alpha(root.foreground, 0.15)
              radius: Style.space(3)

              Row {
                id: cardRow
                anchors.fill: parent
                anchors.margins: Style.space(6)
                spacing: Style.space(8)

                Image {
                  id: cardArt
                  anchors.verticalCenter: parent.verticalCenter
                  width: Style.space(32)
                  height: Style.space(32)
                  source: Qt.resolvedUrl("assets/sprites/" + lineCard.modelData
                                         + "_adult_ace_idle_a.png")
                  smooth: false
                  fillMode: Image.PreserveAspectFit
                }

                Column {
                  id: cardText
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)
                  // The blurbs are whole sentences. Without an explicit width a Text sizes
                  // itself to its content, so the line ran off the edge of the panel instead
                  // of wrapping inside the card.
                  width: cardRow.width - cardArt.width - cardRow.spacing

                  Text {
                    width: cardText.width
                    text: Lines.nameFor(lineCard.modelData, 1)
                    elide: Text.ElideRight
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    renderType: Text.NativeRendering
                  }
                  Text {
                    width: cardText.width
                    wrapMode: Text.Wrap
                    text: Lines.blurbFor(lineCard.modelData)
                    color: Qt.alpha(root.foreground, 0.6)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    renderType: Text.NativeRendering
                  }
                }
              }

              MouseArea {
                id: cardMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.petService.chooseLine(lineCard.modelData)
              }
            }
          }
        }

        // --- the pet -------------------------------------------------------

        Rectangle {
          id: petRoom
          width: parent.width
          height: Style.space(150)
          // Named explicitly rather than anyPaneOpen: the pet deliberately stays visible
          // behind the settings pane, and only the full-height record replaces it.
          visible: root.lineChosen && !lineagePane.open
          radius: Style.cornerRadius > 0 ? Style.space(10) : 0
          color: Qt.alpha(Color.accent, 0.08)
          border.width: 1
          border.color: Qt.alpha(Color.accent, 0.25)

          Text {
            anchors.centerIn: parent
            visible: root.petIsOut
            text: "Out training…"
            color: Qt.alpha(root.foreground, 0.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            renderType: Text.NativeRendering
          }

          // --- the decor ---------------------------------------------------
          // The room's furniture now comes from room.js as ONE computed list, so a level
          // unlock can actually appear. Pieces are decor_<name>.png sprites of ANY size;
          // one that is not drawn yet simply does not render, so the set can grow sprite by
          // sprite. x/y are fractions of the room; px is the zoom applied to the sprite's
          // own pixels. The room stays furnished while the pet is out.

          // The room itself, chosen by generation rather than by stage: the bloodline moves
          // house, the pet growing up does not. Drawn behind everything, dim, and left
          // tinted so it reads as a backdrop instead of competing with the pet.
          Image {
            id: roomBackdrop
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Style.space(4)
            source: root.ready
              ? Qt.resolvedUrl("assets/sprites/decor_" + root.petService.roomName + ".png")
              : ""
            smooth: false
            fillMode: Image.PreserveAspectFit
            width: Math.min(parent.width * 0.92, implicitWidth * Style.space(2))
            height: implicitWidth > 0 ? width * implicitHeight / implicitWidth : 0
            visible: status === Image.Ready
            opacity: 0.35
            z: -1
          }

          // ONE computed list: stage furniture, the reserved keepsake slot, then the
          // level unlocks in ascending order. The old static lookup could not carry an
          // unlock at all -- it would have been in every room or in none.
          Repeater {
            model: root.ready
              ? Room.decor(root.petService.form, root.petService.stage,
                           root.petService.level, root.petService.keepsakeEarned)
              : []
            delegate: Item {
              id: decorItem
              required property var modelData
              // Clamped so a large sprite can never spill past the room walls.
              x: Math.min(petRoom.width * modelData.x,
                          petRoom.width - decorItem.width - Style.space(6))
              y: Math.min(petRoom.height * modelData.y,
                          petRoom.height - decorItem.height - Style.space(6)) - hop
              width: Style.space(decorImage.status === Image.Ready
                ? decorImage.implicitWidth * modelData.px : 0)
              height: Style.space(decorImage.status === Image.Ready
                ? decorImage.implicitHeight * modelData.px : 0)
              visible: decorImage.status === Image.Ready

              // A hanging piece sways gently around its attachment point.
              property real swayAngle: 0
              transform: Rotation {
                origin.x: decorItem.width / 2
                origin.y: 0
                angle: decorItem.swayAngle
              }
              SequentialAnimation {
                running: decorItem.visible && decorItem.modelData.sway === true
                loops: Animation.Infinite
                NumberAnimation { target: decorItem; property: "swayAngle"
                  to: 5; duration: 1900; easing.type: Easing.InOutSine }
                NumberAnimation { target: decorItem; property: "swayAngle"
                  to: -5; duration: 1900; easing.type: Easing.InOutSine }
              }

              // A toy bounces when clicked: two hops, the second smaller.
              property real hop: 0
              SequentialAnimation {
                id: bounceAnim
                NumberAnimation { target: decorItem; property: "hop"
                  to: Style.space(22); duration: 170; easing.type: Easing.OutQuad }
                NumberAnimation { target: decorItem; property: "hop"
                  to: 0; duration: 170; easing.type: Easing.InQuad }
                NumberAnimation { target: decorItem; property: "hop"
                  to: Style.space(8); duration: 110; easing.type: Easing.OutQuad }
                NumberAnimation { target: decorItem; property: "hop"
                  to: 0; duration: 110; easing.type: Easing.InQuad }
              }
              MouseArea {
                anchors.fill: parent
                enabled: decorItem.modelData.bounce === true
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                  if (bounceAnim.running) return
                  bounceAnim.start()
                  root.petService.playSound("ball")
                }
              }

              // Cone of light from a lamp's shade, aimed at the pet so the
              // lamp can be nudged around and still light it. Drawn under
              // the sprite; breathes slowly through the gradient alpha.
              property bool lit: modelData.beam !== undefined
              property real glow: 1
              SequentialAnimation {
                running: decorItem.visible && decorItem.lit
                loops: Animation.Infinite
                NumberAnimation { target: decorItem; property: "glow"
                  to: 0.65; duration: 2600; easing.type: Easing.InOutSine }
                NumberAnimation { target: decorItem; property: "glow"
                  to: 1; duration: 2600; easing.type: Easing.InOutSine }
              }
              Shape {
                id: lightCone
                visible: decorItem.lit
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                readonly property real s: decorImage.implicitWidth > 0
                  ? decorItem.width / decorImage.implicitWidth : 1
                readonly property real ax: decorItem.lit ? decorItem.modelData.beam[0] * s : 0
                readonly property real ay: decorItem.lit ? decorItem.modelData.beam[1] * s : 0
                readonly property real bx: decorItem.lit ? decorItem.modelData.beam[2] * s : 0
                readonly property real by: decorItem.lit ? decorItem.modelData.beam[3] * s : 0
                readonly property real mx: (ax + bx) / 2
                readonly property real my: (ay + by) / 2
                readonly property real ex: bigPet.x + bigPet.width / 2 - decorItem.x
                readonly property real ey: bigPet.y + bigPet.height / 2 - decorItem.y
                readonly property real len: Math.max(1, Math.hypot(ex - mx, ey - my))
                readonly property real ux: (ex - mx) / len
                readonly property real uy: (ey - my) / len
                readonly property real reach: len + bigPet.height * 0.45
                readonly property real cx: mx + ux * reach
                readonly property real cy: my + uy * reach
                readonly property real halfW: bigPet.width * 0.55
                ShapePath {
                  strokeWidth: -1
                  fillGradient: LinearGradient {
                    x1: lightCone.mx; y1: lightCone.my
                    x2: lightCone.cx; y2: lightCone.cy
                    GradientStop { position: 0; color: Qt.alpha(Color.accent, 0.45 * decorItem.glow) }
                    GradientStop { position: 1; color: Qt.alpha(Color.accent, 0) }
                  }
                  startX: lightCone.ax; startY: lightCone.ay
                  PathLine { x: lightCone.bx; y: lightCone.by }
                  PathLine { x: lightCone.cx + lightCone.uy * lightCone.halfW
                             y: lightCone.cy - lightCone.ux * lightCone.halfW }
                  PathLine { x: lightCone.cx - lightCone.uy * lightCone.halfW
                             y: lightCone.cy + lightCone.ux * lightCone.halfW }
                }
              }

              // A thin shelf under pieces that need something to stand on.
              Rectangle {
                visible: decorItem.modelData.shelf === true
                x: decorItem.width * 0.15
                y: decorItem.height
                width: decorItem.width * 0.75
                height: Style.space(2)
                color: Qt.alpha(Color.accent, 0.55)
              }

              Image {
                id: decorImage
                anchors.fill: parent
                source: Qt.resolvedUrl("assets/sprites/decor_" + decorItem.modelData.name + ".png")
                smooth: false
                visible: false
              }
              MultiEffect {
                anchors.fill: decorImage
                source: decorImage
                // Decor has its OWN colorization, separate from PetSprite's. A piece drawn
                // in the sprite palette (the dragon balls, the moon) must opt out or every
                // pixel collapses to one flat accent colour and the art is thrown away.
                colorization: decorItem.modelData.colorize === false ? 0 : 1
                colorizationColor: Color.accent
                // Furniture stays in the background: dimmer than the pet, unless the piece
                // is meant to be a light source.
                opacity: decorItem.modelData.colorize === false ? 0.9 : 0.55
              }
            }
          }

          PetSprite {
            id: bigPet
            anchors.centerIn: parent
            visible: !root.petIsOut && !root.exiting && !root.entering
            width: Style.space(80)
            height: Style.space(80)
            form: root.ready ? root.petService.displayForm : Lines.PLACEHOLDER_SPRITE
            baseForm: root.ready ? root.petService.baseSprite : Lines.PLACEHOLDER_SPRITE
            variantSuffix: root.ready ? root.petService.variantSuffix : ""
            colorize: false
            auraEnabled: root.ready && root.petService.auraEnabled
            auraColor: root.ready ? root.petService.auraColor : "transparent"
            auraPulse: root.ready && root.petService.auraPulse
            auraPadding: 14
            anim: {
              if (!root.ready) return "idle"
              if (root.petService.transientAnim !== "") return root.petService.transientAnim
              // Teens hanging out in their room are on their laptop, obviously.
              if (root.petService.stage === "teen" && root.petService.stateAnim === "idle")
                return "laptop"
              return root.petService.stateAnim
            }
            frameMs: anim === "eat" ? 350 : 600
            tint: Color.accent

            // Being scrubbed is wobbly business.
            SequentialAnimation {
              running: petArea.pressed && petArea.scrubbing
              loops: Animation.Infinite
              NumberAnimation { target: bigPet; property: "rotation"; to: -7; duration: 90 }
              NumberAnimation { target: bigPet; property: "rotation"; to: 7; duration: 90 }
              onStopped: bigPet.rotation = 0
            }
          }

          // Click = pet; press and rub = scrub the dirt off. Same
          // click-vs-gesture threshold as the roam grab.
          MouseArea {
            id: petArea
            anchors.fill: bigPet
            enabled: !root.petIsOut && !root.exiting && !root.entering
            cursorShape: pressed && scrubbing ? Qt.ClosedHandCursor : Qt.PointingHandCursor

            property real lastX: 0
            property real lastY: 0
            property real travel: 0
            property bool scrubbing: false

            onPressed: function(mouse) {
              lastX = mouse.x
              lastY = mouse.y
              travel = 0
              scrubbing = false
              // One wash is one gesture, and only this handler knows where a gesture starts.
              // scrub() is called dozens of times during a drag, so the service pays on the
              // first call of a gesture that actually removes dirt, and not again until the
              // next press.
              if (root.ready) root.petService.beginWash()
            }
            property real travelSinceSparkle: 0
            property int sparkleIndex: 0

            onPositionChanged: function(mouse) {
              if (!pressed) return
              var moved = Math.abs(mouse.x - lastX) + Math.abs(mouse.y - lastY)
              lastX = mouse.x
              lastY = mouse.y
              travel += moved
              if (!scrubbing && travel > 12) {
                scrubbing = true
                if (root.ready && root.petService.dirtiness > 0) {
                  root.petService.playSound("wash")
                  scrubSoundTimer.restart()
                }
              }
              if (scrubbing && root.ready && root.petService.dirtiness > 0) {
                root.petService.scrub(moved * 0.03)
                if (root.petService.dirtiness <= 0) scrubSoundTimer.stop()
                travelSinceSparkle += moved
                if (travelSinceSparkle > 50) {
                  travelSinceSparkle = 0
                  var item = sparkles.itemAt(sparkleIndex % sparkles.count)
                  if (item) item.pop(bigPet.x + mouse.x, bigPet.y + mouse.y)
                  sparkleIndex += 1
                }
              }
            }
            // The scrubbing clip is ~3 s: keep it going for as long as the
            // rubbing lasts and there is dirt left.
            Timer {
              id: scrubSoundTimer
              interval: 3000
              repeat: true
              onTriggered: root.petService.playSound("wash")
            }

            onReleased: {
              scrubSoundTimer.stop()
              if (scrubbing) {
                if (root.ready) { root.petService.endWash(); root.petService.flushPet() }
              } else {
                if (root.ready) root.petService.petThePet()
                panelHeart.pop()
              }
            }
          }

          // Soap sparkles while scrubbing: a small pool of them popping in
          // round-robin around the cursor, so a vigorous scrub foams visibly.
          Repeater {
            id: sparkles
            model: 4

            Text {
              id: sparkleItem
              text: "✦"
              color: Color.accent
              font.pixelSize: Style.space(18)
              opacity: 0

              function pop(cx, cy) {
                x = cx - width / 2 + (Math.random() * 44 - 22)
                y = cy - height / 2 + (Math.random() * 28 - 14)
                sparkleAnimation.restart()
              }

              ParallelAnimation {
                id: sparkleAnimation
                NumberAnimation {
                  target: sparkleItem; property: "y"
                  from: sparkleItem.y; to: sparkleItem.y - Style.space(22)
                  duration: 600
                }
                NumberAnimation {
                  target: sparkleItem; property: "rotation"
                  from: 0; to: Math.random() < 0.5 ? -40 : 40; duration: 600
                }
                SequentialAnimation {
                  NumberAnimation { target: sparkleItem; property: "opacity"; from: 0; to: 1; duration: 100 }
                  NumberAnimation { target: sparkleItem; property: "opacity"; to: 0; duration: 500 }
                }
              }
            }
          }

          // Same recipe as the roaming view: three letters and a slow pulse.
          Text {
            id: panelZzz
            visible: !root.petIsOut && !root.exiting && !root.entering && root.ready
              && root.petService.sleeping
            text: "z z Z"
            color: Color.accent
            font.pixelSize: Style.space(16)
            anchors.left: bigPet.right
            anchors.leftMargin: -Style.space(6)
            anchors.bottom: bigPet.top
            anchors.bottomMargin: -Style.space(12)

            SequentialAnimation {
              running: panelZzz.visible
              loops: Animation.Infinite
              NumberAnimation { target: panelZzz; property: "opacity"; from: 0.25; to: 1; duration: 1300 }
              NumberAnimation { target: panelZzz; property: "opacity"; from: 1; to: 0.25; duration: 1300 }
            }
          }

          // The emote bubble, floating at the pet's shoulder when it is home.
          Item {
            id: panelEmote
            visible: !root.petIsOut && !root.exiting && !root.entering && root.ready
              && root.petService.emoteName !== ""
              && root.petService.transientAnim === ""
              && panelEmoteImage.status === Image.Ready
            width: Style.space(32)
            height: width
            anchors.left: bigPet.right
            anchors.leftMargin: -Style.space(10)
            anchors.bottom: bigPet.top
            anchors.bottomMargin: -Style.space(14)

            property real bob: 0
            SequentialAnimation on bob {
              running: panelEmote.visible
              loops: Animation.Infinite
              NumberAnimation { from: 0; to: -3; duration: 900; easing.type: Easing.InOutQuad }
              NumberAnimation { from: -3; to: 0; duration: 900; easing.type: Easing.InOutQuad }
            }
            transform: Translate { y: panelEmote.bob }

            Image {
              id: panelEmoteImage
              anchors.fill: parent
              source: root.ready && root.petService.emoteName !== ""
                ? Qt.resolvedUrl("assets/sprites/" + root.petService.emoteName + ".png") : ""
              smooth: false
              mipmap: false
              fillMode: Image.PreserveAspectFit
              visible: false
            }

            MultiEffect {
              anchors.fill: panelEmoteImage
              source: panelEmoteImage
              colorization: 1
              // Same tint as the pet in the panel.
              colorizationColor: Color.accent
            }
          }

          Text {
            id: panelHeart
            text: "♥"
            color: Color.accent
            font.pixelSize: Style.space(20)
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.verticalCenter: parent.verticalCenter
            opacity: 0

            function pop() { panelHeartAnimation.restart() }

            ParallelAnimation {
              id: panelHeartAnimation
              NumberAnimation {
                target: panelHeart; property: "anchors.verticalCenterOffset"
                from: -Style.space(20); to: -Style.space(50); duration: 700
              }
              SequentialAnimation {
                NumberAnimation { target: panelHeart; property: "opacity"; from: 0; to: 1; duration: 150 }
                NumberAnimation { target: panelHeart; property: "opacity"; to: 0; duration: 550 }
              }
            }
          }
        }

        // The mood line, with the settings cogwheel at its right edge: the
        // text is centered on the full card width so the cog never shifts it.
        Item {
          width: parent.width
          height: Math.max(moodText.implicitHeight, settingsButton.height)
          visible: root.lineChosen

          Text {
            id: moodText
            width: parent.width
            anchors.verticalCenter: parent.verticalCenter
            horizontalAlignment: Text.AlignHCenter
            text: settingsControl.open ? "Settings"
              : lineagePane.open ? "The family record"
              : root.ready ? root.petService.moodLabel : "Waking up…"
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            wrapMode: Text.Wrap
            renderType: Text.NativeRendering
          }

          PanelActionButton {
            id: lineageButton
            anchors.right: settingsButton.left
            anchors.rightMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            // nf-md-file_document_multiple_outline, by code point so it survives tools that
            // strip private-use characters.
            iconText: String.fromCodePoint(0xF0DDA)
            tooltipText: lineagePane.open ? "Back to the pet" : "The family record"
            fontFamily: root.fontFamily
            foreground: root.foreground
            bordered: true
            enabled: root.ready
            onClicked: {
              settingsControl.open = false
              lineagePane.open = !lineagePane.open
            }
          }

          PanelActionButton {
            id: settingsButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            // nf-md-cog, by code point so it survives tools that strip
            // private-use characters.
            iconText: String.fromCodePoint(0xF0493)
            tooltipText: settingsControl.open ? "Back to the pet" : "Settings"
            fontFamily: root.fontFamily
            foreground: root.foreground
            bordered: true
            enabled: root.ready
            // Opening either pane closes the other.
            onClicked: {
              lineagePane.open = false
              settingsControl.open = !settingsControl.open
            }
          }
        }

        Text {
          width: parent.width
          visible: !root.anyPaneOpen && root.lineChosen
          horizontalAlignment: Text.AlignHCenter
          text: root.ready
            ? root.petService.petName + " · " + root.petService.stageLabel + " · "
              + root.ageLabel(root.petService.ageMinutes) + " old"
              + (root.petService.generation > 1
                ? " · Gen " + root.petService.generation : "")
            : ""
          color: Qt.alpha(root.foreground, 0.6)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          renderType: Text.NativeRendering

          // The one hint the game gives about evolution — deliberately
          // number-free: the exact thresholds stay a playground mystery.
          MouseArea {
            id: ageHover
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
          }
        }

        // The ki line. Names the form when the pet is transformed, and says WHY not when it
        // is not -- "fell back to base" and "is genuinely base" look identical otherwise.
        // The dot is the aura colour, so the panel and the sprite can be checked against
        // each other at a glance.
        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          visible: !root.anyPaneOpen && root.ready && root.lineChosen
          spacing: Style.space(6)

          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(6)
            height: width
            radius: width / 2
            visible: root.ready && root.petService.auraEnabled
            color: root.ready ? root.petService.auraColor : "transparent"
          }

          Text {
            text: root.ready ? root.petService.kiExplain : ""
            color: Qt.alpha(root.foreground, 0.6)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            renderType: Text.NativeRendering
          }

          // A pet that cannot be saved is not allowed to pretend it is playing, so the mode
          // is visible rather than silent.
          Text {
            visible: root.ready && root.petService.saveBlocked
            text: root.ready ? "SAVE BLOCKED · " + root.petService.saveBlockReason : ""
            color: "#E24B4B"
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            renderType: Text.NativeRendering
          }

          // LEVEL. Read progressMode first: a frozen or corrupt subtree shows what it is,
          // not a fabricated level 1 and a next unlock the pet can never reach.
          Text {
            visible: root.ready && root.petService.progressMode !== "absent"
            text: {
              if (!root.ready) return ""
              if (root.petService.progressMode !== "live")
                return "Progress unavailable (" + root.petService.progressMode + ")"
              var s = "Lv " + root.petService.level
              var next = root.petService.xpToNextLevel
              return next === null ? s + " · max" : s + " · " + next + " XP to go"
            }
            color: Qt.alpha(root.foreground, root.ready
              && root.petService.progressMode === "live" ? 0.75 : 0.5)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            renderType: Text.NativeRendering
          }

          // Battle power, straight off the ki reading. Absent whenever the reading is not
          // currently trustworthy: an empty readout beats a frozen number.
          Text {
            visible: root.ready && root.petService.kiPowerLabel !== ""
            text: root.ready ? root.petService.kiPowerLabel : ""
            color: Qt.alpha(root.foreground, 0.75)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            renderType: Text.NativeRendering
          }
          PanelToolTip {
            visible: ageHover.containsMouse && root.ready
            text: "It grows with time. Who it becomes reflects the care you gave it."
            fontFamily: root.fontFamily
          }
        }

        // Idea 7. The Cockpit document measures watts, so the pet says watts -- never a
        // percentage, because the card's power limit is not in the document and a fraction
        // of capacity would be a number nobody measured. Absent whenever the document is
        // not currently trustworthy.
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          visible: !root.anyPaneOpen && root.ready && root.lineChosen
            && root.petService.distantLabel !== ""
          text: root.ready ? root.petService.distantLabel : ""
          color: Qt.alpha(root.foreground, 0.55)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          renderType: Text.NativeRendering
        }

        // Twelve hours of the machine's power, one bar per five minutes, in the aura
        // colour of the rung each bucket peaked at. Empty buckets stay empty: a gap is a
        // period with no trustworthy reading, and filling it in would be a guess.
        Row {
          id: sparkline
          anchors.horizontalCenter: parent.horizontalCenter
          visible: !root.anyPaneOpen && root.ready && root.lineChosen
            && sparkline.peak > 0
          spacing: 1
          // Explicit: bars anchor to the bottom, so deriving the Row's height from its
          // tallest child instead would be a circular binding.
          height: sparkline.fullHeight
          readonly property var series: root.ready ? root.petService.sparkSeries : []
          readonly property real peak: {
            var max = 0
            for (var i = 0; i < series.length; i++)
              if (series[i] && series[i].power > max) max = series[i].power
            return max
          }
          readonly property real fullHeight: Style.space(18)

          Repeater {
            model: sparkline.series
            Rectangle {
              required property var modelData
              width: 2
              // An all-zero window is defined, not accidental: every bar sits on the
              // baseline rather than dividing by a zero peak.
              height: modelData && sparkline.peak > 0
                ? Math.max(1, Math.round(modelData.power / sparkline.peak
                                         * sparkline.fullHeight))
                : 1
              anchors.bottom: parent ? parent.bottom : undefined
              color: modelData
                ? (modelData.rung > 0
                   ? Lines.auraFor(root.ready ? root.petService.line : "", modelData.rung).color
                   : Qt.alpha(root.foreground, 0.35))
                : "transparent"
            }
          }
        }

        Button {
          anchors.horizontalCenter: parent.horizontalCenter
          visible: root.ready && root.petService.stage === "adult"
            && !root.petService.farewellPending && !root.anyPaneOpen && root.lineChosen
          text: "Let it go"
          tooltipText: "Say goodbye — a new attack pod will land (Gen "
            + (root.ready ? root.petService.generation + 1 : 2) + ")"
          fontFamily: root.fontFamily
          onClicked: farewellConfirm.opened = true
        }

        // --- needs ---------------------------------------------------------

        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: !root.anyPaneOpen && root.lineChosen

          Repeater {
            model: root.needs

            // One row per need: the gauge block on the left, its care button
            // (when the need has one) right next to it. A fixed action slot
            // on every row keeps all the gauges the same length.
            Row {
              id: needRow
              required property var modelData
              width: parent.width
              spacing: Style.space(10)

              readonly property real actionSlot: Style.space(104)

              Column {
                width: needRow.width - needRow.actionSlot - needRow.spacing
                spacing: Style.space(3)
                anchors.verticalCenter: parent.verticalCenter

                Text {
                  text: needRow.modelData.label
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  renderType: Text.NativeRendering
                }

                Rectangle {
                  width: parent.width
                  height: Style.space(6)
                  radius: height / 2
                  color: Qt.alpha(root.foreground, 0.15)

                  Rectangle {
                    // The bar shows wellbeing, so a rising need drains it.
                    width: parent.width * (1 - needRow.modelData.value / 100)
                    height: parent.height
                    radius: parent.radius
                    color: needRow.modelData.value >= 60
                      ? Color.urgent : Color.accent

                    Behavior on width { NumberAnimation { duration: 300 } }
                  }
                }

                Text {
                  text: needRow.modelData.hint
                  color: Qt.alpha(root.foreground, 0.6)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption !== undefined ? Style.font.caption : Style.font.bodySmall
                  renderType: Text.NativeRendering
                }
              }

              Item {
                width: needRow.actionSlot
                height: needRow.height
                anchors.verticalCenter: parent.verticalCenter

                Button {
                  anchors.centerIn: parent
                  visible: needRow.modelData.action !== ""
                  text: needRow.modelData.actionLabel
                  tooltipText: needRow.modelData.actionTip
                  fontFamily: root.fontFamily
                  enabled: root.ready
                    && (needRow.modelData.action !== "roam"
                        || (root.petService.canRoam && !root.petService.farewellPending))
                    && (needRow.modelData.action !== "feed"
                        || (root.petService.stage !== "egg" && !root.petService.eating))
                    && (needRow.modelData.needsHome !== true || !root.petIsOut)
                  opacity: enabled ? 1 : 0.4
                  onClicked: root.runAction(needRow.modelData.action)
                }
              }
            }
          }
        }

        // --- settings -------------------------------------------------------
        // Unfolded by the cogwheel in the card's top-right corner: effects
        // volume, and where the pet goes out to play.
        Column {
          id: settingsControl
          width: parent.width
          spacing: Style.space(8)
          visible: open
          property bool open: false
          readonly property real volume: root.ready ? root.petService.soundVolume : 0.5

          Row {
            spacing: Style.space(8)
            anchors.horizontalCenter: parent.horizontalCenter

            Text {
              anchors.verticalCenter: parent.verticalCenter
              // Nerd Font speaker glyphs (nf-md-volume_off/low/medium/high),
              // by code point so the icons survive any editor or tool that
              // strips private-use characters.
              text: String.fromCodePoint(settingsControl.volume <= 0 ? 0xF0581
                : settingsControl.volume < 0.34 ? 0xF057F
                : settingsControl.volume < 0.67 ? 0xF0580 : 0xF057E)
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              renderType: Text.NativeRendering
            }

            PanelSlider {
              id: volumeSlider
              bar: root.bar
              width: Style.space(180)
              anchors.verticalCenter: parent.verticalCenter
              minimum: 0
              maximum: 1
              step: 0.05
              value: settingsControl.volume
              // Persist on release, and let it be heard right away.
              onReleased: function(v) {
                root.petService.updateSettings({ soundVolume: v })
                Qt.callLater(function() { root.petService.playSound("hum") })
              }
              onRightClicked: root.petService.updateSettings({
                soundVolume: settingsControl.volume > 0 ? 0 : 0.5 })
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(36)
              horizontalAlignment: Text.AlignRight
              text: Math.round((volumeSlider.dragging ? volumeSlider.liveValue
                : settingsControl.volume) * 100) + "%"
              color: Qt.alpha(root.foreground, 0.7)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              renderType: Text.NativeRendering
            }
          }

          Row {
            spacing: Style.space(8)
            anchors.horizontalCenter: parent.horizontalCenter
            // On a single screen every choice lands in the same place —
            // don't show a setting that cannot do anything.
            visible: Quickshell.screens.length > 1

            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: "Roam screen"
              color: Qt.alpha(root.foreground, 0.7)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              renderType: Text.NativeRendering
            }

            Button {
              anchors.verticalCenter: parent.verticalCenter
              text: root.ready && root.petService.settings.roamScreen
                ? root.petService.settings.roamScreen : "Where I click"
              tooltipText: "Where the pet goes out to train: the screen the Nimbus"
                + " is called on, or one pinned output"
              fontFamily: root.fontFamily
              enabled: root.ready
              onClicked: {
                // Cycle: follow the click, then each connected output.
                var names = [""]
                var screens = Quickshell.screens
                for (var i = 0; i < screens.length; i++) names.push(screens[i].name)
                var current = root.petService.settings.roamScreen || ""
                var next = names[(names.indexOf(current) + 1) % names.length]
                root.petService.updateSettings({ roamScreen: next })
              }
            }
          }

          // What the pet is allowed to say, and how loudly. Quiet mode is the master
          // switch: with it on, only a save-file failure can still reach a toast.
          Repeater {
            model: [
              { key: "quietMode", label: "Quiet mode",
                tip: "Silence everything except a save-file failure" },
              { key: "speechEnabled", label: "Pet speaks",
                tip: "Events are announced in the line's own voice" },
              { key: "chatterEnabled", label: "Idle chatter",
                tip: "The occasional line when nothing is happening" },
              { key: "probeNotifyEnabled", label: "Health alerts",
                tip: "Disk pressure and failed units" },
              { key: "over9000Enabled", label: "Over 9000",
                tip: "One scouter alert when battle power crosses 9000" },
              { key: "dragonBallsEnabled", label: "Dragon balls",
                tip: "The seven-ball hunt and Shenron" },
              { key: "nightRestEnabled", label: "Night rest",
                tip: "Sleeps 8pm to 7am and needs nothing while it does" },
              { key: "surgeEnabled", label: "Fleet surges",
                tip: "The pet flares when the agent fleet spikes" },
              { key: "distantKiEnabled", label: "Distant power",
                tip: "A second machine's GPU reading on the panel, when a cockpit state document is present" },
              { key: "scouterEnabled", label: "Window scouter",
                tip: "Read the power level of the window it stands on" },
              { key: "scouterTitlesEnabled", label: "Scouter titles",
                tip: "Allow window titles in scouter notifications" },
              { key: "rivalEnabled", label: "The rival",
                tip: "A second fighter walks on when a distant machine is working" },
              { key: "behavioursEnabled", label: "Line behaviours",
                tip: "Each family line's signature reaction" },
              { key: "movesEnabled", label: "Signature moves",
                tip: "Techniques learned at levels 12, 30 and 60" }
            ]
            Row {
              id: toggleRow
              required property var modelData
              spacing: Style.space(8)
              anchors.horizontalCenter: parent.horizontalCenter
              // The button reports the setting's own value, so quiet mode reads "On"
              // when it is on. An inverted label here would misreport the master switch.
              readonly property bool on: root.ready
                && root.petService.settings[toggleRow.modelData.key] === true

              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(110)
                text: toggleRow.modelData.label
                color: Qt.alpha(root.foreground, 0.7)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                renderType: Text.NativeRendering
              }

              Button {
                anchors.verticalCenter: parent.verticalCenter
                text: toggleRow.on ? "On" : "Off"
                tooltipText: toggleRow.modelData.tip
                fontFamily: root.fontFamily
                enabled: root.ready
                onClicked: {
                  var patch = {}
                  patch[toggleRow.modelData.key] = !toggleRow.on
                  root.petService.updateSettings(patch)
                }
              }
            }
          }

          // Start over. Buried at the bottom of the settings pane behind a confirmation,
          // because it is the one thing here that cannot be undone.
          Rectangle {
            width: parent.width
            height: 1
            color: Qt.alpha(root.foreground, 0.15)
          }

          Row {
            spacing: Style.space(8)
            anchors.horizontalCenter: parent.horizontalCenter

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(110)
              text: "Start over"
              color: Qt.alpha(root.foreground, 0.7)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              renderType: Text.NativeRendering
            }
            Button {
              anchors.verticalCenter: parent.verticalCenter
              text: "Reset pet"
              tooltipText: "Ends this pet and hands back an unclaimed pod. Cannot be undone."
              fontFamily: root.fontFamily
              enabled: root.ready && root.lineChosen
              onClicked: resetConfirm.opened = true
            }
          }
        }

        // --- the family record ------------------------------------------------
        //
        // A BOUNDED list, not a scroller. Nothing in this file clips, there is no Flickable
        // or ListView anywhere, and PanelKeyCatcher swallows Up/Down/j/k before any
        // descendant reaches them -- so a hundred-row scroller would need a clipping
        // container and a key-forwarding handshake that do not exist, to show a list nobody
        // reads past the top of. The honest answer for the full history is an export.
        Column {
          id: lineagePane
          width: parent.width
          spacing: Style.space(8)
          visible: open
          property bool open: false

          readonly property var lineage: root.ready ? root.petService.lineageState : null
          readonly property var agg: LineagePane.aggregate(lineagePane.lineage)
          readonly property string mode: root.ready ? root.petService.lineageState.mode : "corrupt"
          readonly property bool loaded: root.ready && root.petService.lineageReady

          // There is no maximum scale to test against -- Style.effectiveSpacingScale is
          // spacingScale * fontScale and neither is bounded -- so the count is computed and
          // allowed to reach zero. The budget comes from the host panel's own clamp, which
          // depends on screen and bar geometry only, never on this content, so there is no
          // binding loop. Style.space(16) is subtracted because Panel.qml already adds it
          // at the fittedContentHeight call site.
          readonly property int rowHeight: Style.space(30)
          readonly property int rowGap: Style.space(4)
          readonly property int chrome: Style.space(180)
          readonly property int rowsThatFit: LineagePane.rowsThatFit(
            panel.availableCardHeight, panel.verticalContentInset,
            Style.space(16), chrome, rowHeight + rowGap)
          readonly property var rows: LineagePane.visibleRows(lineagePane.lineage,
                                                              lineagePane.rowsThatFit)

          function plural(n, one, many) { return n + " " + (n === 1 ? one : many) }

          function boundText(label, m) {
            if (m.contributors === 0) return "no readable " + label
            if (m.complete) return m.value + " " + label
            return "known " + label + " \u2265 " + m.value + ", from " + m.contributors
                 + " of " + lineagePane.agg.retained
          }

          function peakText() {
            var p = lineagePane.agg.peak
            if (p.best === null) return "no readable peak"
            var core = "tier " + p.best.tier + ", " + p.best.label
                     + " (Gen " + p.best.gen + ")"
            return (p.complete ? "best: " : "best known: ") + core
          }

          function careText() {
            var c = lineagePane.agg.care
            if (c.mean === null) return "care was never sampled in this record"
            if (c.complete)
              return "mean care " + c.mean + " across "
                   + lineagePane.plural(lineagePane.agg.retained, "generation", "generations")
            // Never an inequality: a mean over a subset bounds the whole in neither
            // direction, so the qualifier is the denominator instead.
            return "mean care " + c.mean + " across " + c.contributors + " of "
                 + lineagePane.agg.retained + " readable generations"
          }

          function stateText() {
            if (!lineagePane.loaded) return "reading the record\u2026"
            if (root.petService.lineageBusy) return "saving\u2026"
            if (lineagePane.mode === "corrupt")
              return "The record could not be read. It is left untouched so it can be recovered."
            if (lineagePane.mode === "write-failed")
              return "The record could not be saved; it may be out of date."
            if (lineagePane.mode === "partial")
              return lineagePane.plural(lineagePane.agg.unreadable, "row", "rows")
                   + " could not be read. The record is read-only until they are repaired "
                   + "or the history is archived."
            if (lineagePane.agg.retained === 0)
              return "No generations yet. The first farewell writes one."
            return ""
          }

          function reasonText() {
            switch (root.ready ? root.petService.geneticReason : "not-ready") {
            case "not-ready": return "Still reading the family record."
            case "unreadable": return "The family record cannot be read, so nothing is inherited."
            case "record-incomplete": return "Some rows of the record could not be read, so nothing is inherited."
            case "too-few-farewells": return "This line has not said goodbye to three grown pets yet."
            case "window-unreadable": return "One of the last three farewells has no readable progress."
            case "window-unsampled": return "One of the last three farewells was never sampled for care."
            case "inherited": return "Inherited from the last three farewells in this line."
            }
            return ""
          }

          // --- header: never clipped, because it carries the state warning ----
          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: lineagePane.agg.retained === 0 ? ""
              : "across the "
                + lineagePane.plural(lineagePane.agg.retained,
                                     "retained generation", "retained generations")
                + (lineagePane.agg.droppedByCap > 0
                   ? " \u00b7 " + lineagePane.agg.droppedByCap + " older dropped by the cap" : "")
            visible: text !== ""
            color: Qt.alpha(root.foreground, 0.7)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
            renderType: Text.NativeRendering
          }

          Text {
            width: parent.width
            visible: lineagePane.agg.retained > 0
            horizontalAlignment: Text.AlignHCenter
            text: lineagePane.boundText("dragon balls", lineagePane.agg.balls) + "  \u00b7  "
                + lineagePane.boundText("wishes", lineagePane.agg.wishes) + "\n"
                + lineagePane.peakText() + "\n" + lineagePane.careText()
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
            renderType: Text.NativeRendering
          }

          Text {
            width: parent.width
            visible: text !== ""
            horizontalAlignment: Text.AlignHCenter
            text: lineagePane.stateText()
            color: (lineagePane.mode === "valid" || lineagePane.mode === "missing")
              ? Qt.alpha(root.foreground, 0.7) : Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
            renderType: Text.NativeRendering
          }

          Text {
            width: parent.width
            visible: root.ready && root.petService.lineageStuck
            horizontalAlignment: Text.AlignHCenter
            text: "the family record is not being written"
            color: Color.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            renderType: Text.NativeRendering
          }

          // --- the rows: the ONLY clipped region ------------------------------
          //
          // Clipping the whole pane would cut off the bottom of the column at a large
          // enough scale, and the bottom of the column is the archive button -- a read-only
          // record would then show a warning nobody could act on.
          Item {
            width: parent.width
            // Sized to what is ACTUALLY shown, not to the budget: reserving eight rows'
            // worth of height for one row left a hole the size of the card.
            height: Math.min(lineagePane.rowsThatFit, lineagePane.rows.length)
                    * (lineagePane.rowHeight + lineagePane.rowGap)
            clip: true
            visible: lineagePane.rowsThatFit > 0 && lineagePane.rows.length > 0

            Column {
              width: parent.width
              spacing: lineagePane.rowGap

              Repeater {
                model: lineagePane.rows

                Column {
                  id: rowItem
                  required property var modelData
                  width: lineagePane.width
                  height: lineagePane.rowHeight
                  spacing: 0

                  readonly property var lifespan:
                    LineagePane.lifespanMinutes(rowItem.modelData)
                  readonly property var level: LineagePane.levelOf(rowItem.modelData)

                  Text {
                    width: parent.width
                    elide: Text.ElideRight
                    text: "Gen " + rowItem.modelData.gen + " \u00b7 "
                        + Lines.nameFor(rowItem.modelData.line, rowItem.modelData.gen)
                        + " \u00b7 " + (rowItem.lifespan === null
                            ? "not recorded" : root.ageLabel(rowItem.lifespan))
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    renderType: Text.NativeRendering
                  }

                  Text {
                    width: parent.width
                    elide: Text.ElideRight
                    // Branches on the MODE and never null-checks a progression field: on a
                    // frozen or corrupt row those keys are ABSENT, and validEntry rejects a
                    // row that carries them.
                    text: rowItem.modelData.progressMode !== "live"
                      ? "progress unreadable"
                      : Lines.rungLabel(rowItem.modelData.line,
                                        rowItem.modelData.peakKiRung)
                        + " \u00b7 " + (rowItem.level === null
                            ? rowItem.modelData.xp + " xp"
                            : "lv " + rowItem.level)
                        + " \u00b7 " + rowItem.modelData.ballsCollected + " balls"
                        + " \u00b7 " + rowItem.modelData.wishesGranted + " wishes"
                        + " \u00b7 " + (rowItem.modelData.careAverage === null
                            ? "never sampled" : "care " + rowItem.modelData.careAverage)
                    color: Qt.alpha(root.foreground, 0.75)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    renderType: Text.NativeRendering
                  }
                }
              }
            }
          }

          Text {
            width: parent.width
            visible: lineagePane.rowsThatFit === 0 && lineagePane.agg.retained > 0
            horizontalAlignment: Text.AlignHCenter
            text: "the generation list does not fit on this screen at this text size"
            color: Qt.alpha(root.foreground, 0.7)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
            renderType: Text.NativeRendering
          }

          Text {
            width: parent.width
            visible: lineagePane.agg.retained > lineagePane.rows.length
            horizontalAlignment: Text.AlignHCenter
            text: (lineagePane.agg.retained - lineagePane.rows.length) + " older not shown"
            color: Qt.alpha(root.foreground, 0.6)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            renderType: Text.NativeRendering
          }

          // --- footer: never clipped either -----------------------------------
          Text {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "Portraits are shown in each family's standard colours, not the colours "
                + "that generation actually wore.\n" + lineagePane.reasonText()
            color: Qt.alpha(root.foreground, 0.6)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.Wrap
            renderType: Text.NativeRendering
          }

          Button {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Archive and clear"
            // Disabled with a reason is the courtesy; Service.canArchive() at execution
            // time is the guarantee, because one Panel exists per bar and an already-open
            // dialog can be confirmed after a write has started.
            enabled: root.ready && root.petService.canArchive()
            onClicked: archiveConfirm.opened = true
          }
        }

        // --- the dragon ball hunt --------------------------------------------
        // The radar and the fetch button live here because the roam window's click mask is
        // deliberately unchanged, so anything rendered there would be unclickable.
        Column {
          width: parent.width
          spacing: Style.space(6)
          visible: !root.anyPaneOpen && root.ready && root.lineChosen
            && root.petService.ballsOn

          Row {
            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Style.space(8)

            Image {
              anchors.verticalCenter: parent.verticalCenter
              source: Qt.resolvedUrl("assets/sprites/decor_radar.png")
              width: Style.space(16)
              height: width
              smooth: false
              mipmap: false
              visible: status === Image.Ready
            }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              text: root.ready
                ? "Dragon balls " + root.petService.ballsCollected + " / 7" : ""
              color: Qt.alpha(root.foreground, 0.7)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              renderType: Text.NativeRendering
            }
            Button {
              anchors.verticalCenter: parent.verticalCenter
              visible: root.ready && root.petService.ballTarget >= 0
                && root.petService.roaming
              text: "Go get it"
              tooltipText: "One is on this workspace. Send the pet after it."
              fontFamily: root.fontFamily
              onClicked: root.petService.sendForBall()
            }
          }
        }

        // --- Shenron ---------------------------------------------------------
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: !root.anyPaneOpen && root.ready && root.petService.shenronPending

          Image {
            anchors.horizontalCenter: parent.horizontalCenter
            source: Qt.resolvedUrl("assets/sprites/decor_shenron.png")
            width: Math.min(parent.width, Style.space(288))
            height: width / 2
            smooth: false
            mipmap: false
            fillMode: Image.PreserveAspectFit
            visible: status === Image.Ready
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "Speak your wish."
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            renderType: Text.NativeRendering
          }
          Repeater {
            model: [
              { kind: "full_recovery", label: "Full recovery",
                tip: "Every need back to nothing, right now" },
              { kind: "care_ceiling", label: "A day without limits",
                tip: "For 24 hours it can reach whatever the machine actually reports" },
              { kind: "keepsake", label: "A keepsake",
                tip: "The seven balls hang in its room for this generation" }
            ]
            Button {
              required property var modelData
              anchors.horizontalCenter: parent.horizontalCenter
              width: Style.space(220)
              text: modelData.label
              tooltipText: modelData.tip
              fontFamily: root.fontFamily
              onClicked: root.petService.grantWish(modelData.kind)
            }
          }
        }

        // --- go play / come home --------------------------------------------
        Button {
          width: parent.width
          visible: root.ready && !root.anyPaneOpen && root.lineChosen
          text: root.ready && root.petService.settings.roamEnabled === true
            ? "Come home" : "Call Nimbus"
          tooltipText: root.ready && root.petService.canRoam
            ? "Ride the Flying Nimbus out to roam and climb Korin's Tower"
            : "Too young to go out alone"
          fontFamily: root.fontFamily
          enabled: root.ready && root.petService.canRoam
            && !root.petService.farewellPending
          opacity: enabled ? 1 : 0.4
          onClicked: root.runAction("roam")
        }

      }

      // The going-out animation: the pet slides over the room's edge, then
      // gravity wins and it drops straight out. The overlay covers only the
      // room, so the clip cuts the sprite at the room's bottom border — it
      // vanishes behind the gauges instead of gliding over them.
      Item {
        id: exitOverlay
        x: contentColumn.x + petRoom.x
        y: contentColumn.y + petRoom.y
        width: petRoom.width
        height: petRoom.height
        clip: true
        z: 5
        visible: exitAnim.running || enterAnim.running

        PetSprite {
          id: exitPet
          width: Style.space(80)
          height: Style.space(80)
          form: root.ready ? root.petService.displayForm : Lines.PLACEHOLDER_SPRITE
          baseForm: root.ready ? root.petService.baseSprite : Lines.PLACEHOLDER_SPRITE
          variantSuffix: root.ready ? root.petService.variantSuffix : ""
          // Legs pumping on the way out; serenely carried on the way in.
          anim: root.entering ? "idle" : "walk"
          fallbackAnim: "idle"
          frameMs: 220
          colorize: false
          auraEnabled: root.ready && root.petService.auraEnabled
          auraColor: root.ready ? root.petService.auraColor : "transparent"
          auraPulse: root.ready && root.petService.auraPulse
          auraPadding: 14

          property real slideToY: 0
        }

        SequentialAnimation {
          id: exitAnim
          // A careful slide over the edge of the room…
          NumberAnimation {
            target: exitPet; property: "y"
            to: exitPet.slideToY
            duration: 650
            easing.type: Easing.InOutQuad
          }
          // …then straight down, fully past the room's clipped edge.
          NumberAnimation {
            target: exitPet; property: "y"
            to: exitOverlay.height + exitPet.height
            duration: 200
            easing.type: Easing.InQuad
          }
          ScriptAction { script: root.finishExit() }
        }

        // The homecoming: beamed up through the card, the pet rises from the
        // room's bottom edge back to its spot.
        SequentialAnimation {
          id: enterAnim
          NumberAnimation {
            target: exitPet; property: "y"
            to: (petRoom.height - exitPet.height) / 2
            duration: 600
            easing.type: Easing.OutQuad
          }
          ScriptAction { script: root.entering = false }
        }
      }

      ConfirmDialog {
        id: resetConfirm
        anchors.fill: parent
        // Names exactly what is lost. A vague confirmation on an irreversible action is
        // worse than none, because it trains people to click through.
        message: root.ready && root.lineChosen
          ? "Start over? " + root.petService.petName + " ends here — its age, its generation, "
            + "its care history and any dragon balls go with it, and you will choose a family "
            + "line again. This cannot be undone."
          : ""
        confirmText: "Reset the pet"
        // ConfirmDialog.canceled() fires from the Cancel button AND from a scrim click, and
        // with nothing clearing `opened` the confirmation for the only irreversible action in
        // the plugin could not be dismissed except by confirming it. farewellConfirm has this
        // handler; this one did not.
        onCanceled: opened = false
        onConfirmed: {
          opened = false
          if (!root.ready) return
          // Bring it home first: a pod cannot roam, and leaving the playground open around
          // a reset would strand the roam surface mid-walk.
          if (root.petIsOut) root.petService.setRoamEnabled(false)
          root.petService.resetPet()
        }
      }

      ConfirmDialog {
        id: archiveConfirm
        anchors.fill: parent
        // Names exactly what happens, including the copy that survives. Revision 6 promised
        // both "this cannot be undone" and a surviving backup, which cannot both be true.
        message: root.ready
          ? "Archive and clear the family record? The "
            + root.petService.lineageCount + " readable generations"
            + (root.petService.lineageUnreadable > 0
               ? " and " + root.petService.lineageUnreadable + " rows that could not be read"
               : "")
            + " are copied to a timestamped file beside the record, then the record starts "
            + "empty. " + root.petService.petName + " and its generation number are not "
            + "touched, and the archive is kept until you delete it yourself."
          : ""
        confirmText: "Archive and clear"
        onCanceled: opened = false
        onConfirmed: {
          opened = false
          if (!root.ready) return
          root.petService.beginArchive()
        }
      }

      ConfirmDialog {
        id: farewellConfirm
        anchors.fill: parent
        message: "Let your companion go? It will head out into the big wide world, and a new egg will appear."
        confirmText: "Say goodbye"
        onConfirmed: {
          opened = false
          if (!root.ready) return
          // Gated on the RESULT: the farewell is refused while a lineage write is in
          // flight, and playing the walk-off anyway sent the pet off screen for an ending
          // that never happened.
          if (!root.petService.beginFarewell()) return
          // From home it first has to get outside, the usual way out.
          if (!root.petIsOut) root.beginExit()
        }
        onCanceled: opened = false
      }
    }
  }
}
