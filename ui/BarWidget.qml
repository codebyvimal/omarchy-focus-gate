import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons

// Focus Gate bar widget.
//
// Reads one live JSON state file written by the daemon:
//   ~/.local/state/omarchy/focus-gate/state.json
// and one user config:
//   ~/.config/omarchy-focus-gate/config.json
//
// Idle label:
//   locked   🔒 0m/3h study     (progress toward the daily study goal)
//   unlocked 🔓 42m game left    (remaining daily gaming allowance)
// In the final 10-minute warning window before a game cutoff the bar icon
// pulses in the theme's urgent color.
//
// Left-click opens a panel showing two arc progress rings (Study / Gaming),
// a session start/stop button, and the countdown to the 5 AM reset.
// The panel speaks the standard popup contract (opened/open/close/toggle)
// so the bar's popout coordinator, Tab navigation, and indicator all work.

BarWidget {
  id: root
  moduleName: "omarchy-focus-gate"

  readonly property string home: Quickshell.env("HOME")
  readonly property string statePath:   home + "/.local/state/omarchy/focus-gate/state.json"
  readonly property string configPath:  home + "/.config/omarchy-focus-gate/config.json"

  readonly property string studyScriptPath:
    home + "/.config/omarchy/plugins/omarchy-focus-gate/bin/omarchy-focus-gate-study"
  readonly property string installScriptPath:
    home + "/.config/omarchy/plugins/omarchy-focus-gate/bin/omarchy-focus-gate-install"

  // ---- Live state (mirrored from state.json; replaced, never mutated) ----
  property string stEffectiveDate:  ""
  property int    stStudySeconds:   0
  property int    stGameSeconds:    0
  property bool   stUnlocked:       false
  property bool   stSessionActive:  false

  // ---- Config (with sane defaults until config.json is read) -------------
  property int requiredStudySeconds:  10800
  property int dailyAllowanceSeconds: 3600
  property int resetHourLocal:        5
  property int warningSeconds:        600

  // Freshness flag so the panel doesn't flash defaults before the first
  // file read lands.
  property bool loaded: false

  function refresh() {
    var s = root.stateContent
    var c = root.configContent
    if (Util.isPlainObject(s)) {
      root.stEffectiveDate   = String(s.effective_date        || "")
      root.stStudySeconds    = Number(s.study_seconds_today    || 0)
      root.stGameSeconds     = Number(s.game_seconds_used_today || 0)
      root.stUnlocked        = s.unlocked             === true
      root.stSessionActive   = s.study_session_active === true
    }
    if (Util.isPlainObject(c)) {
      root.requiredStudySeconds  = Number(c.required_study_seconds       || 10800)
      root.dailyAllowanceSeconds = Number(c.daily_game_allowance_seconds || 3600)
      root.resetHourLocal        = Number(c.reset_hour_local             || 5)
      root.warningSeconds        = Number(c.warning_seconds_before_cutoff || 600)
    }
    root.loaded = true
  }

  // ---- Derived values ----------------------------------------------------

  readonly property int remainingGameSeconds:
    Math.max(0, root.dailyAllowanceSeconds - root.stGameSeconds)

  // True when the gate is open, game time is actively running down, and
  // the final warning window has been entered. The UI can't detect whether
  // a game is actually running, so this fires on time alone — an
  // intentional approximation that matches the daemon's behaviour.
  readonly property bool inWarningWindow:
    root.stUnlocked
    && root.remainingGameSeconds > 0
    && root.remainingGameSeconds <= root.warningSeconds

  readonly property bool stateDirMissing: root.loaded && root.stEffectiveDate === ""

  // "12m" / "1h" / "1h 30m"
  function fmt(seconds) {
    var sec = Math.max(0, Number(seconds) || 0)
    var h   = Math.floor(sec / 3600)
    var m   = Math.round((sec % 3600) / 60)
    if (m === 60) { h++; m = 0 }
    if (h > 0) return m > 0 ? h + "h " + m + "m" : h + "h"
    return m + "m"
  }

  readonly property string glyph: root.stUnlocked ? "\uF09C" : "\uF023"  // nf-fa-unlock / nf-fa-lock
  readonly property string label: root.stUnlocked
    ? root.fmt(root.remainingGameSeconds) + " game left"
    : root.fmt(root.stStudySeconds) + "/" + root.fmt(root.requiredStudySeconds) + " study"
  readonly property string fullText: (root.stateDirMissing ? "" : root.glyph + " ") + root.label

  readonly property real openPanelIndicatorWidth:
    Math.max(Style.space(10), Math.round(Math.min(120, button.labelWidth || 0)))
  readonly property real openPanelIndicatorHeight:
    Math.max(1, Math.round(Style.bar.iconSlot * 0.55))

  implicitWidth:  button.implicitWidth
  implicitHeight: button.implicitHeight

  // ---- Study session control ---------------------------------------------

  function startStudy() {
    if (studyProc.running) return
    studyProc.command = [root.studyScriptPath, "start"]
    studyProc.running = true
  }

  function stopStudy() {
    if (studyProc.running) return
    studyProc.command = [root.studyScriptPath, "stop"]
    studyProc.running = true
  }

  Process {
    id: studyProc
    environment: ({ HOME: root.home })
  }

  // ---- File watchers -----------------------------------------------------

  FileView {
    id: stateFile
    path: root.statePath
    printErrors: false
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      try   { stateContent = JSON.parse(String(text() || "{}")) }
      catch (e) { stateContent = null }
      root.refresh()
    }
    onLoadFailed: { stateContent = null; root.refresh() }
  }

  property var stateContent: null

  FileView {
    id: configFile
    path: root.configPath
    printErrors: false
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      try   { configContent = JSON.parse(String(text() || "{}")) }
      catch (e) { configContent = null }
      root.refresh()
    }
    onLoadFailed: { configContent = null; root.refresh() }
  }

  property var configContent: null

  // Run the install hook once on startup to ensure config/state dirs exist
  // and default files are written. The hook is fully idempotent — it skips
  // everything that already exists, so existing config edits survive.
  Process {
    id: ensureProc
    environment: ({ HOME: root.home })
    command: [root.installScriptPath]
    onExited: {
      stateFile.reload()
      configFile.reload()
    }
  }

  // ---- Bar button --------------------------------------------------------

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.fullText
    horizontalMargin: 8.5
    tooltipText: root.stUnlocked
      ? "Focus Gate \u00b7 unlocked \u00b7 " + root.fmt(root.remainingGameSeconds) + " game time left"
      : "Focus Gate \u00b7 locked \u00b7 " + root.fmt(root.stStudySeconds) + "/" + root.fmt(root.requiredStudySeconds) + " studied"
    onPressed: function(b) {
      if (b === Qt.RightButton) root.close()
      else root.togglePanel()
    }
  }

  // Urgent-color pulse during the pre-cutoff warning window.
  SequentialAnimation on opacity {
    running: root.inWarningWindow
    loops: Animation.Infinite
    NumberAnimation { to: 0.45; duration: 750; easing.type: Easing.InOutSine }
    NumberAnimation { to: 1.0;  duration: 750; easing.type: Easing.InOutSine }
  }

  // ---- Popup panel -------------------------------------------------------

  readonly property bool opened: popup.open

  function open()        { popup.open = true }
  function close()       { popup.open = false }
  function togglePanel() { popup.open = !popup.open }

  IpcHandler {
    target: "omarchy-focus-gate"

    function open(): void   { root.open() }
    function close(): void  { root.close() }
    function show(): void   { root.open() }
    function hide(): void   { root.close() }
    function toggle(): void { root.togglePanel() }
    function status(): void {
      console.log("omarchy-focus-gate status: unlocked=" + root.stUnlocked
        + " study=" + root.stStudySeconds + " game=" + root.stGameSeconds
        + " sessionActive=" + root.stSessionActive + " opened=" + root.opened)
    }
  }

  PopupCard {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: false
    contentWidth:  popup.fittedContentWidth(Style.space(300))
    contentHeight: popup.fittedContentHeight(panelColumn.implicitHeight)

    Column {
      id: panelColumn
      anchors.fill: parent
      spacing: Style.spacing.lg

      // ---- Header --------------------------------------------------------
      Item {
        width: parent.width
        height: headerRow.implicitHeight

        Row {
          id: headerRow
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.sm

          Text {
            text: root.glyph
            color: root.stUnlocked ? Color.accent : root.bar.barForeground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            text: "Focus Gate"
            color: root.bar.barForeground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            anchors.verticalCenter: parent.verticalCenter
          }
        }

        PanelActionButton {
          iconText: "\uF011"   // nf-fa-power-off
          tooltipText: "Close panel"
          foreground: root.bar.barForeground
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.close()
        }
      }

      PanelSeparator { }

      // ---- Dual arc row: Study | Gaming ----------------------------------
      Row {
        width: parent.width
        spacing: 0

        // --- Study arc ---
        Column {
          width: parent.width / 2
          spacing: Style.spacing.md

          // Arc
          Item {
            width: parent.width
            height: 96

            Canvas {
              id: studyArc
              width: 92; height: 92
              anchors.horizontalCenter: parent.horizontalCenter

              readonly property real progress: root.requiredStudySeconds > 0
                ? Math.min(1.0, root.stStudySeconds / root.requiredStudySeconds) : 0

              readonly property color trackCol: Qt.rgba(
                root.bar.barForeground.r, root.bar.barForeground.g,
                root.bar.barForeground.b, 0.13)

              readonly property color fillCol:
                root.stUnlocked ? Color.accent : root.bar.barForeground

              onProgressChanged:   requestPaint()
              onTrackColChanged:   requestPaint()
              onFillColChanged:    requestPaint()

              onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                var cx = width / 2, cy = height / 2
                var r  = width / 2 - 7
                // 270° arc: starts at 135° (bottom-left), sweeps clockwise
                var startA = Math.PI * 0.75
                var sweep  = Math.PI * 1.5

                // Track (full 270°)
                ctx.beginPath()
                ctx.arc(cx, cy, r, startA, startA + sweep)
                ctx.strokeStyle = trackCol
                ctx.lineWidth = 7
                ctx.lineCap = "round"
                ctx.stroke()

                // Progress fill
                if (progress > 0.005) {
                  ctx.beginPath()
                  ctx.arc(cx, cy, r, startA, startA + progress * sweep)
                  ctx.strokeStyle = fillCol
                  ctx.lineWidth = 7
                  ctx.lineCap = "round"
                  ctx.stroke()
                }
              }

              // Center: time studied so far
              Column {
                anchors.centerIn: parent
                spacing: 0

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: root.fmt(root.stStudySeconds)
                  color: root.stUnlocked ? Color.accent : root.bar.barForeground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: root.stSessionActive ? "live" : "paused"
                  color: root.stSessionActive ? Color.accent : root.bar.barForeground
                  opacity: root.stSessionActive ? 0.9 : 0.35
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // Labels below arc
          Column {
            width: parent.width
            spacing: 1

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "STUDY"
              color: root.bar.barForeground
              opacity: 0.45
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.fmt(root.stStudySeconds) + " / " + root.fmt(root.requiredStudySeconds)
              color: root.bar.barForeground
              opacity: 0.65
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }

        // --- Gaming arc ---
        Column {
          width: parent.width / 2
          spacing: Style.spacing.md

          // Arc
          Item {
            width: parent.width
            height: 96

            Canvas {
              id: gamingArc
              width: 92; height: 92
              anchors.horizontalCenter: parent.horizontalCenter

              readonly property real progress: root.stUnlocked && root.dailyAllowanceSeconds > 0
                ? Math.min(1.0, root.stGameSeconds / root.dailyAllowanceSeconds) : 0

              readonly property color trackCol: Qt.rgba(
                root.bar.barForeground.r, root.bar.barForeground.g,
                root.bar.barForeground.b, 0.13)

              readonly property color fillCol: root.inWarningWindow
                ? Color.accent
                : Qt.rgba(root.bar.barForeground.r, root.bar.barForeground.g,
                          root.bar.barForeground.b, root.stUnlocked ? 0.75 : 0.22)

              onProgressChanged:   requestPaint()
              onTrackColChanged:   requestPaint()
              onFillColChanged:    requestPaint()

              onPaint: {
                var ctx = getContext("2d")
                ctx.clearRect(0, 0, width, height)
                var cx = width / 2, cy = height / 2
                var r  = width / 2 - 7
                var startA = Math.PI * 0.75
                var sweep  = Math.PI * 1.5

                // Track
                ctx.beginPath()
                ctx.arc(cx, cy, r, startA, startA + sweep)
                ctx.strokeStyle = trackCol
                ctx.lineWidth = 7
                ctx.lineCap = "round"
                ctx.stroke()

                // Fill (only meaningful once unlocked)
                if (progress > 0.005) {
                  ctx.beginPath()
                  ctx.arc(cx, cy, r, startA, startA + progress * sweep)
                  ctx.strokeStyle = fillCol
                  ctx.lineWidth = 7
                  ctx.lineCap = "round"
                  ctx.stroke()
                }
              }

              // Center: remaining time or lock icon when still locked
              Column {
                anchors.centerIn: parent
                spacing: 0

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: root.stUnlocked
                    ? root.fmt(root.remainingGameSeconds)
                    : "\uF023"   // nf-fa-lock
                  color: root.inWarningWindow
                    ? Color.accent : root.bar.barForeground
                  opacity: root.stUnlocked ? 1.0 : 0.3
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  visible: root.stUnlocked
                  text: root.remainingGameSeconds > 0 ? "left" : "spent"
                  color: root.inWarningWindow ? Color.accent : root.bar.barForeground
                  opacity: 0.55
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // Labels below arc
          Column {
            width: parent.width
            spacing: 1

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: "GAMING"
              color: root.bar.barForeground
              opacity: 0.45
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1
            }

            Text {
              anchors.horizontalCenter: parent.horizontalCenter
              text: root.stUnlocked
                ? root.fmt(root.stGameSeconds) + " / " + root.fmt(root.dailyAllowanceSeconds)
                : "study to unlock"
              color: root.inWarningWindow ? Color.accent : root.bar.barForeground
              opacity: 0.65
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }
        }
      }

      // ---- Session toggle button -----------------------------------------
      Button {
        width: parent.width
        text: root.stSessionActive ? "Stop study session" : "Start study session"
        iconText: root.stSessionActive ? "\uF04D" : "\uF04B"  // nf-fa-stop / nf-fa-play
        foreground: root.bar.barForeground
        accent: Color.accent
        fontFamily: root.bar.fontFamily
        fontSize: Style.font.body
        onClicked: root.stSessionActive ? root.stopStudy() : root.startStudy()
      }

      // ---- Reset countdown pill ------------------------------------------
      Rectangle {
        width: parent.width
        height: resetRow.implicitHeight + Style.space(10)
        radius: Style.space(6)
        color: Qt.rgba(root.bar.barForeground.r, root.bar.barForeground.g,
                       root.bar.barForeground.b, 0.06)

        Row {
          id: resetRow
          anchors {
            left: parent.left;   leftMargin:  Style.space(10)
            right: parent.right; rightMargin: Style.space(10)
            top: parent.top;     topMargin:   Style.space(5)
          }
          spacing: Style.spacing.sm

          Text {
            text: "\uF017"   // nf-fa-clock-o
            color: root.bar.barForeground
            opacity: 0.5
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            text: root.resetCountdownText
            color: root.bar.barForeground
            opacity: 0.75
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            anchors.verticalCenter: parent.verticalCenter
          }
        }
      }
    }
  }

  // "Resets at 05:00 in 6h 23m" — re-evaluated every 30s via dawnTick.
  property int dawnTick: 0
  readonly property string resetCountdownText: {
    root.dawnTick
    var now  = new Date()
    var next = new Date()
    next.setHours(root.resetHourLocal, 0, 0, 0)
    if (next <= now) next.setDate(next.getDate() + 1)
    var mins = Math.round((next - now) / 60000)
    var h    = Math.floor(mins / 60)
    var m    = mins % 60
    var pad  = (root.resetHourLocal < 10 ? "0" : "") + root.resetHourLocal
    return "Resets at " + pad + ":00 in " + h + "h " + m + "m"
  }

  Timer {
    interval: 30000
    repeat: true
    running: true
    onTriggered: root.dawnTick++
  }

  Component.onCompleted: {
    ensureProc.running = true
  }
}