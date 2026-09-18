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
// In the final 10-minute warning window before a game cutoff the icon
// pulses in the theme's urgent color.
//
// Left-click opens a panel with Start/Stop study buttons, today's totals,
// and the countdown to the 5 AM reset. The panel speaks the standard
// popup contract (opened/open/close/toggle) so the bar's popout
// coordinator, Tab navigation, and open-panel indicator all work.

BarWidget {
  id: root
  moduleName: "omarchy-focus-gate"

  readonly property string home: Quickshell.env("HOME")
  readonly property string statePath: home + "/.local/state/omarchy/focus-gate/state.json"
  readonly property string configPath: home + "/.config/omarchy-focus-gate/config.json"

  // Scripts ship alongside the plugin; compute the absolute path so they
  // work regardless of where the plugin was cloned.
  readonly property string studyScriptPath: {
    var u = Qt.resolvedUrl("../bin/omarchy-focus-gate-study").toString()
    return u.startsWith("file://") ? u.slice(7) : u
  }

  // ---- Live state (mirrored from state.json; replaced, never mutated) ----
  property string stEffectiveDate: ""
  property int stStudySeconds: 0
  property int stGameSeconds: 0
  property bool stUnlocked: false
  property bool stSessionActive: false

  // ---- Config (with sane defaults until config.json is read) -------------
  property int requiredStudySeconds: 10800
  property int dailyAllowanceSeconds: 3600
  property int resetHourLocal: 5
  property int warningSeconds: 600

  // Freshness flag so the panel doesn't flash defaults before the first
  // file read lands.
  property bool loaded: false

  function refresh() {
    var s = stateAdapter.state
    var c = configAdapter.config
    if (Util.isPlainObject(s)) {
      root.stEffectiveDate = String(s.effective_date || "")
      root.stStudySeconds = Number(s.study_seconds_today || 0)
      root.stGameSeconds = Number(s.game_seconds_used_today || 0)
      root.stUnlocked = s.unlocked === true
      root.stSessionActive = s.study_session_active === true
    }
    if (Util.isPlainObject(c)) {
      root.requiredStudySeconds = Number(c.required_study_seconds || 10800)
      root.dailyAllowanceSeconds = Number(c.daily_game_allowance_seconds || 3600)
      root.resetHourLocal = Number(c.reset_hour_local || 5)
      root.warningSeconds = Number(c.warning_seconds_before_cutoff || 600)
    }
    root.loaded = true
  }

  // ---- Derived values ----------------------------------------------------

  readonly property int remainingGameSeconds: Math.max(0, root.dailyAllowanceSeconds - root.stGameSeconds)
  readonly property bool inWarningWindow: root.stUnlocked && root.remainingGameSeconds > 0
    && root.remainingGameSeconds <= root.warningSeconds
  readonly property bool stateDirMissing: root.loaded && root.stEffectiveDate === ""

  // "12m" / "1h" / "1h30m"
  function fmt(seconds) {
    var sec = Math.max(0, Number(seconds) || 0)
    var h = Math.floor(sec / 3600)
    var m = Math.round((sec % 3600) / 60)
    if (m === 60) { h++; m = 0 }
    if (h > 0) return m > 0 ? h + "h" + m + "m" : h + "h"
    return m + "m"
  }

  readonly property string glyph: root.stUnlocked ? "\uF09C" : "\uF023" // nf-fa-lock-open / nf-fa-lock
  readonly property string label: root.stUnlocked
    ? root.fmt(root.remainingGameSeconds) + " game left"
    : root.fmt(root.stStudySeconds) + "/" + root.fmt(root.requiredStudySeconds) + " study"
  readonly property string fullText: (root.stateDirMissing ? "" : root.glyph + " ") + root.label

  readonly property real openPanelIndicatorWidth: Math.max(Style.space(10), Math.round(Math.min(120, button.labelWidth || 0)))
  readonly property real openPanelIndicatorHeight: Math.max(1, Math.round(Style.bar.iconSlot * 0.55))

  implicitWidth: button.implicitWidth
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

  // Refresh when the daemon (or the CLI) rewrites either file.
  FileView {
    id: stateFile
    path: root.statePath
    printErrors: false
    onAdapterUpdated: root.refresh()
    onLoaded: root.refresh()
    onLoadFailed: root.refresh()
    JsonAdapter {
      id: stateAdapter
      property var state: null
    }
  }

  FileView {
    id: configFile
    path: root.configPath
    printErrors: false
    onAdapterUpdated: root.refresh()
    onLoaded: root.refresh()
    onLoadFailed: root.refresh()
    JsonAdapter {
      id: configAdapter
      property var config: null
    }
  }

  // Create the state/config dirs and default files on first run, then wire
  // the file watchers. (Mirrors the install hook so the widget is usable
  // even before the systemd timer is registered.)
  Process {
    id: ensureProc
    environment: ({ HOME: root.home })
    command: ["bash", "-c",
      "mkdir -p \"$HOME/.local/state/omarchy/focus-gate\" \"$HOME/.config/omarchy-focus-gate\"; " +
      "[[ -f \"$HOME/.config/omarchy-focus-gate/config.json\" ]] || printf '{\n  \"required_study_seconds\": 10800,\n  \"daily_game_allowance_seconds\": 3600,\n  \"reset_hour_local\": 5,\n  \"warning_seconds_before_cutoff\": 600,\n  \"tracked_game_processes\": [\"steam\", \"lutris\", \"heroic\", \"bottles\", \"sober\", \"t-launcher\", \"retroarch\", \"minecraft-launcher\", \"prismlauncher\"]\n}\n' > \"$HOME/.config/omarchy-focus-gate/config.json\"; " +
      "[[ -f \"$HOME/.local/state/omarchy/focus-gate/state.json\" ]] || printf '{\"effective_date\": \"1970-01-01\",\"study_seconds_today\": 0,\"game_seconds_used_today\": 0,\"unlocked\": false,\"study_session_active\": false}\n' > \"$HOME/.local/state/omarchy/focus-gate/state.json\""]
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
    NumberAnimation { to: 1.0; duration: 750; easing.type: Easing.InOutSine }
  }

  // ---- Popup panel -------------------------------------------------------

  readonly property bool opened: popup.open

  function open() { popup.open = true }
  function close() { popup.open = false }
  function togglePanel() { popup.open = !popup.open }

  IpcHandler {
    target: "omarchy-focus-gate"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
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
    contentWidth: popup.fittedContentWidth(Style.space(300))
    contentHeight: popup.fittedContentHeight(panelColumn.implicitHeight)

    Column {
      id: panelColumn
      anchors.fill: parent
      spacing: Style.spacing.lg

      // ---- Header ----
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
          iconText: "\uF011" // nf-fa-power-off
          tooltipText: "Close panel"
          foreground: root.bar.barForeground
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          onClicked: root.close()
        }
      }

      // ---- Status hero ----
      Item {
        width: parent.width
        height: Math.max(statusColumn.implicitHeight, statusGlyph.implicitHeight)

        Text {
          id: statusGlyph
          text: root.stUnlocked ? "\uF09C" : "\uF023"
          color: root.stUnlocked ? Color.accent : root.bar.barForeground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.display
          font.bold: true
          anchors.verticalCenter: parent.verticalCenter
        }

        Column {
          id: statusColumn
          anchors.left: statusGlyph.right
          anchors.leftMargin: Style.spacing.lg
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.spacing.xxs

          Text {
            text: root.stUnlocked
              ? (root.remainingGameSeconds > 0 ? "Unlocked \u00b7 " + root.fmt(root.remainingGameSeconds) + " left" : "Unlocked \u00b7 allowance spent")
              : "Locked"
            color: root.inWarningWindow ? Color.accent : root.bar.barForeground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
          }

          Text {
            text: root.stUnlocked
              ? "Study goal met \u2014 games allowed until the allowance runs out."
              : "Study " + root.fmt(root.requiredStudySeconds) + " to unlock gaming."
            color: root.bar.barForeground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
        }
      }

      PanelSeparator { }

      // ---- Study ----
      PanelSectionHeader {
        text: "STUDY \u00b7 TODAY " + root.fmt(root.stStudySeconds) + " / " + root.fmt(root.requiredStudySeconds)
        foreground: root.bar.barForeground
        fontFamily: root.bar.fontFamily
      }

      Rectangle {
        width: parent.width
        height: Style.space(6)
        radius: height / 2
        color: Qt.rgba(root.bar.barForeground.r, root.bar.barForeground.g, root.bar.barForeground.b, 0.12)

        Rectangle {
          width: parent.width * Math.min(1, root.requiredStudySeconds > 0 ? root.stStudySeconds / root.requiredStudySeconds : 0)
          height: parent.height
          radius: height / 2
          color: root.stUnlocked ? Color.accent : root.bar.barForeground
          opacity: 0.85
        }
      }

      Button {
        width: parent.width
        text: root.stSessionActive ? "Stop study session" : "Start study session"
        iconText: root.stSessionActive ? "\uF04D" : "\uF04B" // nf-fa-stop / nf-fa-play
        foreground: root.bar.barForeground
        accent: Color.accent
        fontFamily: root.bar.fontFamily
        fontSize: Style.font.body
        onClicked: root.stSessionActive ? root.stopStudy() : root.startStudy()
      }

      // ---- Gaming ----
      PanelSectionHeader {
        text: "GAMING \u00b7 TODAY " + root.fmt(root.stGameSeconds) + " / " + root.fmt(root.dailyAllowanceSeconds)
        foreground: root.bar.barForeground
        fontFamily: root.bar.fontFamily
      }

      Column {
        width: parent.width
        spacing: Style.spacing.xxs

        Text {
          text: root.stUnlocked && root.remainingGameSeconds > 0
            ? root.fmt(root.remainingGameSeconds) + " of game time left"
            : root.stUnlocked
              ? "Daily gaming allowance spent \u2014 games are blocked until tomorrow."
              : "Blocked while the gate is locked. Launches are intercepted by the launch guard."
          color: root.inWarningWindow ? Color.accent : root.bar.barForeground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
      }

      // ---- Reset countdown ----
      Rectangle {
        width: parent.width
        height: resetRow.implicitHeight + Style.space(10)
        radius: Style.space(6)
        color: Qt.rgba(root.bar.barForeground.r, root.bar.barForeground.g, root.bar.barForeground.b, 0.06)

        Row {
          id: resetRow
          anchors.left: parent.left
          anchors.leftMargin: Style.space(10)
          anchors.right: parent.right
          anchors.rightMargin: Style.space(10)
          anchors.top: parent.top
          anchors.topMargin: Style.space(5)
          spacing: Style.spacing.sm

          Text {
            text: "\uF017" // nf-fa-clock-o
            color: root.bar.barForeground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter
          }

          Text {
            text: root.resetCountdownText
            color: root.bar.barForeground
            opacity: 0.8
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            anchors.verticalCenter: parent.verticalCenter
          }
        }
      }
    }
  }

  // "Resets at 5:00 AM in 6h 23m"
  property int dawnTick: 0
  readonly property string resetCountdownText: {
    root.dawnTick // re-evaluated on timer tick
    var now = new Date()
    var next = new Date()
    next.setHours(root.resetHourLocal, 0, 0, 0)
    if (next <= now) next.setDate(next.getDate() + 1)
    var mins = Math.round((next - now) / 60000)
    var h = Math.floor(mins / 60)
    var m = mins % 60
    var pad = (root.resetHourLocal < 10 ? "0" : "") + root.resetHourLocal
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