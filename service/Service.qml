import QtQuick
import Quickshell
import Quickshell.Io

Item {
  id: root

  // Paths
  readonly property string home: Quickshell.env("HOME")
  readonly property string daemonScriptPath: home + "/.config/omarchy/plugins/omarchy-focus-gate/bin/omarchy-focus-gate-daemon"

  // The timer acts like the systemd timer, ticking every 30s
  Timer {
    interval: 30000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: {
      if (!daemonProc.running) {
        daemonProc.command = [root.daemonScriptPath]
        daemonProc.running = true
      }
    }
  }

  Process {
    id: daemonProc
    environment: ({ HOME: root.home })
  }
}
