# Changelog

Notable changes between released versions. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Added

- `install.ps1 -Elevated` runs an instance's session with a full admin token
  (task `RunLevel Highest`). **Off by default and never implied by anything else.**
  It is inherited on a bare re-run like other remembered parameters, announces
  itself each time because it is security-relevant, and is revoked with
  `-Elevated:$false`.

  Elevation breaks attach and detach, which is the reason it needs deliberate
  opt-in rather than being a convenience. UIPI stops an unelevated shell from
  driving an elevated window, and `ShowWindow`/`SetForegroundWindow` fail by
  returning `false` — no error, no prompt. `greenroom.ps1` therefore reads the new
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

  One behaviour is documented as **unverified** rather than assumed: whether
  `Win32_Process.CommandLine` is readable for a higher-integrity process of the
  same user. If it is not, `greenroom list` under-reports elevated sessions from an
  ordinary shell, so a hint is printed whenever an elevated instance is installed
  and discovery finds nothing. The watchdog is unaffected — `RunLevel Highest`
  applies to the whole `wscript` → watchdog → `wt` → `claude` chain, so an elevated
  instance's supervisor is itself elevated and always sees its own session.

### Changed

- Sessions are launched with `--name <instance>`, which makes Claude Code render
  the window title as `<glyph> <instance>`. Window resolution matches that name
  anchored at the end of the title — the leading glyph is an animated spinner, and
  an unanchored match would let `admin` match `admin-2`.

### Fixed

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
