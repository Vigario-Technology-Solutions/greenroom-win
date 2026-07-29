# Changelog

Notable changes between released versions. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- `greenroom restart <instance>`. The procedure it replaces did not restart
  anything: stopping the watchdog by process and then running `Start-ScheduledTask`
  leaves the session alive, and the new watchdog adopts it — the old session with a
  new supervisor. Measured on the reference host: an instance reinstalled with
  `-Elevated` kept running at Medium integrity through exactly that sequence. The
  verb stops watchdog → session → launcher in that order, re-verifying identity
  immediately before each kill, and everything is driven from the instance name,
  its task and `config.json` rather than from session discovery, which reads NULL
  across integrity levels. Refuses with exit 6 when run from inside the session it
  would kill.
- `install.ps1 -Elevated` runs an instance's session with a full admin token
  (task `RunLevel Highest`). **Off by default and never implied by anything else.**
  It is inherited on a bare re-run like other remembered parameters, announces
  itself each time because it is security-relevant, and is revoked with
  `-Elevated:$false`.

  Elevation breaks attach and detach, which is the reason it needs deliberate
  opt-in rather than being a convenience. UIPI stops an unelevated shell from
  driving an elevated window: measured on the reference host, `ShowWindow(SW_HIDE)`
  against an elevated window **returned `false` with `GetLastWin32Error` 5
  (`ERROR_ACCESS_DENIED`) and the window did not move** — no exception, no prompt. `greenroom.ps1` therefore reads the new
  `elevated` field from `config.json` and refuses *before* acting, exiting 4 with
  the elevated re-run command, rather than printing `attached` over a window that
  never moved. `greenroom list` still works unelevated — enumeration is permitted
  across integrity levels even though acting is not — and grew an `Elevated`
  column, since nothing on screen otherwise distinguishes such a session.

  Registering `RunLevel Highest` **requires an elevated installer** — measured, it
  returns `Access is denied` otherwise. That is checked up front rather than at
  `Register-ScheduledTask`, which is the last step; failing there would leave the
  instance half-built, with files copied and trust seeded but nothing registered
  to run them.

  `attach` and `detach` on an elevated instance **re-launch `greenroom.ps1` through
  UAC** rather than refusing, so the window still moves. A prompt is acceptable
  there because the command was typed interactively — the opposite of the logon
  path, where a UAC dialog behind a hidden window would be an invisible hang, which
  is why the session takes its token from the task trigger. `-NoElevate` restores a
  plain refusal for scripted callers.

  Session discovery no longer discards processes it cannot identify.
  **`Win32_Process.CommandLine` is NULL for any process the querying shell lacks
  query rights on** — measured against `ctfmon.exe`, `TabTip.exe` and
  `Bitwarden.exe`, which enumerate normally but expose no command line. An elevated
  `claude.exe` is therefore visible but unidentifiable, and the old filter dropped
  it, reporting "no session running" for a session that was running. Such processes
  are now reported as `(unreadable)`.

  That blind spot belongs to the **shell**, not the session: run `greenroom list`
  elevated and every instance resolves by name as usual. The notes say so, and are
  suppressed entirely when already elevated. The `(unreadable)` branch is gated on
  an elevated instance actually being configured — a host with Claude Desktop runs
  a dozen unrelated `claude.exe` (13 on the reference host), and calling one of
  those a probable greenroom session would be the confident wrong answer the branch
  exists to prevent. The watchdog is unaffected — `RunLevel Highest` covers the
  whole `wscript` → watchdog → `wt` → `claude` chain, so an elevated instance's
  supervisor is itself elevated and always sees its own session.

### Changed

- Window resolution no longer infers anything from window titles. The watchdog
  records the handle of the window it creates — the handle that is both new since
  a snapshot taken immediately before `wt.exe` launched and owned by the
  `WindowsTerminal.exe` in the session's own ancestry — and writes it to
  `<state>/session.json`. That record is the only source; there is deliberately no
  fallback. Titles belong to Claude Code, and a session sitting at a trust prompt
  or a `/login` screen has not applied `--name` yet, so it has no matching title at
  all — which is exactly when an operator needs to attach. A fallback would also
  hide a capture that quietly stopped working, right up until it resolved someone
  else's window. The record is validated on every use against one invariant: it
  must have been written for the session being acted on. Removed with the fallback:
  the `--name` title match, the single-window short-circuit that made the
  one-instance case right by luck, and the working-directory-leaf match.
- Sessions are still launched with `--name <instance>`, so the window title reads
  `<glyph> <instance>` rather than `Claude Code`. Nothing depends on it.

### Fixed

- Targeting an elevated instance by name from an unelevated shell reported
  `no greenroom session named '<instance>'` for a session that was running fine.
  Selection matched on the discovered instance name, but an elevated session's
  command line reads NULL across the integrity boundary, so it has no discoverable
  name and never matched — which also left the code that knows how to escalate
  sitting below an early exit, unreachable for exactly the instances it exists for.
  `config.json` is readable at any integrity level, so its elevated flag is now
  used to route instead.
- `install.ps1` destroyed an instance's scheduled task before replacing it. An
  unconditional `Unregister-ScheduledTask` preceded registration, which equals a
  replace only when registration then succeeds; on any failure a working task was
  already gone and the instance silently stopped starting at logon. Now replaced in
  one step with `Register-ScheduledTask -Force`, so a refusal changes nothing.
- Window operations were reported as successful without being checked.
  `ShowWindow` returns the window's *previous* visibility rather than success, and
  `GetLastError` is stale on success, so neither can report failure. Measured on
  the reference host: `ShowWindow(SW_HIDE)` against an elevated window returned
  `false` with `GetLastWin32Error 5` and the window did not move — no exception, no
  prompt. Attach and detach now confirm by observing `IsWindowVisible` before and
  after.
- Re-running `install.ps1` without `-WorkingDirectory` silently relocated an
  installed instance to `~/<instance>`, creating a new working directory, seeding
  trust for it and restarting the session there — abandoning the real directory
  along with its project store, memory and transcripts. `-TriggerDelay` reset the
  same way, un-staggering a multi-instance host. Both are now inherited from the
  previous install when omitted, and `triggerDelay` is recorded in `config.json`
  so it can be. `-ClaudeExe` is inherited too, but only when it was explicitly
  chosen — an auto-detected path is re-resolved rather than pinned, so the WinGet
  shim keeps surviving upgrades. Pass `-ClaudeExe ''` to revoke a choice, mirroring
  `-AdditionalDirectories @()`. An explicit or inherited `-ClaudeExe` that does not
  exist is now refused rather than silently dropped — auto-detection used to take
  over and be recorded as though it were the deliberate choice. A `config.json` that exists but cannot be parsed is
  now a hard error rather than being treated as absent — silently falling back to
  defaults there would relocate the instance through the same route this fixes.

- The launcher did not stop when its working directory was unreachable. Because
  `$ErrorActionPreference` is `Continue`, both the directory creation and the
  `Set-Location` could fail while execution carried on, and Claude Code then
  launched in the inherited directory — `$env:USERPROFILE`, the home directory,
  which is the one place Remote Control will not connect from. Silently, inside a
  hidden window. Reaching it needs only a working directory on a network share
  that is not mapped yet when the logon task fires. Both steps are now checked and
  fatal, and the launcher confirms it actually landed in the target directory.

- A session whose hosting shell was killed rather than exited left its Windows
  Terminal window behind, frozen at its last title. Because that title carries the
  instance name, the replacement session produced a second window with the same
  name and window resolution refused to choose between them — attach broke
  permanently. The watchdog now closes any window bearing its instance name
  immediately before relaunching, at which point the session is already confirmed
  dead. The ambiguity message also distinguishes "no window matched" from
  "several matched, so one is stale", and no longer suggests `Start-ScheduledTask`
  as a restart.

- Nothing stopped a second watchdog supervising the same instance. Because
  `Stop-ScheduledTask` is a no-op against this architecture, a plain
  `Start-ScheduledTask` added a supervisor rather than replacing one, and two
  watchdogs relaunch the session together on the same poll — producing two windows
  with the same name, which resolution refuses to choose between. The watchdog now
  claims a per-instance named mutex at startup and exits if another holds it. The
  claim is released if the holder is killed, so a crashed watchdog cannot lock the
  instance out.

- Each watchdog restart began a new conversation rather than continuing the
  previous one, so every restart appeared as its own entry in the Claude Desktop
  session list. `greenroom-launch.ps1` now passes `-c`, guarded on whether a
  transcript already exists for the project directory — `-c` exits 1 under
  `--remote-control` when there is nothing to continue.
- Re-running `install.ps1` without `-AdditionalDirectories` silently revoked the
  instance's directory grants, clearing them from `config.json`, the project
  settings file and the launch line. Omitting the parameter now inherits the
  previous install's grants; `-AdditionalDirectories @()` still clears them.
- The trust re-seed path restarted the session with `Stop-ScheduledTask` followed
  by `Start-ScheduledTask`. `Stop-ScheduledTask` is a no-op against this
  architecture, so that sequence added a second watchdog instead of replacing the
  first. The supervisor is now stopped by process, the session with it, and the
  session PID is re-resolved afterwards rather than reporting the dead one.
