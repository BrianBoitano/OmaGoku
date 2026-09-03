import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Wayland
import "lines.js" as Lines
import "display.js" as Display
import "moon.js" as Moon
import "notifybudget.js" as Budget
import "probes.js" as Probes
import "wm.js" as Wm
import "effects.js" as Effects
import "scouter.js" as Scouter
import "rival.js" as Rival
import "dragonballs.js" as Balls
import "levels.js" as Levels
import "moves.js" as Moves
import "lineage.js" as Lineage
import "genetics.js" as Genetics
import "behaviour.js" as Behaviour
import "ki.js" as Ki
import "localki.js" as LocalKi

// Headless pet brain. Loaded once at shell startup, independent of the bar
// widget, so the pet keeps living (and roaming) with the panel closed.
//
// Needs follow the classic loop: they rise with active shell time so there is
// always something to do, whatever the hardware. System state only flavors the
// pace — pending updates make it hungrier faster, orphaned packages make it
// get dirty faster. Nothing here depends on absolute machine performance.
//
// Commands executed (all fixed argv, read-only, no interpolation):
//   timeout 60 checkupdates   pending official updates (it can block on a pacman lock)
//   pacman -Qdtq              orphaned packages
Item {
  id: root

  property var shell: null
  property var manifest: null

  readonly property string stateHome: Quickshell.env("XDG_STATE_HOME")
    || ((Quickshell.env("HOME") || "") + "/.local/state")
  readonly property string stateDir: stateHome + "/omarchy"
  readonly property string settingsPath: stateDir + "/omagoku-settings.json"
  readonly property string petPath: stateDir + "/omagoku-state.json"
  readonly property string notifyPath: stateDir + "/omagoku-notify.json"
  readonly property string lineagePath: stateDir + "/omagoku-lineage.json"
  readonly property string discardPath: stateDir + "/omagoku-progress-discarded.json"

  readonly property var defaultSettings: ({
    roamEnabled: false,
    roamScale: 3,
    // Which output the pet roams on, named as Hyprland names it (whatever
    // `hyprctl monitors` prints, e.g. "DP-1"). Empty keeps the default: the
    // largest screen.
    roamScreen: "",
    soundVolume: 0.5,
    // Omagoku's own setting. The Scouter panel's reduced-motion toggle sets a property
    // private to the separate ki producer and does NOT write the flag file, so Omagoku cannot
    // follow it and has to ship its own. Pulsing stops if EITHER is set.
    reducedMotion: false,
    // The escape hatches. quietMode is the master: it silences everything except a
    // save-file failure, which is operational rather than flavour.
    quietMode: false,
    speechEnabled: true,
    chatterEnabled: true,
    probeNotifyEnabled: true,
    over9000Enabled: true,
    dragonBallsEnabled: true,
    // The pet sleeps 20:00-07:00 and accrues nothing. Off means the old always-on clock.
    nightRestEnabled: true,
    surgeEnabled: false,
    distantKiEnabled: false,
    scouterEnabled: true,
    scouterTitlesEnabled: true,
    // OFF by default. All three read the optional cockpit state document, which most
    // machines will not have, so defaulting them on shipped three switches that could never
    // turn anything on. Anyone running the producer turns them on once.
    rivalEnabled: false,
    behavioursEnabled: true,
    // updateSettings() merges only keys declared here, so a setting missing from this
    // object is silently dropped on every write and is not a switch at all.
    movesEnabled: true
  })
  // Effects volume, 0 (mute) to 1.
  readonly property real soundVolume: {
    var v = Number(settings.soundVolume)
    return isFinite(v) ? Math.max(0, Math.min(1, v)) : 0.5
  }
  property var settings: defaultSettings

  // --- persistent pet facts --------------------------------------------------

  property double hatchedAtMs: 0
  property double lastPetMs: 0

  // Growth, Gen1-chart style: the stage advances with active shell minutes,
  // and the branch taken depends on average happiness over the stage.
  property string stage: "egg"     // egg | baby | child | teen | adult
  property string form: "pod"      // sprite prefix in assets/sprites/
  property real ageMinutes: 0
  property real careSum: 0
  property int careCount: 0
  property int generation: 1
  // Which family line this pet belongs to. Empty means "not chosen yet", which is what the
  // panel's selector keys on. Pet state, not a setting: it belongs to this pet and dies
  // with it.
  property string line: ""

  // Need levels, 0 = fine, 100 = critical. All persisted.
  property real hungerLevel: 0
  property real dirtLevel: 0
  property real tirednessLevel: 0
  property real boredomLevel: 0
  property real lonelinessLevel: 0
  property bool sleeping: false

  readonly property var knownForms: ["pod", "baby", "child", "teen_neat",
    "teen_scruffy", "adult_ace", "adult_ok", "adult_gremlin"]

  property string omarchyPath: Quickshell.env("OMARCHY_PATH") || ""
  readonly property string notificationExecutable: omarchyPath !== ""
    ? omarchyPath + "/bin/omarchy-notification-send"
    : "omarchy-notification-send"

  // --- probe results ---------------------------------------------------------

  property int pendingUpdates: 0
  property int orphanCount: 0
  property double nowMs: Date.now()

  // Every probe carries a status and a sample time. Expired or failed reads become
  // unknown, which REMOVES the effect: a stale number that keeps flavouring the pet is
  // the same lie as a fabricated one.
  property var diskProbe: ({ status: "unknown" })
  property var failedSysProbe: ({ status: "unknown" })
  property var failedUserProbe: ({ status: "unknown" })
  readonly property int probeTtlMs: 2 * 30 * 60 * 1000
  readonly property var diskState: Probes.fresh(diskProbe, nowMs, probeTtlMs)
    ? diskProbe : { status: "unknown" }
  readonly property var failedState: {
    var sys = Probes.fresh(failedSysProbe, nowMs, probeTtlMs)
      ? failedSysProbe : { status: "unknown" }
    var usr = Probes.fresh(failedUserProbe, nowMs, probeTtlMs)
      ? failedUserProbe : { status: "unknown" }
    return Probes.combineFailed(sys, usr)
  }
  readonly property int failedUnits: failedState.status === "ok" ? failedState.count : 0
  readonly property int diskPercent: diskState.status === "ok" ? diskState.worst.pcent : -1
  readonly property string diskMount: diskState.status === "ok" ? diskState.worst.target : ""

  property bool initialized: false
  // State files are read through `head -c` so a huge or symlinked file can
  // never be pulled whole into the shell; the plugin writes a few hundred
  // bytes, anything hitting the cap is treated as corrupt.
  readonly property int maxStateBytes: 65536
  property bool settingsFileLoaded: false
  property bool petFileLoaded: false
  property bool notifyFileLoaded: false
  property string loadedSettingsText: ""
  property string loadedPetText: ""
  property string loadedNotifyText: ""
  property string petReadProblem: ""

  // --- derived needs ---------------------------------------------------------

  readonly property real hunger: Math.max(0, Math.min(100, hungerLevel))
  readonly property real dirtiness: Math.max(0, Math.min(100, dirtLevel))
  readonly property real tiredness: Math.max(0, Math.min(100, tirednessLevel))
  readonly property real boredom: Math.max(0, Math.min(100, boredomLevel))
  // Affection is a cuddle-session need: it fills over active time and each
  // petting only takes a bite out of it — a truly lonely pet wants a real
  // fuss, not a single tap.
  readonly property real loneliness: Math.max(0, Math.min(100, lonelinessLevel))

  readonly property bool roaming: canRoam && settings.roamEnabled === true

  readonly property real worstNeed: Math.max(hunger, dirtiness, tiredness,
    boredom, loneliness)
  readonly property real happiness: Math.round(100 - worstNeed)

  readonly property real careAverage: careCount > 0 ? careSum / careCount : 100

  // --- progression -----------------------------------------------------------
  //
  // { mode, progress, raw }. STORE XP, DERIVE LEVEL: nothing here writes a level, and a
  // subtree this build cannot understand is preserved read-only rather than replaced.
  property var progressState: ({ mode: "absent", progress: null, raw: null })
  readonly property string progressMode: progressState.mode
  readonly property bool progressLive: progressState.mode === "live"
  readonly property int xp: progressLive ? progressState.progress.xp : 0
  readonly property int level: progressLive ? Levels.levelFor(xp) : 1
  readonly property int xpIntoLevel: progressLive ? Levels.xpIntoLevel(xp) : 0
  // null at level 100, and at every non-live mode, where the panel shows no bar at all.
  readonly property var xpToNextLevel: progressLive ? Levels.xpToNextLevel(xp) : null
  // An INDEX or null. null means UNCAPPED, which is why a non-live subtree fails closed to
  // 0 and a legacy (pacing 0) pet is exempt for life -- gating an existing pet at level 1
  // would demote an honest Ultra Instinct to Base for weeks.
  readonly property var levelCapIndex: Levels.levelCapFor(progressState)
  readonly property real needRateMultiplier: Levels.multiplierFor(progressState)
  readonly property var availableMoves: progressLive ? Moves.available(line, level) : []

  // In-memory counters, mirroring notifySent / notifyDropped / lastDropReason.
  property var xpAwarded: ({})
  property var xpDropped: ({})
  property string lastXpDrop: ""
  readonly property bool canRoam: stage !== "egg" && stage !== "baby"
  readonly property string stageLabel: ({
    egg: "Egg", baby: "Baby", child: "Child", teen: "Teen", adult: "Adult"
  })[stage] || stage

  // --- ki and the transformation axis ----------------------------------------

  // ONE KiSource for the whole plugin. The bar widget, the panel, the exit animation and
  // the roaming window all read the derived properties below, so every surface shows the
  // same form at the same moment. Four independent readers would drift.
  KiSource { id: ki }

  // The one off-machine feed: the distant-power readout and the fleet surges both read it.
  CockpitSource { id: cockpit }

  // Idle, straight from the compositor. NOT hypridle, which this setup deliberately removed
  // hypridle/hyprlock on 2026-08-27, and a flag-file producer would have quietly
  // reinstated it. The unit of `timeout` is SECONDS, proven on this desktop rather than
  // read from docs: a monitor at 3 went idle while one at 3000 did not.
  IdleMonitor {
    id: idle
    enabled: true
    timeout: 1200
    // Explicit, not inherited: a fullscreen player should not read as idleness.
    respectInhibitors: true
  }

  readonly property bool inputIdle: idle.isIdle === true

  readonly property var distantPowerW: settings.distantKiEnabled === false
    ? null : cockpit.distantPowerW
  readonly property string distantState: settings.distantKiEnabled === false
    ? "unknown" : cockpit.distantState
  // The document measures watts, so the pet says watts. It never says a percentage: the
  // card's power limit is not in the document, so a fraction of capacity would be a number
  // nobody measured.
  readonly property string distantLabel: {
    if (distantPowerW === null) return ""
    var word = distantState === "generating" ? "A vast power stirs to the north"
      : distantState === "resident_idle" ? "Something waits to the north"
      : "The north is quiet"
    return word + " -- " + distantPowerW.toFixed(1) + " W"
  }

  // --- where the ki reading comes from ----------------------------------------
  //
  // KiSource reads an external producer's ki.json. Nothing in this plugin writes that file,
  // so on a stock install it never appears and the pet could never transform -- the whole
  // point of the thing, dead for everyone who is not already running the producer. When
  // there is no external producer at all we derive the reading from /proc/stat instead.
  //
  // ONLY on "missing", deliberately. A producer that exists and is stale, malformed or
  // oversized must keep failing closed to base: papering over a broken feed with a
  // synthetic number is exactly the lie KiSource's `status` property exists to prevent.
  readonly property bool usingLocalKi: ki.status === "missing"
  property var localKiPrev: LocalKi.emptySample()
  property real localKiSmoothed: NaN
  property var localKiState: LocalKi.state(null)

  readonly property string kiForm: usingLocalKi ? localKiState.form : ki.kiForm
  readonly property string kiStatus: usingLocalKi ? localKiState.status : ki.status
  readonly property bool reducedMotion: settings.reducedMotion === true
    || ki.reducedMotionFile

  readonly property var lineProfile: Lines.profile(line, generation)
  readonly property string petName: lineProfile.name
  readonly property string roomName: lineProfile.room
  readonly property string baseSprite: lineProfile.baseSprite(stage, form)

  // DERIVED, never persisted. `form` remains the pet's identity -- it drives evolution
  // history, decor, farewell sounds and the base sprite. A transformation is a temporary
  // reading of the machine, so writing it into `form` would make a hot afternoon
  // permanently rewrite the pet's biography.
  //
  // ONE resolver, every surface. Deriving displayForm here and displayIndex there is what
  // let the two describe different pets; now they come out of a single pure call, and the
  // machine-truth fields (rawKiIndex, effectiveRungIndex) ride along untouched by costume
  // so nothing that reasons about the machine ever reads a sprite name.
  // Display.inputs() is the ONE constructor of a resolver argument, shared with the test
  // harness. It tests presence on THIS object, so a property renamed or forgotten here
  // becomes a sentinel and caps at base with a warning, instead of silently uncapping.
  readonly property var display: Display.resolve(Display.inputs(root))
  readonly property string displayForm: display.displayForm
  readonly property int displayIndex: display.displayIndex
  readonly property string kiExplain: display.kiExplain
  readonly property int rawKiIndex: display.rawKiIndex
  readonly property int effectiveRungIndex: display.effectiveRungIndex

  readonly property bool auraEnabled: display.aura.enabled
  readonly property color auraColor: display.aura.color
  // Reduced motion keeps the aura's colour but stops it breathing: the form is information,
  // the pulse is decoration.
  readonly property bool auraPulse: display.aura.pulse && !reducedMotion

  // Battle power, straight off the ki reading. null whenever the reading is not currently
  // trustworthy, which is what hides the readout instead of freezing a number.
  readonly property var kiPower: usingLocalKi ? localKiState.power : ki.kiPower
  readonly property string kiPowerLabel: kiPower === null ? ""
    : "BP " + String(Math.round(kiPower)).replace(/\B(?=(\d{3})+(?!\d))/g, ",")

  // The moon, re-evaluated on the minute tick. Phase maths are UTC; only the night gate
  // reads local hours, so DST cannot move a full moon.
  property bool moonActive: false

  // Night rest. The pet goes to bed at 20:00 and gets up at 07:00, and while it is resting
  // NO need accrues -- the whole point is that leaving the machine on overnight must not
  // cost anything, because nobody was awake to feed it.
  property bool nightResting: false

  function refreshMoon() {
    // Before the gate opens this would read the boot clock and could put the pet to sleep,
    // wake it, freeze its needs, play a sound and save -- all from a time nobody trusts.
    if (!clockReady) return
    var now = new Date()
    moonActive = Moon.lunarActive(now.getTime(), now.getHours())
    nightResting = settings.nightRestEnabled !== false && Moon.isRestHours(now.getHours())
  }

  // Both edges of the night live here, so bedtime and morning cannot drift apart.
  onNightRestingChanged: {
    if (!initialized || line === "" || stage === "egg") return
    if (nightResting) {
      // It sleeps WHEREVER it is, including out roaming. Exempting roaming defeated the
      // whole point: roamEnabled persists across restarts, so the machine left on overnight
      // is exactly the case with the pet out. `roamEnabled` itself is untouched, so it
      // simply resumes playing in the morning.
      if (sleeping || eating || transientAnim !== "") return
      sleeping = true
      playSound("sleep")
      flushPet()
    } else if (sleeping) {
      sleeping = false
      wokenForCare = false
      playSound("hum")
      flushPet()
    }
  }

  // Where the pet left its panel, in screen coordinates (center x, feet y),
  // so the roaming window can pick up the fall right under the card. Negative
  // x means "no handoff": spawn at the usual floor spot.
  property real handoffX: -1
  property real handoffY: -1
  property string handoffScreen: ""
  // The screen Go play / Come home was last clicked on. Runtime-only: after
  // a shell restart the playground falls back to the usual screen choice.
  property string requestedScreenName: ""

  // Set by the panel to call the pet home through the tractor beam; the roam
  // window beams it up to the handoff spot, then clears this and fires
  // arrivedHome so the panel can play the entrance.
  property bool returnRequested: false
  signal arrivedHome()

  // Short-lived animation for a care action ("eat", "wash"), shown by the
  // panel and the roaming pet, then cleared.
  property string transientAnim: ""
  Timer {
    id: transientTimer
    interval: 2500
    onTriggered: root.endCare()
  }

  function endCare() {
    transientAnim = ""
    // Woken up for a meal or a bath? It stays up a little while, then goes
    // back to bed if it is still sleepy. The flag survives until the pet
    // actually dozes back off, so chained cares (feed then wash) re-arm it.
    if (wokenForCare) resleepTimer.restart()
  }
  Timer {
    id: resleepTimer
    interval: 30000
    onTriggered: {
      // Mid-meal or mid-scrub: stay up, endCare re-arms the timer.
      if (root.sleeping || root.eating || root.transientAnim !== "") return
      root.wokenForCare = false
      // During the night it goes back to bed however rested it is, and wherever it is;
      // otherwise a 21:00 petting would leave it awake until it happened to get tired.
      if (!root.nightResting && (root.roaming || root.tirednessLevel < 60)) return
      root.sleeping = true
      root.playSound("sleep")
      root.flushPet()
    }
  }

  // A meal is eaten bite by bite: hunger drains over ~6 s from full while
  // the eat frames play, then a last chew before the animation ends.
  readonly property bool eating: eatTimer.running
  Timer {
    id: eatTimer
    interval: 100
    repeat: true
    onTriggered: {
      root.hungerLevel = Math.max(0, root.hungerLevel - 100 / 60)
      if (root.hungerLevel > 0) return
      stop()
      transientTimer.interval = 600
      transientTimer.restart()
      root.flushPet()
    }
  }

  // The shared emote bubbles, one glyph per complaining need. When several
  // needs complain at once the bubble cycles through them every few seconds.
  // Views hide the bubble when the file doesn't exist yet.
  readonly property var activeEmotes: {
    if (!initialized || sleeping || stage === "egg") return []
    var list = []
    if (hunger >= 60) list.push("emote_hungry")
    if (dirtiness >= 60) list.push("emote_dirty")
    if (tiredness >= 60) list.push("emote_sleepy")
    if (boredom >= 60) list.push("emote_bored")
    if (loneliness >= 60) list.push("emote_sad")
    return list
  }
  property int emoteCycle: 0
  readonly property string emoteName: activeEmotes.length > 0
    ? activeEmotes[emoteCycle % activeEmotes.length]
    : behaviourEmote

  Timer {
    interval: 3000
    running: root.initialized && root.activeEmotes.length > 1
    repeat: true
    onTriggered: root.emoteCycle += 1
  }

  // The idle-state animation views should show (falls back to plain idle in
  // PetSprite when the dedicated sprite doesn't exist yet).
  // The pet's real state, before any behaviour is considered. behaviourBusy reads THIS,
  // and stateAnim below layers the behaviour on top -- otherwise the two would form a
  // binding cycle through behaviourActive.
  readonly property string baseStateAnim: {
    if (!initialized || stage === "egg") return "idle"
    if (sleeping) return "sleep"
    switch (mood) {
    case "hungry": return "hungry"
    case "dirty": return "dirty"
    case "sleepy": return "sleepy"
    case "bored": return "bored"
    case "lonely": return "sad"
    default: return "idle"
    }
  }

  // A behaviour may only occupy the idle slot. It can never replace a mood animation, so a
  // meditating Piccolo can never hide a starving pet.
  readonly property string stateAnim: (behaviourActive && behaviourAnim !== ""
                                       && baseStateAnim === "idle")
    ? behaviourAnim : baseStateAnim

  // Priority order: sleep is a state, then the loudest complaint wins.
  readonly property string mood: {
    if (!initialized) return "sleeping"
    if (stage === "egg") return "egg"
    if (sleeping) return "sleeping"
    if (hunger >= 60) return "hungry"
    if (dirtiness >= 60) return "dirty"
    if (tiredness >= 60) return "sleepy"
    if (boredom >= 60) return "bored"
    if (loneliness >= 60) return "lonely"
    if (worstNeed >= 35) return "meh"
    return "happy"
  }

  readonly property string moodLabel: {
    switch (mood) {
    case "egg": return "An attack pod. Something stirs inside…"
    case "sleeping": return "Resting in the Hyperbolic Time Chamber…"
    case "hungry": return pendingUpdates > 0
      ? "Starving — and those " + pendingUpdates + " pending updates smell delicious"
      : "Starving — pass a senzu bean!"
    case "dirty": return failedUnits > 0
      ? "Battered — " + failedUnits + " failed units left their mark"
      : orphanCount > 0
      ? "Battered — the " + orphanCount + " orphaned packages don't help"
      : "Battered — time in the healing tank?"
    case "sleepy": return "Worn out — about to drop…"
    case "bored": return "Restless — call the Nimbus!"
    case "lonely": return "Nobody to spar with — click me!"
    case "meh": return diskPercent >= 90
      ? "Holding steady — though " + diskMount + " is at " + diskPercent + "%"
      : "Holding steady"
    case "happy": return diskPercent >= 90
      ? "Full power! (" + diskMount + " is at " + diskPercent + "%, mind you)"
      : "Full power!"
    default: return "Omagoku"
    }
  }

  // --- the minute tick -------------------------------------------------------

  // Per-stage personalities: babies nap constantly, children burst with
  // energy and want out, teens raid the fridge and stay in. The multipliers below are the
  // whole specification -- they scale the base need rates, and 1 means "no opinion".
  readonly property var stageRates: ({
    baby:  { hunger: 1.5, dirt: 1, tired: 2.0, fun: 0.5 },
    child: { hunger: 1,   dirt: 1, tired: 1,   fun: 1.5 },
    teen:  { hunger: 2,   dirt: 1, tired: 0.8, fun: 0.5 },
    adult: { hunger: 1,   dirt: 1, tired: 1,   fun: 1 }
  })

  // Per-active-minute rates. System state flavors the pace: pending updates
  // and orphans speed up hunger/dirt, roaming is fun but tiring.
  function applyMinute() {
    if (stage === "egg") return // an egg has no needs yet
    // Defence in depth: the heartbeat Timer guards against unclaimed pods ageing. This guard
    // applies rates only if a line is present; if it somehow fires for an empty line
    // anyway, we do not apply a chosen line's rates to an unchosen pet.
    if (line === "") return
    var rate = Lines.composeRates(stageRates[stage], line)

    // NIGHT REST: nothing accrues between 20:00 and 07:00. Only tiredness drains, and the
    // pet is NOT woken by draining it -- waking at 02:00 would restart the whole problem.
    if (nightResting) {
      if (sleeping) tirednessLevel = Math.max(0, tirednessLevel - 2.2)
      return
    }

    // Out and about, it hums to itself once or twice an hour.
    if (roaming && !sleeping && Math.random() < 1.5 / 60) playSound("hum")

    // A mature pet is genuinely half as demanding -- but it does not also RECOVER half as
    // fast, so this multiplies only the five positive accruals below and never a recovery
    // or a care reduction.
    var lv = needRateMultiplier

    hungerLevel = Math.min(100,
      hungerLevel + (pendingUpdates > 0 ? 0.5 : 0.33) * rate.hunger * lv)
    // Battle damage: a failed unit wears the pet down faster, the same way orphans do.
    dirtLevel = Math.min(100,
      dirtLevel + (failedUnits > 0 ? 0.45 : orphanCount > 0 ? 0.33 : 0.21) * rate.dirt * lv)

    if (sleeping) {
      tirednessLevel = Math.max(0, tirednessLevel - 2.2)
      if (tirednessLevel <= 5) {
        sleeping = false
        // A little hum tells the user it woke up on its own.
        playSound("hum")
      }
    } else {
      tirednessLevel = Math.min(100,
        tirednessLevel + (roaming ? 0.55 : 0.28) * rate.tired * lv)
      if (tirednessLevel >= 90) {
        sleeping = true
        playSound("sleep")
      }
    }

    boredomLevel = roaming
      ? Math.max(0, boredomLevel - 2.0)
      : Math.min(100, boredomLevel + 0.45 * rate.fun * lv)

    // Full in ~14 active hours; each petting takes 10 off.
    lonelinessLevel = Math.min(100, lonelinessLevel + 0.12 * rate.lonely * lv)
  }

  // ONE event, ONE reducer call, ONE write. Per-source awards would be two full pet-save
  // writes a minute. Nothing here notifies: quiet mode and the notification cap change what
  // the user sees, never what the pet earns.
  //
  // Nothing accrues before clockReady: an award judged against the boot clock is an award
  // judged against a clock the plugin itself does not trust.
  function accrueMinuteXp(sample, sampled) {
    if (!progressLive || !clockReady) return
    var r = Levels.award(progressState.progress, {
      kind: "heartbeat",
      resting: nightResting,
      kiStatus: kiStatus,
      // The MACHINE truth, never effectiveRungIndex: paying on the care- stage- and
      // level-capped rung would make progression feed back on itself.
      rawKiIndex: rawKiIndex,
      sample: sample === true,
      sampled: sampled
    }, { nowMs: Date.now(), dayOrdinal: Levels.localDayOrdinal(new Date()) })
    publishProgress(r, false)
  }

  // Publishes a reducer result: commit the candidate first, and only adopt it if the write
  // succeeded. `announce` is for the caller that wants the awards logged.
  function publishProgress(r, announce) {
    if (!r || !r.progress) return false
    var next = { mode: "live", progress: r.progress, raw: null }
    if (!commitPet(petSave({ progress: Levels.toSave(next) }))) return false
    progressState = next
    for (var i = 0; i < r.awards.length; i++) {
      var a = r.awards[i]
      xpAwarded[a.source] = (xpAwarded[a.source] || 0) + a.amount
      // The per-minute trickle would be a journal line a minute forever.
      if (announce && a.source !== "active" && a.source !== "ki")
        console.log("omagoku: xp +" + a.amount + " " + a.source
                    + " total=" + r.progress.xp + " level=" + Levels.levelFor(r.progress.xp))
    }
    announceMoves()
    return true
  }

  function countXpDrop(source, reason) {
    xpDropped[source] = (xpDropped[source] || 0) + 1
    lastXpDrop = source + ":" + reason
  }

  // --- growth ----------------------------------------------------------------

  // Every pet alive when Phase 1 shipped is grandfathered onto the v0 thresholds. A teen
  // ten minutes from adulthood must not wake up four thousand minutes away from it, so the
  // pacing version is per-pet and never changes for a living pet.
  readonly property var pacing: Levels.pacingTable(progressState)

  function maybeEvolve() {
    if (stage === "egg" && ageMinutes >= pacing.baby)
      return evolve("baby", "baby",
        "SCOUTER: pod breach. A new power signature — " + petName + ".")
    if (stage === "baby" && ageMinutes >= pacing.child)
      return evolve("child", "child",
        "SCOUTER: power level climbing. " + petName + " is a child now.")
    if (stage === "child" && ageMinutes >= pacing.teen)
      return evolve("teen", careAverage >= 55 ? "teen_neat" : "teen_scruffy",
        careAverage >= 55
          ? "SCOUTER: reading stabilised. " + petName + " has grown into a teen."
          : (Lines.isOozaruLine(line)
             ? "SCOUTER: WARNING, signature spiking off the scale. It looked at the moon."
             : "SCOUTER: reading unstable. " + petName + " grew up neglected."))
    if (stage === "teen" && ageMinutes >= pacing.adult) {
      var neat = form === "teen_neat"
      var next = "adult_gremlin"
      if (careAverage >= 75) next = neat ? "adult_ace" : "adult_ok"
      else if (careAverage >= 40) next = neat ? "adult_ok" : "adult_gremlin"
      return evolve("adult", next,
        "SCOUTER: signature at full strength. " + petName + " is fully grown.")
    }
  }

  // The evolution notification is PERSONALIZED, not duplicated: one event, one toast, in
  // the line's voice, falling back to the generic copy when speech is off.
  function evolve(nextStage, nextForm, message) {
    if (!canMutatePet()) return
    stage = nextStage
    form = nextForm
    careSum = 0
    careCount = 0
    // A pet BEGINS here, at the pod's hatch. This and the load-time migration are the only
    // two points a petId is minted, and they are mutually exclusive: a claimed non-egg save
    // with no progress is the migration, anything else hatches into pacing 1.
    if (nextStage === "baby" && !progressLive) {
      progressState = { mode: "live", raw: null,
        progress: Levels.mint({ claimedPet: false, nowMs: Date.now(),
                                clockReady: clockReady }) }
    }
    flushPet()
    playSound(nextStage === "baby" ? "hatch" : "evolve")
    var key = "evolve_" + (nextStage === "teen" ? nextForm : nextStage)
    var voiced = settings.speechEnabled === false
      ? null : Lines.speak(line, key, { name: petName, gen: generation })
    emitNotify("evolution", "event", "Omagoku", voiced || message)
  }

  // --- sounds ----------------------------------------------------------------

  // One short clip per event, named after the event so better sounds can be
  // dropped in without touching code. The current set is placeholders reused
  // One file per event, or a list to pick from at random (see CREDITS.md).
  readonly property var eventSounds: ({
    hatch: "hatch.wav",
    evolve: "evolve.wav",
    eat: "eat.wav",
    wash: "wash.wav",
    pet: ["pet.wav", "pet2.wav"],
    hum: "humming.wav",
    grab: "grab.wav",
    sleep: "sleep.mp3",
    stun: "stun.wav",
    land: "fall.wav",
    beamCharge: "subbass.wav",
    beam: "tractorbeam.wav",
    ball: "balloon.wav",
    farewell_ace: "farewell_ace.wav",
    farewell_ok: "farewell_ok.mp3",
    farewell_gremlin: "farewell_gremlin.wav"
  })

  // pw-play wants a filesystem path, not a file:// URL.
  function soundPath(relativePath) {
    var url = Qt.resolvedUrl(relativePath).toString()
    if (url.indexOf("file://") === 0) url = url.substring(7)
    return decodeURIComponent(url)
  }

  function playSound(event) {
    if (soundVolume <= 0) return
    var file = eventSounds[event]
    if (Array.isArray(file)) file = file[Math.floor(Math.random() * file.length)]
    if (!file) return
    Quickshell.execDetached(["pw-play", "--volume", soundVolume.toFixed(2),
      soundPath("sounds/" + file)])
  }

  function notify(title, body) {
    Quickshell.execDetached([
      notificationExecutable,
      "--app-name", "omagoku",
      "-u", "normal",
      title,
      body
    ])
  }

  // --- the notification arbiter ----------------------------------------------
  //
  // Every notification in the plugin goes through here, including the four that predate
  // it. The combined rate of all sources is the plugin's real off-switch risk, so it is
  // governed in one place with one persisted state rather than by each feature promising
  // to behave. Drop means drop: nothing queues, nothing replays.

  property var notifyState: null
  // Counters live in memory for inspection; only a CHANGE of drop reason reaches the
  // journal, so an oscillating source cannot turn the log into a storm.
  property var notifySent: ({})
  property var notifyDropped: ({})
  property var lastDropReason: ({})
  readonly property int notifyWindowUsed: notifyState && notifyState.sends
    ? notifyState.sends.length : 0

  function featureEnabled(source) {
    if (settings.quietMode === true) return false
    switch (source) {
    case "fleetSurge": return settings.surgeEnabled !== false
    case "scouterRecord": return settings.scouterEnabled !== false
    case "rivalArrives": return settings.rivalEnabled !== false
    case "over9000": return settings.over9000Enabled !== false
    case "disk":
    case "failedUnits": return settings.probeNotifyEnabled !== false
    case "chatter": return settings.chatterEnabled !== false
    case "transformation":
    case "hardLanding":
    case "needCritical":
    case "moonrise":
    case "dawn": return settings.speechEnabled !== false
    default: return true
    }
  }

  function countDrop(source, reason) {
    notifyDropped[source] = (notifyDropped[source] || 0) + 1
    if (lastDropReason[source] === reason) return
    lastDropReason[source] = reason
    console.log("omagoku: notify drop " + source + " " + reason)
  }

  // The one entry point. `cls` is "exempt" (save failure), "event" or "chatter".
  function emitNotify(source, cls, title, body) {
    if (!body || body === "") return false
    if (cls !== "exempt") {
      // Non-exempt traffic waits for the arbiter's own state file. Failure lands on
      // silence rather than on a burst nobody asked for.
      if (!notifyFileLoaded || !notifyState) { countDrop(source, "not-ready"); return false }
      if (!featureEnabled(source)) { countDrop(source, "disabled"); return false }
    }
    var r = Budget.decide(notifyState, { source: source, cls: cls }, Date.now(), Math.random)
    notifyState = r.state
    if (cls !== "exempt") flushNotifyState()
    if (!r.send) { countDrop(source, r.reason); return false }
    notifySent[source] = (notifySent[source] || 0) + 1
    lastDropReason[source] = ""
    notify(title, body)
    return true
  }

  // Speech: the line's own copy for an event, through the same budget. A line with no copy
  // for this moment sends nothing rather than an empty toast.
  function speakEvent(source, cls, key, ctx) {
    var context = ctx || {}
    if (context.name === undefined) context.name = petName
    if (context.gen === undefined) context.gen = generation
    var body = settings.speechEnabled === false
      ? null : Lines.speak(line, key, context)
    return emitNotify(source, cls, "Omagoku", body)
  }

  function reducerState(key) {
    return (notifyState && notifyState.reducers) ? notifyState.reducers[key] : null
  }

  function saveReducer(key, state) {
    if (!notifyState) return
    if (!notifyState.reducers) notifyState.reducers = {}
    notifyState.reducers[key] = state
    flushNotifyState()
  }

  // Both lanes share one file. notifybudget.js stays unaware of effects, so the effect
  // state rides alongside under its own key rather than inside the budget shape.
  function flushNotifyState() {
    if (!notifyState) return
    var out = {}
    for (var k in notifyState) out[k] = notifyState[k]
    // Through toSave(), so an envelope this build does not understand is written back
    // untouched instead of being flattened away by an unrelated notification flush.
    out.effects = Effects.toSave(effectsState)
    notifyFile.setText(JSON.stringify(out) + "\n")
  }

  // --- the effect lane --------------------------------------------------------
  //
  // Separate from the notification budget on purpose: 4/hour and 120 s spacing are
  // calibrated for an interrupting toast, while a 10 s flare's irritation is about motion.
  // Letting a flare spend a send slot would also invert the priority the arbiter encodes.
  property var effectsState: Effects.emptyState()
  property bool surgeFlare: false

  function tryFlare() {
    if (!notifyFileLoaded) return false
    if (settings.quietMode === true || settings.surgeEnabled === false) return false
    var r = Effects.admit(effectsState, Date.now(), reducedMotion)
    effectsState = r.state
    if (!r.ok) return false
    flushNotifyState()
    surgeFlare = true
    flareTimer.restart()
    return true
  }
  Timer {
    id: flareTimer
    interval: Effects.FLARE_MS
    onTriggered: root.surgeFlare = false
  }

  // --- the move sets ----------------------------------------------------------
  //
  // AVAILABILITY IS DERIVED, always: Moves.available(line, level) is the only thing that
  // decides what this pet can do. progress.announced records what has been TOASTED and
  // gates nothing, because a corrupt array must never be able to unlock an unearned move.

  property int moveAdmitted: 0
  property int moveRefused: 0
  property string lastMoveRefusal: ""

  readonly property bool movesReady: clockReady && !saveBlocked
    && settings.movesEnabled !== false && settings.quietMode !== true
    && !fullscreenActive && initialized && progressLive && line !== ""
    && availableMoves.length > 0 && happiness >= 70 && !sleeping && !nightResting
    && !farewellPending && !returnRequested

  // Learning is announced once per pet. The ledger is written BEFORE the toast is attempted:
  // a dropped toast stays dropped and the move is available either way.
  function announceMoves() {
    if (!progressLive || !canMutatePet()) return
    var have = progressState.progress.announced || []
    var fresh = []
    for (var i = 0; i < availableMoves.length; i++)
      if (have.indexOf(availableMoves[i].id) < 0) fresh.push(availableMoves[i])
    if (fresh.length === 0) return
    var p = JSON.parse(JSON.stringify(Levels.toSave(progressState.progress)))
    p.announced = have.slice()
    for (var j = 0; j < fresh.length; j++) p.announced.push(fresh[j].id)
    var loaded = Levels.load(p, { claimedPet: false, nowMs: Date.now(), clockReady: true,
                                  moveIds: Moves.ids() })
    if (loaded.mode !== "live") return
    if (!commitPet(petSave({ progress: Levels.toSave(loaded) }))) return
    progressState = loaded
    for (var k = 0; k < fresh.length; k++)
      emitNotify("moveLearned", "ambient", "Omagoku",
                 "SCOUTER: new technique registered — " + fresh[k].label + ".")
  }

  // A latest-wins command slot, consumed once by the roam surface, exactly like fetchBall.
  // The surface owns `action` and `support`, so it re-checks its own half of the predicate
  // synchronously and calls tryMove() as a handshake before anything is committed.
  property var moveCommand: null
  property int moveNonce: 0
  function requestMove(moveId) {
    moveNonce += 1
    moveCommand = { id: moveId, nonce: moveNonce }
  }

  // The handshake. Membership is checked by ID, not "some move is available", so a stale
  // command can never fire another line's technique. The cooldown is spent only on an
  // admitted move.
  function tryMove(moveId) {
    if (!movesReady) { refuseMove("not-ready"); return null }
    if (!Moves.isAvailable(line, level, moveId)) { refuseMove("not-available"); return null }
    var m = Moves.byId(moveId)
    var tl = Moves.timeline(m.geometry, reducedMotion)
    var r = Effects.admitMove(effectsState, Date.now(), reducedMotion, moveId, tl.total,
                              { moveIds: Moves.ids(), clockReady: clockReady })
    if (!r.ok) { refuseMove(r.reason); return null }
    effectsState = r.state
    flushNotifyState()
    moveAdmitted += 1
    return { id: m.id, label: m.label, geometry: m.geometry, timeline: tl,
             reduced: r.static === true, color: Lines.moveColor(line),
             sprite: Moves.spriteFor(m.id), shape: Moves.GEOMETRY[m.geometry],
             substitute: Moves.reducedForm(m.geometry) }
  }

  function refuseMove(reason) {
    moveRefused += 1
    lastMoveRefusal = reason
  }

  // ONE global ambient budget, not one per move: three learned techniques must not mean
  // three attacks an hour. The deadline advances on every DUE attempt, admitted or not --
  // committing it only on success turns an overdue attempt into a per-tick retry, which is
  // a queued move wearing an ambient hat.
  function maybeAmbientMove() {
    if (!clockReady || !notifyFileLoaded || !effectsState) return
    if (!Effects.ambientDue(effectsState, Date.now())) return
    effectsState = Effects.drawAmbient(effectsState, Date.now(), Math.random)
    flushNotifyState()
    if (!movesReady || !roaming || !roamSurface) return
    var m = Moves.best(line, level)
    if (m) requestMove(m.id)
  }

  // Attempted, never guaranteed: a sleeping, held, stunned, indoor or unlevelled pet simply
  // does not fire, and nothing is queued or replayed. Same selection rule as the ambient
  // path, named once.
  function over9000Move() {
    if (!movesReady || !roaming || !roamSurface) return
    var m = Moves.best(line, level)
    if (m) requestMove(m.id)
  }

  // --- actions ---------------------------------------------------------------

  // Care wakes a sleeping pet first; once the fuss is over it dozes back
  // off if it is still sleepy (see transientTimer).
  // --- care XP ----------------------------------------------------------------
  //
  // Per COMPLETED gesture, and only when the gesture actually did something: feeding at zero
  // hunger is a polite nibble and washing is a drag that calls scrub() dozens of times.
  // Panel.qml owns the gesture boundary, so it brackets a wash with beginWash/endWash.
  property int washGesture: 0
  property int washPaidGesture: -1

  function beginWash() { washGesture += 1 }
  function endWash() { }

  function awardCareXp(kind) {
    if (!progressLive || !clockReady || !canMutatePet()) return
    var now = Date.now()
    var ord = Levels.localDayOrdinal(new Date())
    var r = Levels.awardCare(progressState.progress, kind, now, ord)
    if (r.amount <= 0) { countXpDrop("care", "gate"); return }
    // The first care award of a new local day is the qualifying interaction for the streak.
    var s = Levels.applyStreak(r.progress, ord)
    var next = { mode: "live", raw: null, progress: s.progress }
    if (s.amount > 0) next.progress.xp = Math.min(Levels.MAX_XP, next.progress.xp + s.amount)
    if (!commitPet(petSave({ progress: Levels.toSave(next) }))) return
    progressState = next
    xpAwarded.care = (xpAwarded.care || 0) + r.amount
    console.log("omagoku: xp +" + r.amount + " care total=" + next.progress.xp
                + " level=" + Levels.levelFor(next.progress.xp))
    if (s.amount > 0) {
      xpAwarded.streak = (xpAwarded.streak || 0) + s.amount
      console.log("omagoku: xp +" + s.amount + " streak day=" + next.progress.streak.count
                  + " total=" + next.progress.xp)
    }
    announceMoves()
  }

  property bool wokenForCare: false

  function wakeForCare() {
    // A pending doze interrupted by more care still counts as one to resume.
    if (resleepTimer.running) wokenForCare = true
    resleepTimer.stop()
    if (!sleeping) return
    sleeping = false
    wokenForCare = true
  }

  function feedNow() {
    if (eating) return
    if (!canMutatePet()) return
    // Paid only when the meal actually started; a nibble at zero hunger earns nothing.
    if (hungerLevel > 0) awardCareXp("feed")
    wakeForCare()
    transientAnim = "eat"
    transientTimer.stop()
    playSound("eat")
    if (hungerLevel > 0) eatTimer.restart()
    else {
      // Nothing to eat: a polite nibble, then back to whatever it was doing.
      transientTimer.interval = 1200
      transientTimer.restart()
    }
  }

  // Washing is a scrubbing gesture: the panel feeds it mouse travel and the
  // dirt comes off progressively. Persisted by the caller on gesture end.
  function scrub(amount) {
    if (dirtLevel <= 0) return
    if (!canMutatePet()) return
    // ONE award per wash gesture, on the first call that actually removes dirt.
    if (washPaidGesture !== washGesture) {
      washPaidGesture = washGesture
      awardCareXp("wash")
    }
    wakeForCare()
    dirtLevel = Math.max(0, dirtLevel - amount)
    transientAnim = "wash"
    transientTimer.interval = 2500
    transientTimer.restart()
    if (dirtLevel === 0) flushPet()
  }

  // --- the lineage record -----------------------------------------------------
  //
  // Its own file, because resetPet() wipes the pet save and surviving that is the whole
  // point. Two rules: it must never block a pet ending, and it must never destroy history.
  //
  // The default mode is CORRUPT, so an append that somehow beats the reader is refused
  // rather than writing a one-row file over every generation. Read-only is the safe side of
  // every ambiguity here.
  property var lineageState: ({ mode: "corrupt", record: Lineage.emptyRecord(),
                                unreadableRows: 0, droppedByCap: 0,
                                priorMode: null, backupPath: null })
  property bool lineageReady: false
  // Readable generations only. Rows we could not read are counted beside this, never
  // folded into it: six pieces of junk plus one real row is one generation, not seven.
  readonly property int lineageCount: lineageState.record.entries.length
  readonly property int lineageUnreadable: lineageState.unreadableRows || 0
  readonly property int lineageDroppedByCap: lineageState.droppedByCap || 0

  // One serialised transaction owns every lineage mutation. Three rules, each of which
  // cost a review round:
  //
  //   MEMORY MOVES ONLY WHEN THE DISK DOES. lineageState is written in exactly three
  //   places -- the loader, a matching terminal, and a failed write. recordEnding used to
  //   promote it the moment setText was issued, so a failed write left memory claiming a
  //   generation that had never reached disk, and genetics inherited from it.
  //
  //   EVERY WRITE OWNS ITS OWN WRITER. FileView.saved carries nothing identifying the
  //   write, so a token kept here cannot tell a late or duplicate signal from the current
  //   one. A writer per write turns the token into an object identity.
  //
  //   THE TRANSACTION IS ASSIGNED BEFORE ITS WRITE IS ISSUED. With the opposite order, a
  //   synchronously dispatched `saved` is discarded as stale and lineageBusy sticks
  //   forever on a write that actually succeeded.
  property var lineageTxn: null
  property int lineageTxnSeq: 0
  readonly property bool lineageBusy: lineageTxn !== null
  property string pendingArchivePath: ""

  // Display only. It cancels nothing and kills nothing -- a watchdog that acts on elapsed
  // time is the defect this house has shipped three broken versions of.
  property int lineageStuckToken: 0
  property int lineageTickToken: 0
  readonly property bool lineageStuck: lineageStuckToken !== 0

  // lineageState has no `ready` key (the three loader Processes set lineageReady directly), so
  // the object Genetics consumes is assembled once here rather than at each call site.
  readonly property var lineageForGenetics: ({
    ready: lineageReady, mode: lineageState.mode, record: lineageState.record })
  readonly property var genetics: Genetics.bucket(lineageForGenetics, line)
  readonly property int geneticBucket: genetics.bucket
  readonly property string geneticReason: genetics.reason
  // Appended to a sprite FILENAME, never to a form: a token inside a form would reach
  // Lineage.validEntry and drop every historical row.
  readonly property string variantSuffix: Lines.variantSuffix(geneticBucket)
  property string lastGeneticReason: ""

  onGeneticReasonChanged: {
    if (geneticReason === lastGeneticReason) return
    lastGeneticReason = geneticReason
    console.log("omagoku: genetics " + geneticReason + " (bucket " + geneticBucket + ")")
  }

  // An ending is NEVER blocked by this -- only its RECORD is. The check is deliberately
  // not `lineageReady && !lineageBusy`: a record that failed to load must not stop a pet
  // from saying goodbye, it just means the goodbye is recorded nowhere.
  function admit(what) {
    if (!lineageBusy) return true
    console.warn("omagoku: " + what + " refused -- a lineage write is in flight")
    return false
  }

  function canArchive() {
    // There must be something to copy. `missing` passes canWipe (nothing to protect), but
    // the archive's first step is a copy of a file that does not exist, which fails and
    // aborts the whole action while the button sat there enabled.
    return lineageReady && !lineageBusy && !farewellPending
        && Lineage.canWipe(lineageState.mode)
        && lineageState.mode !== "missing"
        && (lineageCount + lineageUnreadable) > 0
  }

  function lineageCtx(endedBy) {
    var mode = progressState.mode
    var p = progressState.progress
    var raw = progressState.raw
    var ctx = {
      progressMode: mode,
      petId: (mode === "live") ? (p ? p.petId : null)
                               : ((raw && typeof raw === "object") ? raw.petId : null),
      gen: generation, line: line, endedBy: endedBy, stage: stage, form: form,
      bornAt: (mode === "live" && p) ? p.bornAt : null,
      // An honest null beats a fabricated timestamp from a clock we do not trust yet.
      endedAt: clockReady ? Date.now() : null
    }
    if (mode !== "live") return ctx
    ctx.curve = p.curve
    ctx.xp = p.xp
    ctx.peakKiRung = p.peakRawKiRung
    ctx.ballsCollected = p.ballsLifetime
    ctx.wishesGranted = p.wishes
    // The LIFETIME average. Service.careAverage covers only the current stage, because
    // evolve() zeroes the counters, so it cannot answer "how well was this pet looked after".
    ctx.careAverage = p.care.countAll > 0
      ? Math.round(p.care.sumAll / p.care.countAll) : null
    return ctx
  }

  // Opens the ending transaction. Runs synchronously and completely BEFORE the pet ends,
  // so completeSendOff/completeReset may discard progressState.raw freely: neither payload
  // refers to it afterwards. Never throws to its caller.
  function beginEndingTransaction(endedBy) {
    // BOTH payloads are built before any gate is consulted. The shard describes a
    // progression subtree that is being destroyed either way and depends on nothing about
    // the lineage file; gating them together threw the forensic copy away exactly when the
    // record was already unreadable, which the old discardPreservedProgress never did.
    var shardText = null
    if (progressState.mode === "frozen" || progressState.mode === "corrupt") {
      try {
        shardText = JSON.stringify({
          discardedAt: clockReady ? Date.now() : null,
          mode: progressState.mode, raw: progressState.raw }, null, 2) + "\n"
      } catch (err) {
        console.warn("omagoku: could not serialise the discarded subtree (" + err + ")")
      }
    }

    var text = null
    var fitted = null
    if (!lineageReady) {
      console.warn("omagoku: lineage not loaded, ending recorded nowhere")
    } else if (!Lineage.canWrite(lineageState.mode)) {
      console.warn("omagoku: lineage is " + lineageState.mode
                   + " and read-only, ending recorded nowhere")
    } else {
      var e = Lineage.buildEntry(lineageCtx(endedBy))
      if (e !== null) {
        // An UPSERT by petId: a crash between this write and the pet reset leaves the
        // ending to be retried, and a second row for one pet is a fabricated generation.
        var rec = Lineage.upsert(lineageState.record, e)
        fitted = Lineage.fit(rec, maxStateBytes)
        if (fitted === null) {
          console.warn("omagoku: lineage entry does not fit in " + maxStateBytes
                       + " bytes -- ending recorded nowhere")
        } else {
          if (fitted.entries.length < rec.entries.length)
            console.warn("omagoku: lineage trimmed to fit, dropped "
                         + (rec.entries.length - fitted.entries.length) + " oldest entries")
          text = Lineage.toText(fitted)
        }
      }
    }

    if (text === null && shardText === null) return false

    // The shard is not part of the lineage transaction: it targets a different file and has
    // no ordering relationship to the record. Refusing it because a lineage write is in
    // flight would throw away the only copy of a progression subtree that completeSendOff is
    // about to discard -- the exact loss that building both payloads early was meant to stop.
    if (lineageBusy) {
      console.warn("omagoku: a lineage write is live, this ending is recorded nowhere")
      if (shardText !== null) issueWrite(discardPath, shardText, -1, "orphan-shard")
      return false
    }

    var t = { token: ++lineageTxnSeq, kind: "ending",
              phase: text === null ? "shard" : "lineage",
              lineageText: text, record: fitted, shardText: shardText,
              backupPath: null, priorMode: null, ok: true }
    // Assigned BEFORE the write is issued. See the note on lineageTxn.
    lineageTxn = t
    if (t.phase === "lineage") issueWrite(lineagePath, text, t.token, "lineage")
    else issueWrite(discardPath, shardText, t.token, "shard")
    return true
  }

  function issueWrite(path, text, token, phase) {
    var w = lineageWriter.createObject(root, { path: path })
    if (w === null) {
      writeTerminal(token, phase, false, "the writer could not be created", null)
      return
    }
    w.saved.connect(function () { root.writeTerminal(token, phase, true, "", w) })
    w.saveFailed.connect(function (err) {
      root.writeTerminal(token, phase, false, String(err), w)
    })
    // A throw here would reach the ending's outer catch while the transaction stayed busy
    // forever, because no saveFailed ever arrives for a call that never started.
    try { w.setText(text) }
    catch (err) { writeTerminal(token, phase, false, String(err), w) }
  }

  function writeTerminal(token, phase, ok, error, writer) {
    // The createObject-failure path passes NO writer, and that is the one failure this
    // branch exists for -- reading writer.terminalSeen first would throw inside the
    // handler meant to recover from it and wedge lineageBusy for the life of the shell.
    if (writer !== null && writer !== undefined) {
      if (writer.terminalSeen) return
      writer.terminalSeen = true
      Qt.callLater(function () { writer.destroy() })
    }
    // An orphan shard is written outside any transaction (an ending refused because a
    // lineage write was live). It has no phase machine to advance; the writer is retired
    // above and the outcome is logged here.
    if (phase === "orphan-shard") {
      if (!ok) console.warn("omagoku: could not save the discarded subtree (" + error + ")")
      return
    }
    var t = lineageTxn
    if (t === null || t.token !== token || t.phase !== phase) {
      console.warn("omagoku: stale lineage callback ignored (token " + token
                   + ", phase " + phase + ")")
      return
    }
    if (!ok) t.ok = false

    if (phase === "lineage") {
      if (ok) {
        // The ONLY promotion site.
        lineageState = { mode: "valid", record: t.record, unreadableRows: 0,
                         // An archive replaces the record with an empty one, so a count of
                         // rows the cap dropped from the OLD file no longer describes it.
                         droppedByCap: t.kind === "archive"
                           ? 0 : (lineageState.droppedByCap || 0),
                         priorMode: null, backupPath: t.backupPath }
      } else {
        console.warn("omagoku: LINEAGE WRITE FAILED (" + error
                     + ") -- the record is read-only and may be out of date")
        // write-failed, NOT corrupt: the loader's corrupt means "the bytes are unreadable"
        // and carries an empty record, while this carries the last committed entries and
        // says nothing about the file. It also keeps the archive available, so one failed
        // click cannot remove the only escape from `partial`.
        lineageState = { mode: "write-failed", record: lineageState.record,
                         unreadableRows: lineageState.unreadableRows || 0,
                         droppedByCap: lineageState.droppedByCap || 0,
                         priorMode: lineageState.mode, backupPath: t.backupPath }
      }
      // A failed lineage write still writes the ending's shard: that subtree is being
      // destroyed either way, and the row failing does not make the evidence less needed.
      if (t.kind === "ending" && t.shardText !== null) {
        t.phase = "shard"
        issueWrite(discardPath, t.shardText, t.token, "shard")
        return
      }
      // The archive deliberately does NOT touch the discarded-progress copy. That file is
      // the only record of a progression subtree this plugin could not read, it is not part
      // of the family record, and an action whose whole argument is "copy before you clear"
      // has no business deleting it without a copy of its own.
      finishTxn(t)
      return
    }

    if (!ok) console.warn("omagoku: could not save the discarded subtree (" + error + ")")
    finishTxn(t)
  }

  function finishTxn(t) {
    if (t.ok) console.log("omagoku: lineage " + t.kind + " complete (token " + t.token + ")")
    else console.warn("omagoku: lineage " + t.kind + " INCOMPLETE (token " + t.token + ")")
    if (lineageStuckToken === t.token) {
      lineageStuckToken = 0
      console.log("omagoku: the lineage record recovered (token " + t.token + ")")
    }
    lineageTickToken = 0
    lineageTxn = null
  }

  // Archive and clear. Not a wipe: it always copies the record aside first, because the
  // most reachable cause of a read-only record is rows THIS BUILD cannot parse -- rename a
  // line id and every row of that family becomes unreadable at once -- and the escape hatch
  // must not also be a shredder.
  function beginArchive() {
    if (!canArchive()) {
      console.warn("omagoku: archive refused (mode " + lineageState.mode
                   + ", busy " + lineageBusy + ", farewell " + farewellPending + ")")
      return false
    }
    // Millisecond-stamped so two archives cannot collide, and copied with --no-clobber so
    // an existing path can never be overwritten even if one somehow did.
    pendingArchivePath = stateDir + "/omagoku-lineage." + Date.now() + ".json"
    var t = { token: ++lineageTxnSeq, kind: "archive", phase: "backup",
              lineageText: Lineage.toText(Lineage.emptyRecord()),
              record: Lineage.emptyRecord(), shardText: null,
              backupPath: pendingArchivePath, priorMode: lineageState.mode, ok: true }
    lineageTxn = t
    archiveCopy.running = true
    return true
  }

  function archiveCopyTerminal(exitCode) {
    var t = lineageTxn
    if (t === null || t.kind !== "archive" || t.phase !== "backup") return
    if (exitCode !== 0) {
      // Nothing written, nothing deleted, no mode change, no bytes touched.
      t.ok = false
      console.warn("omagoku: archive ABORTED -- could not copy the record to "
                   + t.backupPath + " (exit " + exitCode + ")")
      finishTxn(t)
      return
    }
    console.log("omagoku: lineage archived to " + t.backupPath)
    t.phase = "lineage"
    issueWrite(lineagePath, t.lineageText, t.token, "lineage")
  }

  function tickLineageStuck() {
    if (lineageTxn === null) { lineageTickToken = 0; return }
    if (lineageTickToken !== lineageTxn.token) { lineageTickToken = lineageTxn.token; return }
    if (lineageStuckToken === lineageTxn.token) return
    lineageStuckToken = lineageTxn.token
    console.warn("omagoku: the lineage record is not being written -- a write has been in "
                 + "flight for over a minute (token " + lineageTxn.token + ")")
  }

  // The Tamagotchi farewell: the adult sets off into the world, a new egg appears, and
  // the generation counter carries the legacy.
  // Letting go is a little ceremony: the adult leaves its room (if home),
  // walks to the nearest screen corner, says goodbye in its own voice and
  // walks off the screen. Only then does the new egg appear.
  property bool farewellPending: false

  function beginFarewell() {
    if (stage !== "adult" || farewellPending) return false
    // Admission at EXECUTION time, not at the dialog. farewellPending then covers the whole
    // walk-off ceremony, so an archive can never start during a farewell and a farewell can
    // never start during an archive -- the interlock is symmetric and seconds wide.
    //
    // RETURNS A BOOL because the caller plays the walk-off animation: a refusal that the
    // panel ignored produced a pet that walked off screen and never came back.
    if (!admit("the farewell")) return false
    wakeUp()
    farewellPending = true
    return true
  }

  function farewellSoundEvent() {
    return "farewell_" + form.replace("adult_", "")
  }

  function sendOff() {
    if (stage !== "adult") return
    if (!canMutatePet()) return
    // try / catch / finally, not try / finally: `finally` alone runs the ending and then
    // RE-THROWS, so the caller's remaining work and the warning would still be skipped.
    try {
      beginEndingTransaction("farewell")
    } catch (err) {
      console.warn("omagoku: farewell record failed (" + err + ")")
    } finally {
      completeSendOff()
    }
  }

  function completeSendOff() {
    farewellPending = false
    generation += 1
    stage = "egg"
    form = "pod"
    ageMinutes = 0
    careSum = 0
    careCount = 0
    hungerLevel = 0
    dirtLevel = 0
    tirednessLevel = 0
    boredomLevel = 0
    lonelinessLevel = 0
    sleeping = false
    hatchedAtMs = Date.now()
    lastPetMs = hatchedAtMs
    // A pet ENDS here. The new pod carries no progression at all and earns nothing until it
    // hatches -- sendOff keeps the line, so the heartbeat's line === "" guard would not have
    // covered a post-farewell egg.
    progressState = { mode: "absent", progress: null, raw: null }
    // And the hunt belonged to the pet that earned it, exactly as resetPet already says.
    // A farewell used to carry the whole ball subtree into the new egg: collected balls, a
    // pending summon, and an active wish -- including care_ceiling, which lifts the
    // transformation cap onto a pet that never earned it. The keepsake self-invalidated on
    // the generation bump; nothing else did.
    ballState = Balls.emptyState()
    // The adult may leave from outdoors; the egg must not inherit a stale
    // "out playing" state (disabled Come home button, surprise exit at
    // the child stage).
    updateSettings({ roamEnabled: false })
    flushPet()
    var voiced = settings.speechEnabled === false
      ? null : Lines.speak(line, "rebirth", { name: petName, gen: generation })
    emitNotify("rebirth", "event", "Omagoku", voiced
      || "Your companion said goodbye and walked off into the world… a new egg appeared! (Gen " + generation + ")")
  }

  // START OVER. The only irreversible action in the plugin, and deliberately NOT the
  // farewell: the farewell is a ceremony an ADULT earns, which carries the line and the
  // generation forward. This ends the pet outright and hands back an unclaimed pod, so a
  // run that went wrong can be abandoned at any stage rather than nursed to adulthood
  // first. Reached only through the settings pane and a confirmation.
  //
  // It touches the PET and nothing else. Notification budget state is deliberately left
  // alone: those latches and cooldowns are about not irritating the user, not about this pet,
  // and clearing them would let a burst through the moment the new pod appears.
  function resetPet() {
    try {
      // A reset of a HATCHED pet writes a real row -- "reset" is in ENDED_BY precisely for
      // that, and `line` is not cleared until completeReset() runs in the finally BELOW
      // this call. Only a reset with no progression (an unclaimed pod, or a post-farewell
      // egg) records nothing, and it completes either way.
      beginEndingTransaction("reset")
    } catch (err) {
      console.warn("omagoku: reset record failed (" + err + ")")
    } finally {
      completeReset()
    }
  }

  function completeReset() {
    // The one thing that may replace a preserved subtree, along with deleting the file.
    saveBlocked = false
    saveBlockReason = ""
    progressState = { mode: "absent", progress: null, raw: null }
    farewellPending = false
    returnRequested = false
    wokenForCare = false
    transientAnim = ""
    eatTimer.stop()
    transientTimer.stop()
    resleepTimer.stop()

    line = ""                 // back to the pod selector, so a new family can be chosen
    generation = 1
    stage = "egg"
    form = "pod"
    ageMinutes = 0
    careSum = 0
    careCount = 0
    hungerLevel = 0
    dirtLevel = 0
    tirednessLevel = 0
    boredomLevel = 0
    lonelinessLevel = 0
    sleeping = false
    hatchedAtMs = Date.now()
    lastPetMs = hatchedAtMs

    // The hunt belonged to the pet that earned it; a fresh pod inherits nothing. The
    // keepsake invalidates itself, since it only renders for its own generation.
    ballState = Balls.emptyState()

    // A pod cannot roam, and the egg must not inherit a stale "out playing" state.
    updateSettings({ roamEnabled: false })
    flushPet()
    // No notification: this was a deliberate click, and a toast confirming what someone
    // just did on purpose is noise.
    console.log("omagoku: pet reset by request")
  }

  // A deliberate wake-up — petting, grabbing, or sending it out — unlike
  // wakeForCare it does not tuck the pet back in afterwards.
  function wakeUp() {
    if (!sleeping) return
    resleepTimer.stop()
    sleeping = false
    wokenForCare = false
    flushPet()
  }

  function petThePet() {
    if (!canMutatePet()) return
    if (lonelinessLevel > 0 || (!canRoam && boredomLevel > 0)) awardCareXp("pet")
    wakeUp()
    lastPetMs = Date.now()
    nowMs = lastPetMs
    lonelinessLevel = Math.max(0, lonelinessLevel - 10)
    // Cuddles only entertain a pet too little to go out; once it can
    // roam, boredom is cured outside.
    if (!canRoam) boredomLevel = Math.max(0, boredomLevel - 10)
    playSound("pet")
    flushPet()
  }

  // Called once by the panel's selector. Validating here as well as on load means a caller
  // cannot put an unvalidated id on the property by mistake.
  function chooseLine(id) {
    if (line !== "") return          // one pet, one line
    if (!Lines.has(id)) return
    line = id
    flushPet()
    var voiced = settings.speechEnabled === false
      ? null : Lines.speak(id, "line_selected",
                           { name: Lines.nameFor(id, generation), gen: generation })
    emitNotify("lineSelection", "event", "Omagoku", voiced
      || "SCOUTER: signature locked. " + Lines.nameFor(id, generation) + " is on the way.")
  }

  function setRoamEnabled(value) {
    updateSettings({ roamEnabled: value === true })
    // Brought home already sleepy? It settles in for a moment, then dozes
    // off — no need to hit rock bottom first.
    if (value !== true && !sleeping && tirednessLevel >= 60)
      resleepTimer.restart()
  }

  // A big fall hurts its feelings too: the inverse of a petting.
  // A big fall: the thud first, the dizzy jingle right after it.
  function stunShock() {
    lonelinessLevel = Math.min(100, lonelinessLevel + 10)
    playSound("land")
    stunSoundTimer.restart()
    flushPet()
    speakEvent("hardLanding", "event", "hard_landing", {})
  }
  Timer {
    id: stunSoundTimer
    interval: 450
    onTriggered: root.playSound("stun")
  }

  // The tractor beam: a low thrum powering up, then the beam itself. On the
  // way home it is mirrored: the beam plays out (~2.7 s), then the thrum.
  function playBeamSound(homeward) {
    beamSoundTimer.second = homeward ? "beamCharge" : "beam"
    beamSoundTimer.interval = homeward ? 2700 : 650
    playSound(homeward ? "beam" : "beamCharge")
    beamSoundTimer.restart()
  }
  Timer {
    id: beamSoundTimer
    property string second: "beam"
    onTriggered: root.playSound(second)
  }

  function updateSettings(patch) {
    var merged = {}
    for (var key in defaultSettings) merged[key] = defaultSettings[key]
    // Only known keys survive a write: retired settings (soundEnabled…) drop
    // out of the file on their own.
    for (var current in settings) if (current in merged) merged[current] = settings[current]
    for (var change in patch) if (change in merged) merged[change] = patch[change]
    settings = merged
    settingsFile.setText(JSON.stringify(settings, null, 2) + "\n")
  }

  // --- the save boundary -----------------------------------------------------
  //
  // A preflight that ran AFTER the mutation would be worse than none: the ball would be
  // collected in memory, the XP spent, the write skipped, every later write skipped too,
  // and the restart would re-collect the ball. So a transition builds a CANDIDATE, commits
  // it, and publishes to these properties only if the commit succeeded.

  // True when the save cannot be written. A visible read-only mode, not a silent one: the
  // pet is not allowed to pretend it is playing.
  property bool saveBlocked: false
  property string saveBlockReason: ""

  function petSave(over) {
    var out = {
      hatchedAtMs: hatchedAtMs,
      lastPetMs: lastPetMs,
      stage: stage,
      form: form,
      ageMinutes: ageMinutes,
      careSum: careSum,
      careCount: careCount,
      generation: generation,
      line: line,
      hungerLevel: hungerLevel,
      dirtLevel: dirtLevel,
      tirednessLevel: tirednessLevel,
      boredomLevel: boredomLevel,
      lonelinessLevel: lonelinessLevel,
      sleeping: sleeping,
      balls: Balls.toSave(ballState),
      progress: Levels.toSave(progressState)
    }
    for (var k in over) out[k] = over[k]
    return out
  }

  // Measured in UTF-8 BYTES and refused at >=, because the reader is `head -c` (bytes) and
  // boundedText() discards a file whose text REACHES maxStateBytes. A save written at
  // exactly the cap would come back empty and reset the pet to an egg.
  //
  // A preserved (frozen/corrupt) subtree is written compact, since it is the only part that
  // can push a document near the cap and its indentation buys nothing.
  function commitPet(candidate) {
    var pretty = progressState.mode === "live" || progressState.mode === "absent"
    var text = JSON.stringify(candidate, null, pretty ? 2 : 0) + "\n"
    if (Levels.utf8Bytes(text) >= maxStateBytes) {
      blockSaves("the save would exceed " + maxStateBytes + " bytes")
      return false
    }
    petFile.setText(text)
    // What this return value honestly means: the candidate FITS and the write was issued.
    // FileView's write is not synchronous, so a failure arrives at onSaveFailed a beat
    // later and freezes the pet there -- at most one transition can be published against a
    // write that turned out to fail, and none after that.
    return !saveBlocked
  }

  function flushPet() { return commitPet(petSave({})) }

  // One guard on every persistent transition. Disabling buttons blocks nothing that
  // matters: the pet mutates itself through the heartbeat and four timers.
  function canMutatePet() { return !saveBlocked }

  function blockSaves(reason) {
    if (saveBlocked) return
    saveBlocked = true
    saveBlockReason = reason
    console.warn("omagoku: SAVE BLOCKED -- " + reason)
    // Freeze the pet rather than let it keep changing a state that can no longer be
    // written. Every one of these mutates persistent state on its own.
    heartbeat.stop()
    eatTimer.stop()
    transientTimer.stop()
    resleepTimer.stop()
    emitNotify("saveCorruption", "exempt", "Omagoku cannot save",
               "The pet is frozen until this is fixed: " + reason)
  }

  // --- init ------------------------------------------------------------------

  function initializeIfReady() {
    if (initialized || !settingsFileLoaded || !petFileLoaded || !notifyFileLoaded) return

    try {
      var parsedSettings = loadedSettingsText !== "" ? JSON.parse(loadedSettingsText) : {}
      updateSettingsInMemory(parsedSettings)
    } catch (error) {
      console.warn("omagoku: settings file unreadable (" + error + "), using defaults")
      settings = defaultSettings
    }

    var hatch = false
    var saveProblem = petReadProblem
    // Staged out of the parse so an unvalidated value never reaches a binding. Seeded with
    // the safe defaults in case the parse throws before either is set.
    var loadedStage = "egg"
    var loadedForm = "pod"
    var loadedLine = ""
    // Persisted numbers must be finite and non-negative; anything else
    // (NaN, Infinity, negatives, strings) reads as 0.
    function num(v) { var n = Number(v); return isFinite(n) && n > 0 ? n : 0 }
    // Declared BEFORE the try: after a failed parse it would otherwise be undefined, and
    // reading pet.balls below would throw INSIDE the biography catch -- the exact failure
    // the ball boundary exists to prevent.
    var pet = {}
    try {
      pet = loadedPetText !== "" ? JSON.parse(loadedPetText) : {}
      hatchedAtMs = num(pet.hatchedAtMs)
      lastPetMs = num(pet.lastPetMs)
      // Into locals, NOT onto the properties. A QML property assignment re-evaluates every
      // binding on it immediately, so assigning first and validating afterwards publishes
      // the unvalidated value to every sprite in between.
      loadedStage = typeof pet.stage === "string" ? pet.stage : "egg"
      loadedForm = typeof pet.form === "string" ? pet.form : "pod"
      loadedLine = typeof pet.line === "string" ? pet.line : ""
      ageMinutes = num(pet.ageMinutes)
      careSum = num(pet.careSum)
      careCount = Math.round(num(pet.careCount))
      generation = Math.max(1, Math.round(num(pet.generation)))
      hungerLevel = num(pet.hungerLevel)
      dirtLevel = num(pet.dirtLevel)
      tirednessLevel = num(pet.tirednessLevel)
      boredomLevel = num(pet.boredomLevel)
      if (pet.lonelinessLevel !== undefined) {
        lonelinessLevel = num(pet.lonelinessLevel)
      } else {
        // Soft migration from the old wall-clock model: seed the stored level
        // from the time since the last petting.
        var hours = Number(pet.lastPetMs) > 0
          ? Math.max(0, (Date.now() - Number(pet.lastPetMs)) / 3600000) : 0
        lonelinessLevel = Math.min(100, hours / 24 * 100)
      }
      sleeping = pet.sleeping === true
    } catch (petError) {
      hatchedAtMs = 0; lastPetMs = 0
      saveProblem = "not valid JSON (" + petError + ")"
    }
    // Saves written before the egg sprite became the attack pod. Migrate the
    // prefix instead of falling through to the reset below, which would
    // discard a real pet's age and care history over a rename.
    if (loadedForm === "egg") loadedForm = "pod"
    // A corrupt or hand-edited form or stage falls back to a fresh egg
    // rather than a broken sprite path or NaN-poisoned need rates.
    if (knownForms.indexOf(loadedForm) < 0
        || ["egg", "baby", "child", "teen", "adult"].indexOf(loadedStage) < 0) {
      if (saveProblem === "")
        saveProblem = "unknown stage/form " + loadedStage + "/" + loadedForm
      loadedStage = "egg"
      loadedForm = "pod"
      ageMinutes = 0
      careSum = 0
      careCount = 0
    }
    // A line id becomes a path component in every sprite URL. An unrecognised one is not
    // "some other line", it is a save we do not understand, and it resets to a fresh pod.
    if (!Lines.has(loadedLine)) {
      if (loadedLine !== "" && saveProblem === "")
        saveProblem = "unknown line " + loadedLine
      loadedLine = ""
      loadedStage = "egg"
      loadedForm = "pod"
      ageMinutes = 0
      careSum = 0
      careCount = 0
    }
    // OUTSIDE the try, through a null guard, into a total function. A hostile ball object
    // can therefore never set saveProblem, never notify, and never touch a biography field.
    var rawBalls = (pet && typeof pet === "object") ? pet.balls : undefined
    ballState = Balls.fromSave(rawBalls, Date.now(),
                               Math.max(1, Math.round(num(pet ? pet.generation : 1))))

    // Progression, at the same kind of boundary and for the same reason: a save that resets
    // a real pet to an egg over a bad XP integer is a worse bug than a lost level. This can
    // never set saveProblem.
    //
    // `claimedPet` cannot be derived from the subtree, because a deployed pet and a fresh
    // install both arrive with none. It is computed from the biography we have just
    // validated, and it decides pacing -- which governs both the stage thresholds and
    // whether the level gate applies to this pet at all.
    var rawProgress = (pet && typeof pet === "object") ? pet.progress : undefined
    var claimed = Lines.has(loadedLine) && loadedStage !== "egg"
    progressState = Levels.load(rawProgress,
                                { claimedPet: claimed, nowMs: Date.now(),
                                  clockReady: false, moveIds: Moves.ids() })
    if (progressState.mode === "absent" && claimed) {
      // Every pet alive when Phase 1 shipped begins here. bornAt stays null: hatchedAtMs is
      // stamped when a POD appears and can precede this pet's hatch by days, and no
      // plausibility bound can invent a birth that was never recorded.
      progressState = { mode: "live", raw: null,
        progress: Levels.mint({ claimedPet: true, nowMs: Date.now(), clockReady: false }) }
      console.log("omagoku: progression migrated, pacing 0 (legacy pet, no level gate)")
    }
    if (progressState.mode === "frozen" || progressState.mode === "corrupt") {
      // The MODE and the byte count only. Copying up to 64 KiB of damaged or future save
      // content into the journal expands the blast radius and can flood the log.
      console.warn("omagoku: progression " + progressState.mode + ", preserved read-only ("
                   + Levels.utf8Bytes(JSON.stringify(progressState.raw)) + " bytes)")
    }

    // Only now, once both are known-good, do they become visible to the sprites.
    line = loadedLine
    stage = loadedStage
    form = loadedForm
    if (hatchedAtMs === 0) {
      hatchedAtMs = Date.now()
      lastPetMs = hatchedAtMs
      hatch = true
    }

    initialized = true
    if (saveProblem !== "") {
      console.warn("omagoku: save file " + petPath + " " + saveProblem + " — starting over")
      // Exempt: a save failure is operational, not flavour, so it bypasses the budget.
      emitNotify("saveCorruption", "exempt", "Omagoku couldn't read its save file",
                 "It was corrupt or oversized, so a fresh egg takes over.")
    }
    if (hatch) flushPet()

    // Cold start primes latches silently and draws chatter's first delay, but starts NO
    // cooldowns: pre-starting the six-hour over-9000 cooldown would eat a genuine crossing
    // on a fresh install.
    if (loadedNotifyText === "")
      notifyState = Budget.primeChatter(Budget.emptyState(), Date.now(), Math.random)
    refreshMoon()
    refreshFullscreen()
    sparkSeries = Ki.bucketSeries(kiBuckets, Date.now())

    updatesProc.running = true
    orphansProc.running = true
    runProbes()
  }

  function updateSettingsInMemory(parsed) {
    var merged = {}
    for (var key in defaultSettings) merged[key] = defaultSettings[key]
    for (var loaded in parsed) if (loaded in merged) merged[loaded] = parsed[loaded]
    settings = merged
  }

  // --- probes ----------------------------------------------------------------

  // --- the sources ------------------------------------------------------------

  // Every source is a pure reducer plus a driver. The reducer owns the latch and sees the
  // raw value; the budget above never sees a measurement.

  // ONE measurement, TWO reducers, evaluated in one place so they can never be computed
  // from different samples.
  //
  // The notification keeps its Wave-1 unknown-preserving latch, and therefore keeps working
  // when progression is absent, frozen or corrupt. The XP and move trigger use the
  // continuity-REQUIRING latch in the progress subtree, because a toast about a reading is
  // cheap and a payout for a transition nobody observed is not. They can legitimately
  // disagree after an outage; that is the point.
  function checkOver9000() {
    if (!notifyState) return
    var r = Budget.latchCross(reducerState("over9000"), kiPower, 9000, 8000)
    saveReducer("over9000", r.state)
    if (r.fire) emitNotify("over9000", "event", "Omagoku", "SCOUTER: IT'S OVER 9000!!")

    if (!progressLive || !clockReady || !canMutatePet()) return
    var p = progressState.progress
    var x = Levels.riseLatch(p.latch ? p.latch.over9000 : null, kiPower, 9000, 8000)
    var np = JSON.parse(JSON.stringify(Levels.toSave(p)))
    if (!np.latch) np.latch = {}
    np.latch.over9000 = x.state
    var loaded = Levels.load(np, { claimedPet: false, nowMs: Date.now(), clockReady: true })
    if (loaded.mode !== "live") return
    if (!x.fire) {
      if (!commitPet(petSave({ progress: Levels.toSave(loaded) }))) return
      progressState = loaded
      return
    }
    var aw = Levels.award(loaded.progress, { kind: "over9000" },
                          { nowMs: Date.now(), dayOrdinal: Levels.localDayOrdinal(new Date()) })
    if (aw.awards.length === 0) countXpDrop("over9000", "cooldown")
    if (publishProgress(aw, true)) over9000Move()
  }

  // The XP side of the probes. These are FALLING edges -- a disk emptying, a unit count
  // reaching zero -- and Budget's latches only fire on the rising one. The reducer is also
  // gap-aware: a bad -> unknown -> good sequence pays nothing, because a recovery nobody
  // observed did not happen.
  function checkMaintenanceXp() {
    if (!progressLive || !clockReady || !canMutatePet()) return
    var np = JSON.parse(JSON.stringify(Levels.toSave(progressState.progress)))
    if (!np.latch) np.latch = {}
    var fired = []
    var sources = [
      { key: "disk", value: diskState.status === "ok" ? diskState.worst.pcent : null,
        low: 85, high: 90 },
      { key: "failed", value: failedState.status === "ok" ? failedState.count : null,
        low: 1, high: 1 },
      // A probe that simply stopped running must go unknown on its own, or its stale
      // integer lets a later recovery pay across a gap nobody marked.
      { key: "updates",
        value: (updatesStatus === "ok" && Date.now() - updatesSampledAt < probeTtlMs)
          ? pendingUpdates : null,
        low: 1, high: 1 }
    ]
    for (var i = 0; i < sources.length; i++) {
      var s = sources[i]
      var r = Levels.fallLatch(np.latch[s.key], s.value, s.low, s.high)
      np.latch[s.key] = r.state
      if (r.fire) fired.push(s.key)
    }
    var loaded = Levels.load(np, { claimedPet: false, nowMs: Date.now(), clockReady: true })
    if (loaded.mode !== "live") return
    var cur = loaded.progress
    var awards = []
    for (var j = 0; j < fired.length; j++) {
      var aw = Levels.award(cur, { kind: "maint", source: fired[j] },
                            { nowMs: Date.now(),
                              dayOrdinal: Levels.localDayOrdinal(new Date()) })
      if (aw.awards.length === 0) countXpDrop("maint", "cooldown")
      cur = aw.progress
      awards = awards.concat(aw.awards)
    }
    publishProgress({ progress: cur, awards: awards }, true)
  }

  function checkProbeAlerts() {
    if (!notifyState) return
    var d = Budget.latchCross(reducerState("disk"),
      diskState.status === "ok" ? diskState.worst.pcent : null, 90, 85)
    saveReducer("disk", d.state)
    if (d.fire)
      emitNotify("disk", "event", "Omagoku",
        "SCOUTER: this planet's core is unstable. Integrity: "
        + (100 - diskPercent) + "% (" + diskMount + ")")

    var f = Budget.countLatch(reducerState("failedUnits"),
      failedState.status === "ok" ? failedState.count : null)
    saveReducer("failedUnits", f.state)
    if (f.fire)
      emitNotify("failedUnits", "event", "Omagoku",
        "SCOUTER: battle damage. " + failedUnits
        + (failedUnits === 1 ? " unit has failed." : " units have failed."))
  }

  // Idea 6. Thresholds are MEASURED, not guessed: 8+ agents is the top 2.9% of 584 samples
  // over 149 hours, which is a few flares a week rather than a strobe.
  //
  // The flare and the toast are TWO INDEPENDENT decisions. `if (emitNotify(...)) flare()`
  // would make the visual vanish on exactly the busy hours the feature advertises.
  function checkFleetSurge() {
    if (!notifyState) return
    var n = cockpit.fleetAgents
    var r = Budget.latchCross(reducerState("fleetSurge"), n, 8, 6)
    saveReducer("fleetSurge", r.state)
    if (!r.fire) return
    tryFlare()
    emitNotify("fleetSurge", "ambient", "Omagoku",
      "SCOUTER: an enormous power just flared... somewhere else. " + n + " agents at once.")
  }

  function checkTransformation() {
    if (!notifyState) return
    var r = Budget.rungRise(reducerState("transformation"), effectiveRungIndex,
                            kiStatus === "ok", Date.now())
    saveReducer("transformation", r.state)
    if (r.fire)
      speakEvent("transformation", "event", "transformation",
                 { rung: Lines.rungLabel(line, effectiveRungIndex) })
  }

  function checkMoon() {
    if (!notifyState) return
    var eligible = moonActive && Lines.isOozaruLine(line)
      && (stage === "teen" || stage === "adult")
    var r = Budget.boolEdge(reducerState("moon"), eligible)
    saveReducer("moon", r.state)
    if (r.rose) speakEvent("moonrise", "event", "moonrise", {})
    else if (r.fell) speakEvent("dawn", "event", "dawn", {})
  }

  readonly property var needKeys: ["hunger", "dirt", "tired", "bored", "lonely"]
  function needLevel(key) {
    switch (key) {
    case "hunger": return hunger
    case "dirt": return dirtiness
    case "tired": return tiredness
    case "bored": return boredom
    default: return loneliness
    }
  }

  function checkNeeds() {
    if (!notifyState || stage === "egg" || line === "") return
    for (var i = 0; i < needKeys.length; i++) {
      var key = needKeys[i]
      // Critical at 90, re-arming at 60 -- the same level the pet starts complaining at
      // on screen, so the toast and the emote agree about what "bad" means.
      var r = Budget.latchCross(reducerState("need_" + key), needLevel(key), 90, 60)
      saveReducer("need_" + key, r.state)
      if (r.fire) speakEvent("needCritical", "care", "need_" + key, {})
    }
  }

  // Chatter: the pet with nothing to report. Never queued, never repeated until its bag is
  // exhausted, and silent while any monitor's active workspace is fullscreen.
  function maybeChatter() {
    if (!notifyState || !initialized || stage === "egg" || line === "") return
    if (sleeping || fullscreenActive) return
    var bag = Lines.chatterLines(line)
    if (bag.length === 0) return
    var draw = Budget.bagDraw(reducerState("chatterBag"), bag.length, Math.random)
    var sent = emitNotify("chatter", "chatter", "Omagoku", bag[draw.index])
    if (sent) saveReducer("chatterBag", draw.state)
  }

  // --- the fullscreen signal --------------------------------------------------
  //
  // One shared derivation, consumed by chatter here and by the roam window's platform
  // builder. The ids cover EVERY monitor, so chatter cannot escape onto a second screen.
  property bool fullscreenActive: false
  function refreshFullscreen() {
    var ids = []
    var monitors = Hyprland.monitors.values
    for (var i = 0; i < monitors.length; i++)
      if (monitors[i].activeWorkspace) ids.push(monitors[i].activeWorkspace.id)
    var tops = []
    var toplevels = Hyprland.toplevels.values
    for (var j = 0; j < toplevels.length; j++) {
      var ipc = toplevels[j].lastIpcObject
      if (!ipc) continue
      tops.push({ workspaceId: toplevels[j].workspace ? toplevels[j].workspace.id : -1,
                  fullscreen: ipc.fullscreen === true || Number(ipc.fullscreen) > 0 })
    }
    fullscreenActive = Wm.anyFullscreen(tops, ids)
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "fullscreen" || event.name === "activewindow"
          || event.name === "workspace" || event.name === "workspacev2"
          || event.name === "focusedmon" || event.name === "closewindow")
        fullscreenDebounce.restart()
    }
  }
  Timer {
    id: fullscreenDebounce
    interval: 150
    onTriggered: root.refreshFullscreen()
  }

  // --- the window scouter -----------------------------------------------------
  //
  // Service owns the read, because it is the single I/O owner with the fixed-argv
  // discipline, the settings and the budget. RoamWindow only publishes which window the
  // pet is standing on.
  //
  // The number is real. The COPY is what keeps it honest: a browser is forty processes, so
  // this is one process of the window, never the window.

  property var roamSurface: null
  // Samples live OUTSIDE the platform array, keyed address:pid:starttime. The array is
  // rebuilt wholesale within ~600 ms of any window event and every 7 s regardless, so a
  // cache on the platform object could never accumulate anything.
  property var scouterAdopt: null
  property var scouterValue: null
  property string scouterKey: ""
  property int scouterGeneration: 0
  property double scouterTargetChangedAt: 0

  readonly property var scouterTarget: (roamSurface && settings.scouterEnabled !== false
                                        && roaming && !sleeping)
    ? roamSurface.scouterTarget : null

  readonly property string scouterLabel: {
    if (!scouterTarget || scouterValue === null) return ""
    var meta = roamSurface ? roamSurface.scouterMeta : null
    if (!meta) return ""
    return Scouter.label(meta.cls, scouterValue, meta.title,
                         settings.scouterTitlesEnabled !== false)
  }

  onScouterTargetChanged: {
    // Clear, never freeze: the number disappears when the pet steps away, exactly as the
    // BP readout disappears when the ki reading is not trustworthy.
    scouterValue = null
    scouterAdopt = null
    scouterKey = ""
    scouterTargetChangedAt = Date.now()
  }

  function sampleScouter() {
    if (!scouterTarget || scouterProc.running) return
    // Settle after a target change, so a pet walking across three windows does not fire
    // three reads it will immediately discard.
    if (Date.now() - scouterTargetChangedAt < 400) return
    var pid = scouterTarget.pid
    if (!Scouter.validPid(pid)) return
    scouterGeneration += 1
    scouterProc.generation = scouterGeneration
    scouterProc.pid = pid
    scouterProc.address = scouterTarget.address
    scouterProc.command = ["timeout", "2", "head", "-c", "4096", "/proc/" + pid + "/stat"]
    scouterProc.running = true
  }

  Process {
    id: scouterProc
    property int generation: 0
    property int pid: 0
    property string address: ""
    command: ["true"]
    stdout: StdioCollector { id: scouterOut }
    onExited: function(exitCode) {
      if (generation < root.scouterGeneration) return
      if (exitCode !== 0) return
      var r = Scouter.parseStat(scouterOut.text, pid, 4)
      if (r.status !== "ok" || r.rssKb === null) return
      // Keyed on starttime as well as pid: a recycled pid re-latches rather than
      // inheriting the previous process's number.
      var key = address + ":" + pid + ":" + r.starttime
      if (key !== root.scouterKey) {
        root.scouterKey = key
        root.scouterAdopt = null
      }
      var a = Scouter.adopt(root.scouterAdopt, Scouter.power(r.rssKb))
      root.scouterAdopt = a.state
      root.scouterValue = a.value
      root.noteScouterRecord(a.value)
    }
  }

  // Deliberately rare. A toast per window climbed would be noise and would spend budget the
  // pet needs for care; a personal best is the one moment worth interrupting for.
  function noteScouterRecord(value) {
    if (!notifyState || value === null || value < 4000) return
    var prev = reducerState("scouterRecord")
    var best = (prev && typeof prev.best === "number") ? prev.best : 0
    if (value <= best) return
    saveReducer("scouterRecord", { best: value })
    if (best === 0) return   // the first reading is a baseline, not a record
    var meta = roamSurface ? roamSurface.scouterMeta : null
    emitNotify("scouterRecord", "ambient", "Omagoku",
      "SCOUTER: " + Scouter.label(meta ? meta.cls : "something", value,
                                  meta ? meta.title : "",
                                  settings.scouterTitlesEnabled !== false))
  }

  Timer {
    interval: 5000
    running: root.initialized && root.scouterTarget !== null
    repeat: true
    onTriggered: root.sampleScouter()
  }

  // --- the dragon balls -------------------------------------------------------
  //
  // State lives INSIDE the pet's save file, so every rule here is ultimately about not
  // letting a game object erase a biography.

  property var ballState: Balls.emptyState()

  // The clock-ready gate. The desktop's clock is wrong for the first minute after every
  // boot, which is exactly when the shell starts, so no timestamp is produced until it
  // opens -- placement, relocation, scatter and granting a wish all wait.
  property bool clockReady: false
  Timer {
    interval: 90000
    running: true
    onTriggered: {
      root.clockReady = true
      // A corrupt effect envelope owes its spacing from THIS stamp, not from load time:
      // establishing a wall-clock admission on the boot clock is what this gate forbids.
      var armed = Effects.armAfterClock(root.effectsState, Date.now())
      if (armed !== root.effectsState) root.effectsState = armed
      // And the first ambient deadline is drawn here for the same reason.
      if (root.effectsState && root.effectsState.mode === "live"
          && typeof root.effectsState.nextAmbientAt !== "number")
        root.effectsState = Effects.drawAmbient(root.effectsState, Date.now(), Math.random)
      root.flushNotifyState()
      // The first trusted rest state, established without replaying the elapsed time.
      root.refreshMoon()
    }
  }

  readonly property bool ballsOn: settings.dragonBallsEnabled !== false
    && initialized && line !== "" && stage !== "egg"

  // Ordinary workspaces on the pet's own monitor. Special and scratchpad ids are negative.
  function ballWorkspaces() {
    var out = []
    var monitors = Hyprland.monitors.values
    for (var i = 0; i < monitors.length; i++) {
      var m = monitors[i]
      if (roamSurface && roamSurface.screen && m.name !== roamSurface.screen.name) continue
      if (m.activeWorkspace && m.activeWorkspace.id > 0) out.push(m.activeWorkspace.id)
    }
    var ws = Hyprland.workspaces.values
    for (var j = 0; j < ws.length; j++)
      if (ws[j].id > 0 && out.indexOf(ws[j].id) < 0) out.push(ws[j].id)
    return out
  }

  readonly property int activeWorkspaceId: {
    if (!roamSurface || !roamSurface.hyprMonitor) return -1
    var aw = roamSurface.hyprMonitor.activeWorkspace
    return aw ? aw.id : -1
  }

  // The wish's ceiling override: an INDEX or null, fed into the ONE resolver.
  readonly property var ceilingOverride: Balls.wishCeiling(ballState, nowMs)

  function ballTick() {
    if (!ballsOn || !clockReady) return
    var now = Date.now()
    var before = ballState
    var st = ballState
    if (st.pending) {
      var ws = ballWorkspaces()
      if (ws.length === 0) return
      st = Balls.place(st, now, ws, Math.random)
    } else {
      st = Balls.markSeen(st, activeWorkspaceId, now)
      st = Balls.relocate(st, now, activeWorkspaceId, ballWorkspaces())
    }
    if (st === before) return
    ballState = st
    flushPet()
    console.log("omagoku: balls " + (before.pending ? "scattered" : "moved")
                + " collected=" + Balls.collectedCount(st) + "/7")
  }

  // Called by the roam surface. Flushes SYNCHRONOUSLY before any effect, so a crash cannot
  // recollect the seventh ball or summon twice.
  function collectBall(index) {
    if (!ballsOn || !canMutatePet()) return
    var st = Balls.collectAt(ballState, index, Date.now())
    if (st === ballState) return
    // The ball transition and its XP are ONE mutation and ONE write. Awarding in a later
    // write can lose the XP; awarding in an earlier one can replay it.
    var np = progressState
    var awards = []
    if (progressLive && clockReady) {
      var r = Levels.award(progressState.progress, { kind: "ball" },
                           { nowMs: Date.now(),
                             dayOrdinal: Levels.localDayOrdinal(new Date()) })
      r.progress.ballsLifetime = Math.min(1000000, r.progress.ballsLifetime + 1)
      np = { mode: "live", raw: null, progress: r.progress }
      awards = r.awards
    }
    if (!commitPet(petSave({ balls: Balls.toSave(st), progress: Levels.toSave(np) })))
      return
    ballState = st
    progressState = np
    for (var i = 0; i < awards.length; i++)
      xpAwarded[awards[i].source] = (xpAwarded[awards[i].source] || 0) + awards[i].amount
    announceMoves()
    playSound("ball")
    if (Balls.allCollected(st))
      console.log("omagoku: balls all seven collected")
  }

  function checkShenron() {
    if (!ballsOn || !clockReady || !notifyState) return
    if (!Balls.canSummon(ballState, new Date().getHours())) return
    // Persist the summon BEFORE the toast: a crash in the other order repeats Shenron on
    // every dusk tick, and losing a toast is the smaller failure.
    if (!canMutatePet()) return
    var st = Balls.markNotified(Balls.recordSummon(ballState, Date.now()))
    var np = progressState
    if (progressLive) {
      var r = Levels.award(progressState.progress, { kind: "summon" },
                           { nowMs: Date.now(),
                             dayOrdinal: Levels.localDayOrdinal(new Date()) })
      np = { mode: "live", raw: null, progress: r.progress }
      for (var i = 0; i < r.awards.length; i++)
        xpAwarded[r.awards[i].source] = (xpAwarded[r.awards[i].source] || 0) + r.awards[i].amount
    }
    if (!commitPet(petSave({ balls: Balls.toSave(st), progress: Levels.toSave(np) })))
      return
    ballState = st
    progressState = np
    announceMoves()
    emitNotify("shenron", "ambient", "Omagoku",
      "SCOUTER: the sky just went dark. Something enormous is looking at you.")
  }

  readonly property bool shenronPending: ballState.summon !== null && ballState.summon !== undefined
  readonly property bool keepsakeEarned: ballState.keepsake === generation

  function grantWish(kind) {
    if (!shenronPending || !clockReady) return
    var now = Date.now()
    if (kind === "full_recovery") {
      hungerLevel = 0; dirtLevel = 0; tirednessLevel = 0
      boredomLevel = 0; lonelinessLevel = 0
      // Zeroing tiredness alone leaves a sleeping pet asleep until the next heartbeat, so
      // an instantaneous wish would visibly do nothing for up to a minute.
      sleeping = false
    }
    // The counter increments HERE, not in checkShenron: Shenron can appear and the menu be
    // dismissed, so counting wishes at the summon would overstate them.
    var st = Balls.applyWish(ballState, kind, now, generation)
    var np = progressState
    if (progressLive) {
      var p = JSON.parse(JSON.stringify(Levels.toSave(progressState.progress)))
      p.wishes = Math.min(1000000, p.wishes + 1)
      var loaded = Levels.load(p, { claimedPet: false, nowMs: now, clockReady: true })
      if (loaded.mode === "live") np = loaded
    }
    if (!commitPet(petSave({ balls: Balls.toSave(st), progress: Levels.toSave(np) })))
      return
    ballState = st
    progressState = np
    console.log("omagoku: wish " + kind)
  }

  // The panel cannot reach a specific RoamWindow, so the fetch is a latest-wins command
  // slot consumed once by the roam surface.
  property var fetchBall: null
  property int fetchNonce: 0
  function sendForBall() {
    if (!ballsOn || !roamSurface || !roaming) return
    var i = Balls.targetIndex(ballState, activeWorkspaceId, Date.now())
    if (i < 0) return
    fetchNonce += 1
    fetchBall = { index: i, nonce: fetchNonce }
  }
  readonly property int ballTarget: ballsOn
    ? Balls.targetIndex(ballState, activeWorkspaceId, nowMs) : -1
  readonly property int ballsCollected: Balls.collectedCount(ballState)

  // --- the rival, and the per-line behaviours ---------------------------------

  // Idea 8. The rival appears when a distant machine is working hard while the local pet is
  // transformed. `encounter` is TRI-STATE: unknown (a dead feed) leaves, exactly as false
  // does, because a rival lingering on stale evidence asserts a state nobody measured.
  readonly property var rivalEncounter: {
    if (settings.rivalEnabled === false || settings.quietMode === true) return false
    if (cockpit.status !== "ok" || !cockpit.trusted || cockpit.gpu === null) return "unknown"
    // The MACHINE truth, never display.cause: a full-moon night must neither fake an
    // encounter nor mask a real one.
    return cockpit.gpu.state === "generating" && effectiveRungIndex > 0
  }
  readonly property string rivalLine: {
    var l = Rival.lineFor(line)
    return l === null ? "" : l
  }
  readonly property string rivalForm: {
    var f = Rival.formFor(stage)
    return f === null ? "" : f
  }
  readonly property bool rivalPossible: rivalLine !== "" && rivalForm !== ""
    && settings.rivalEnabled !== false

  // Idea 10. Two channels, because Krillin's and Frieza's behaviours are emote-only and
  // cannot be expressed as a pose.
  property var behaviourState: Behaviour.emptyState()
  readonly property string rivalPhase: roamSurface ? roamSurface.rivalPhase : "none"

  readonly property bool behaviourPredicate: {
    if (settings.behavioursEnabled === false || !initialized || stage === "egg") return false
    switch (line) {
    case "vegeta":  return Behaviour.vegetaFurious(rawKiIndex, effectiveRungIndex)
    case "piccolo": return Behaviour.piccoloMeditates(inputIdle, fullscreenActive)
    case "frieza":  return Behaviour.friezaComplains(diskPercent, orphanCount)
    case "krillin": return Behaviour.krillinNervous(rivalPhase)
    default: return false
    }
  }
  // A behaviour may never mask a real state: any need emote, a care animation, sleep, or
  // the pet not being idle cancels it outright.
  readonly property bool behaviourBusy: sleeping || eating || transientAnim !== ""
    || activeEmotes.length > 0 || baseStateAnim !== "idle"

  readonly property bool behaviourActive: behaviourState.active === true
  readonly property string behaviourAnim: {
    if (!behaviourActive) return ""
    if (line === "vegeta") return "pushup"
    if (line === "piccolo") return "meditate"
    return ""
  }
  readonly property string behaviourEmote: {
    if (!behaviourActive) return ""
    if (line === "krillin") return "emote_nervous"
    if (line === "frieza") return "emote_dirty"
    return ""
  }

  Timer {
    interval: 1000
    running: root.initialized
    repeat: true
    onTriggered: root.behaviourState = Behaviour.next(
      root.behaviourState, root.behaviourPredicate, root.behaviourBusy, 1000)
  }

  // --- the ki sparkline -------------------------------------------------------

  property var kiBuckets: ({})
  property var sparkSeries: []
  function sampleKi() {
    if (kiPower === null || kiStatus !== "ok") return
    Ki.bucketUpsert(kiBuckets, Date.now(), kiPower, rawKiIndex)
  }
  // The series changes only when a bucket closes, so the panel is not re-laid-out on
  // every five-second poll.
  Timer {
    interval: 300000
    running: root.initialized
    repeat: true
    onTriggered: root.sparkSeries = Ki.bucketSeries(root.kiBuckets, Date.now())
  }

  onKiPowerChanged: {
    sampleKi()
    checkOver9000()
  }

  // --- probes ----------------------------------------------------------------

  // `checkupdates` has no timeout of its own and can block indefinitely on a pacman lock,
  // so a hung probe would sit on a stale integer forever and let a later recovery pay across
  // an unmarked gap. Fixed argv, never a shell string.
  //
  // EXIT 2 IS A TRUSTED ZERO, not an error: "no updates" is exactly how it reports success
  // with an empty list, so treating every non-zero exit as unknown would make an updates
  // recovery permanently unobservable.
  property string updatesStatus: "unknown"
  property double updatesSampledAt: 0
  Process {
    id: updatesProc
    command: ["timeout", "60", "checkupdates"]
    stdout: StdioCollector { id: updatesOut }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        var text = updatesOut.text.trim()
        root.pendingUpdates = text === "" ? 0 : text.split("\n").length
        root.updatesStatus = "ok"
        root.updatesSampledAt = Date.now()
      } else if (exitCode === 2) {
        root.pendingUpdates = 0
        root.updatesStatus = "ok"
        root.updatesSampledAt = Date.now()
      } else {
        // exit 1 = error (offline, db lock), 124 = the timeout fired. The previous count is
        // kept for flavour, but the XP latch is told the truth.
        root.updatesStatus = "unknown"
      }
      root.checkMaintenanceXp()
    }
  }

  Process {
    id: orphansProc
    command: ["pacman", "-Qdtq"]
    stdout: StdioCollector { id: orphansOut }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        var text = orphansOut.text.trim()
        root.orphanCount = text === "" ? 0 : text.split("\n").length
      } else {
        root.orphanCount = 0
      }
    }
  }

  // Disk and the two service managers, each its own fixed argv under a hard `timeout`, and
  // each carrying a generation id so a late exit can never overwrite a newer sample.
  property int probeGeneration: 0

  function runProbes() {
    probeGeneration += 1
    if (!diskProc.running) { diskProc.generation = probeGeneration; diskProc.running = true }
    if (!failedSysProc.running) {
      failedSysProc.generation = probeGeneration; failedSysProc.running = true
    }
    if (!failedUserProc.running) {
      failedUserProc.generation = probeGeneration; failedUserProc.running = true
    }
  }

  Process {
    id: diskProc
    property int generation: 0
    command: ["timeout", "10", "df", "--output=source,target,pcent", "/", "/home"]
    stdout: StdioCollector { id: diskOut }
    onExited: function(exitCode) {
      if (generation < root.probeGeneration) return
      var r = exitCode === 0 ? Probes.parseDf(diskOut.text) : { status: "error" }
      r.sampledAtMs = Date.now()
      root.diskProbe = r
      root.checkProbeAlerts()
      root.checkMaintenanceXp()
    }
  }

  Process {
    id: failedSysProc
    property int generation: 0
    command: ["timeout", "10", "systemctl", "--failed", "--no-pager", "--no-legend", "--plain"]
    stdout: StdioCollector { id: failedSysOut }
    onExited: function(exitCode) {
      if (generation < root.probeGeneration) return
      var r = exitCode === 0 ? Probes.parseFailedUnits(failedSysOut.text)
                             : { status: "error" }
      r.sampledAtMs = Date.now()
      root.failedSysProbe = r
      root.checkProbeAlerts()
      root.checkMaintenanceXp()
    }
  }

  Process {
    id: failedUserProc
    property int generation: 0
    command: ["timeout", "10", "systemctl", "--user", "--failed", "--no-pager",
              "--no-legend", "--plain"]
    stdout: StdioCollector { id: failedUserOut }
    onExited: function(exitCode) {
      if (generation < root.probeGeneration) return
      var r = exitCode === 0 ? Probes.parseFailedUnits(failedUserOut.text)
                             : { status: "error" }
      r.sampledAtMs = Date.now()
      root.failedUserProbe = r
      root.checkProbeAlerts()
      root.checkMaintenanceXp()
    }
  }

  // The heartbeat: needs, age, care sampling and evolution, every minute.
  //
  // The ORDER is pinned, because the lifetime care aggregate has to read the same captured
  // happiness as the stage aggregate, behind the same predicate, in the same reducer call.
  Timer {
    id: heartbeat
    interval: 60 * 1000
    running: root.initialized && !root.saveBlocked
    repeat: true
    onTriggered: {
      root.nowMs = Date.now()
      root.refreshMoon()
      // An unclaimed pod must not age or it hatches overnight. The line property gates
      // everything: without it a pet does not exist yet, so it has no needs to age, no
      // happiness to sample, and no evolution to pursue. Only an unchosen pod is left behind
      // when a save loads.
      if (root.line === "") return
      if (!root.canMutatePet()) return
      root.applyMinute()
      // It still grows overnight -- age is the reward for time, and it was never the
      // complaint. But care is NOT sampled while it sleeps through the night: eleven hours
      // of identical samples would drown the waking day it actually reflects, and nobody
      // can care for a sleeping pet.
      root.ageMinutes += 1
      // Captured ONCE, and both aggregates read this value behind this predicate.
      var sampled = root.happiness
      var sample = !(root.nightResting && root.sleeping)
      if (sample) {
        root.careSum += sampled
        root.careCount += 1
      }
      root.accrueMinuteXp(sample, sampled)
      root.maybeEvolve()
      root.checkMoon()
      root.checkTransformation()
      root.checkNeeds()
      root.checkFleetSurge()
      root.ballTick()
      root.checkShenron()
      root.maybeAmbientMove()
      root.maybeChatter()
      if (root.careCount % 5 === 0) root.flushPet()
    }
  }
  // Both probes only flavor the pace, so every 30 minutes is plenty (and
  // checkupdates syncs its own db copy each time).
  Timer {
    interval: 30 * 60 * 1000
    running: root.initialized
    repeat: true
    onTriggered: orphansProc.running = true
  }
  Timer {
    interval: 30 * 60 * 1000
    running: root.initialized
    repeat: true
    onTriggered: updatesProc.running = true
  }
  Timer {
    interval: 30 * 60 * 1000
    running: root.initialized
    repeat: true
    onTriggered: root.runProbes()
  }

  // --- roaming ---------------------------------------------------------------

  // Outputs coming and going (monitors powered off, lock, unplug) destroy the
  // roam layer surface while QML still believes the window is visible — the
  // pet keeps "roaming" with nowhere to be drawn, and the return sequence's
  // visible-gated timers never fire. Dropping visibility for a beat after the
  // screen list settles forces Quickshell to map a fresh surface.
  property bool screensSettled: true
  Connections {
    target: Quickshell
    function onScreensChanged() {
      root.screensSettled = false
      screensSettleTimer.restart()
    }
  }
  Timer {
    id: screensSettleTimer
    interval: 1000
    onTriggered: root.screensSettled = true
  }

  // Deliberately a static window with a visibility binding, not a Loader:
  // dynamically created windows leak a zombie layer surface across the shell's
  // plugin hot-reload, which then wedges screencopy (grim) on that output.
  RoamWindow {
    id: roamWindow
    petService: root
    visible: root.initialized && root.roaming && root.screensSettled
    Component.onCompleted: root.roamSurface = roamWindow
  }

  // --- persistence -----------------------------------------------------------

  // Bounded reads: at most maxStateBytes per file, once at startup. A file
  // that fills the cap (or can't be read) counts as empty → defaults.
  function boundedText(collector, exitCode) {
    if (exitCode !== 0) return ""
    var text = collector.text
    return text.length >= maxStateBytes ? "" : text
  }

  Process {
    id: settingsReader
    command: ["head", "-c", String(root.maxStateBytes), root.settingsPath]
    running: true
    stdout: StdioCollector { id: settingsOut }
    onExited: function(exitCode) {
      root.loadedSettingsText = root.boundedText(settingsOut, exitCode)
      root.settingsFileLoaded = true
      root.initializeIfReady()
    }
  }

  Process {
    id: petReader
    command: ["head", "-c", String(root.maxStateBytes), root.petPath]
    running: true
    stdout: StdioCollector { id: petOut }
    onExited: function(exitCode) {
      root.loadedPetText = root.boundedText(petOut, exitCode)
      if (exitCode === 0 && petOut.text.length >= root.maxStateBytes)
        root.petReadProblem = "exceeds " + root.maxStateBytes + " bytes"
      root.petFileLoaded = true
      root.initializeIfReady()
    }
  }

  Process {
    id: notifyReader
    command: ["head", "-c", String(root.maxStateBytes), root.notifyPath]
    running: true
    stdout: StdioCollector { id: notifyOut }
    onExited: function(exitCode) {
      root.loadedNotifyText = root.boundedText(notifyOut, exitCode)
      if (root.loadedNotifyText !== "") {
        root.notifyState = Budget.loadState(root.loadedNotifyText, Date.now())
        root.effectsState = Effects.loadState(root.loadedNotifyText, Date.now(),
                                             { moveIds: Moves.ids(), clockReady: false })
      }
      root.notifyFileLoaded = true
      root.initializeIfReady()
    }
  }

  // Write-only views: preload off, text() is never called, so the shell
  // never maps these files itself.
  FileView {
    id: notifyFile
    path: root.notifyPath
    preload: false
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  FileView {
    id: settingsFile
    path: root.settingsPath
    preload: false
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  // The lineage reader, three fixed-argv probes with unambiguous exit codes.
  //
  // `head` alone cannot tell a missing file from a permission failure, and letting the
  // second look like the first is how "no history yet" becomes a creatable empty record
  // that overwrites every generation on the next ending. So: stat for the size, and on any
  // stat failure a `test -e` whose exit 1 is the only thing accepted as absence. A residual
  // race between the probes is possible and lands on `corrupt`, which is read-only.
  // The local ki producer's I/O. Bounded, fixed argv, and only running when there is no
  // external producer to defer to.
  // Its own timer, deliberately. blockSaves() stops the heartbeat, and a full or read-only
  // state directory is exactly the condition that both blocks saves AND can wedge a lineage
  // write -- so driving this from the heartbeat silenced the only user-visible report of a
  // wedged write in the one case it exists for.
  Timer {
    id: lineageStuckTimer
    interval: 60000
    running: root.lineageBusy
    repeat: true
    onTriggered: root.tickLineageStuck()
  }

  Timer {
    id: localKiTimer
    interval: 5000
    running: root.initialized && root.usingLocalKi
    repeat: true
    triggeredOnStart: true
    onTriggered: localKiRead.running = true
  }

  // Nothing else creates this directory. On a machine where no Omarchy component has
  // written state yet, the first save fails and freezes the pet with a message that does
  // not say why.
  Process {
    id: stateDirInit
    command: ["mkdir", "-p", root.stateDir]
    running: true
    stdout: StdioCollector { }
  }

  Process {
    id: localKiRead
    command: ["head", "-c", "256", "/proc/stat"]
    stdout: StdioCollector { id: localKiOut }
    onExited: function (exitCode) {
      if (exitCode !== 0) return
      var sample = LocalKi.parse(localKiOut.text)
      if (sample === null) return
      var fraction = LocalKi.busyFraction(root.localKiPrev, sample)
      root.localKiPrev = sample
      // The first poll has nothing to difference against, and a counter that went backwards
      // is a reboot. Both mean "no reading yet", not "the machine is calm".
      if (fraction === null) return
      root.localKiSmoothed = LocalKi.smooth(root.localKiSmoothed, fraction)
      root.localKiState = LocalKi.state(root.localKiSmoothed)
    }
  }

  Process {
    id: lineageStat
    command: ["stat", "-c", "%s", root.lineagePath]
    running: true
    stdout: StdioCollector { id: lineageStatOut }
    onExited: function(exitCode) {
      if (exitCode !== 0) { lineageExists.running = true; return }
      var size = parseInt(lineageStatOut.text.trim(), 10)
      if (!isFinite(size) || size > root.maxStateBytes) {
        root.lineageState = Lineage.load({ status: "error", text: "", bytes: 0 })
        root.lineageReady = true
        console.warn("omagoku: lineage file is oversized or unreadable, read-only")
        return
      }
      lineageRead.running = true
    }
  }
  Process {
    id: lineageExists
    command: ["test", "-e", root.lineagePath]
    stdout: StdioCollector { }
    onExited: function(exitCode) {
      // Exit 1 is the ONLY confirmation of absence. Anything else exists but could not be
      // read, which is a fault, not a fresh start.
      root.lineageState = Lineage.load({
        status: exitCode === 1 ? "missing" : "error", text: "", bytes: 0 })
      root.lineageReady = true
      if (exitCode !== 1)
        console.warn("omagoku: lineage file exists but could not be read, read-only")
    }
  }
  Process {
    id: lineageRead
    command: ["head", "-c", String(root.maxStateBytes), root.lineagePath]
    stdout: StdioCollector { id: lineageOut }
    onExited: function(exitCode) {
      var text = exitCode === 0 ? lineageOut.text : ""
      root.lineageState = Lineage.load({
        status: exitCode === 0 ? "ok" : "error", text: text, bytes: text.length })
      root.lineageReady = true
      // Tests the property that matters, not the mode STRING: `partial` is a state in
      // which no future ending will ever be recorded, and branching on === "corrupt"
      // announced it at log level in the same shape as a healthy load.
      if (!Lineage.canWrite(root.lineageState.mode))
        console.warn("omagoku: lineage " + root.lineageState.mode + " -- READ-ONLY, "
                     + root.lineageState.record.entries.length + " readable, "
                     + root.lineageState.unreadableRows + " unreadable; endings will NOT "
                     + "be recorded until it is repaired or archived")
      else
        console.log("omagoku: lineage " + root.lineageState.mode + ", "
                    + root.lineageState.record.entries.length + " entries"
                    + (root.lineageState.droppedByCap > 0
                       ? " (" + root.lineageState.droppedByCap + " older dropped by the cap)"
                       : ""))
    }
  }

  // One Component, and every write creates its own writer from it. FileView.saved is a
  // bare signal on a shared object, so a token kept in QML cannot tell a late or duplicate
  // completion from the current one; a writer that serves exactly one setText and is then
  // retired makes the token an object identity instead.
  Component {
    id: lineageWriter
    FileView {
      preload: false
      watchChanges: false
      atomicWrites: true
      printErrors: false
      // DECLARED, not an expando: a FileView is a QML object and will not take one.
      property bool terminalSeen: false
    }
  }

  Process {
    id: archiveCopy
    command: ["cp", "--no-clobber", root.lineagePath, root.pendingArchivePath]
    stdout: StdioCollector { }
    onExited: function (exitCode) { root.archiveCopyTerminal(exitCode) }
  }

  FileView {
    id: petFile
    path: root.petPath
    preload: false
    watchChanges: false
    atomicWrites: true
    printErrors: false
    // Fitting is not persisting. Without this, ENOSPC or a permission change would advance
    // XP, cooldowns and the hunt in memory while the disk stayed exactly as it was.
    onSaveFailed: function (error) {
      root.blockSaves("the state file could not be written (" + error + ")")
    }
  }
}
