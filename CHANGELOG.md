# Changelog

All notable changes to this project will be documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

## [1.0.1] - 2026-09-19

### Added
- `omarchy-focus-gate-study toggle` — start/stop in one command, ideal for keybindings
- `CHANGELOG.md`

### Changed
- Bar widget panel: progress bar replaced with two side-by-side arc progress rings (Study / Gaming)
- Gaming arc shows a dimmed lock glyph while the gate is still locked
- Study arc center shows "live" / "paused" indicator for session state at a glance
- `ensureProc` now calls the idempotent install hook instead of inlining duplicated config JSON
- `fg_fmt_time` consolidated into `bin/lib/common.sh` (was duplicated across 3 scripts)
- `fg_config()` simplified — removed unnecessary nested `jq -n` subshells on every tick
- `fg_descendants()` now caps recursion at depth 8 to guard against pathological trees

### Fixed
- `fg_duration_hhmm` in `omarchy-focus-gate-study` renamed to canonical `fg_fmt_time`
- `inWarningWindow` QML property now has a comment clarifying it fires on time alone (approximation)
- Scratch development files (`scratch.qml`, `scratch2.qml`) removed from repository

---

## [1.0.0] - 2026-09-18

### Added
- Initial release
- Study-gated gaming with configurable study/gaming quotas and reset hour
- Bar widget with live progress display, pulsing warning animation, and control panel
- Background service (Quickshell) drives enforcement ticks every 30s
- `omarchy-focus-gate-study start|stop|status` CLI commands
- `omarchy-focus-gate-daemon` single-tick enforcement (called by the service)
- `omarchy-focus-gate-launch-guard <cmd>` — pre-launch blocking with exec passthrough
- `omarchy-focus-gate-install` / `-uninstall` idempotent lifecycle hooks
- Suspend-safe elapsed-time accounting (5-minute cap per daemon tick)
- Desktop notifications for unlock, gate block, and 10-minute pre-cutoff warning
- 5 AM local-time day rollover (configurable via `reset_hour_local`)
- Atomic state writes via `flock` + temp-file rename
- Corrupt state recovery (auto-backup rather than silent clobber)
