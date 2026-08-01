# greenroom-win

Always-on **Claude Code Remote Control** sessions on Windows. Each instance starts
hidden at logon, stays supervised, and is revealed on demand with its full live
scrollback — not a resumed copy.

A green room is where the performer waits: always there, out of sight, called on
stage the moment you want them.

Several instances run side by side on one host, each with its own working
directory, its own directory grants, and its own name in the Remote Control UI.

> **Status: in development.** Every `0.x` release is initial development in the
> sense semver means it — anything may change, and the surface is not stable — so
> a command that exists today may not exist, or may not behave the same way, in
> the next minor.
>
> That is enforced rather than promised: while the major is zero a breaking change
> bumps the minor, so reaching `1.0.0` cannot happen by accident. It takes someone
> deciding the surface is worth keeping.

---

## Scope

Everything needed to stand an instance up lives here, and the installer does as much
of it as it can without being asked twice. It resolves the right `claude.exe`,
asserts the flag it depends on, checks the host settings that fail silently, seeds
trust, registers the task, starts the session, and verifies what it can observe.
`Install-GreenroomInstance -Name <name>` is the whole procedure.

**One thing is deliberately not here: memory.** What an instance should *know* is
personal and specific to whoever runs it — it does not belong in a repository that
anyone can clone, and it is conveyed separately.

Everything else — settings shape, host prerequisites, branch protection payload — is
in the tree.

---

## Install

greenroom is a PowerShell module. Installing the **module** and provisioning an
**instance** are two different things, in that order.

It needs **PowerShell 7.4 or newer**. The manifest declares that floor and
`CompatiblePSEditions = 'Core'`, so Windows PowerShell 5.1 cannot load it — and says so
only if it finds the file at all; see [Troubleshooting](#troubleshooting).

```powershell
git clone <this repo>
cd greenroom-win
Get-ChildItem -Recurse | Unblock-File   # if it arrived as an archive
```

Then install the module. From a local folder as a repository, which needs no gallery
and no network:

```powershell
Register-PSResourceRepository -Name greenroom-local -Uri (Resolve-Path .) -Trusted
Publish-PSResource -Path .\Greenroom -Repository greenroom-local
Install-PSResource -Name Greenroom -Repository greenroom-local -Scope CurrentUser
```

Or just copy it onto the module path, which is all the above amounts to:

```powershell
$v = (Import-PowerShellDataFile .\Greenroom\Greenroom.psd1).ModuleVersion
Copy-Item .\Greenroom "$HOME\Documents\PowerShell\Modules\Greenroom\$v" -Recurse
```

Either way it then resolves by name, including inside the logon task:

```powershell
Import-Module Greenroom
Install-GreenroomInstance -Name desktop-admin
```

With a directory grant:

```powershell
Install-GreenroomInstance -Name desktop-admin -AdditionalDirectories "$env:USERPROFILE"
```

| Parameter | |
|---|---|
| `-Name` | required; 1–32 chars, letters/digits/`.`/`-`/`_`, **no spaces** |
| `-WorkingDirectory` | inherited on a re-run; `%USERPROFILE%\<name>` on a first install |
| `-AdditionalDirectories` | per-instance grants, **default none** |
| `-TriggerDelay` | logon delay, default `PT1M` |
| `-ClaudeExe` | override CLI detection |
| `-Elevated` | run the session as admin, **default off** — see below |
| `-NoTrustSeed`, `-NoStart` | skip those steps |
| `-WhatIf`, `-Confirm` | as with every state-changing command here |

Idempotent — re-run any time. It will not kill a running session; new config applies
at the next restart.

**Omitting a parameter INHERITS it** from the previous install rather than falling
back to a default. That is load-bearing, not a nicety: a bare re-run that reset the
working directory used to relocate the instance and abandon its project store.
Clearing is explicit — `-AdditionalDirectories @()`, `-ClaudeExe ''`.

### Elevated instances

`-Elevated` registers the task with `RunLevel Highest`, so the session runs with a
full admin token and no UAC prompt. **Requires an elevated installer** — registering
`RunLevel Highest` is refused from a normal shell.

It is off by default because it changes how the instance is operated, not as a
security posture:

- **Show and Hide prompt for elevation.** UIPI stops a normal shell from showing or
  hiding an elevated window, and the calls fail by returning `false` rather than
  erroring — so the command re-launches itself through UAC and the elevated copy does
  the work. Pass `-NoElevate` to get a plain refusal instead.
- **`Get-GreenroomInstance` has a blind spot unless it is run elevated too.**
  `Win32_Process.CommandLine` reads as NULL across integrity levels, and that is
  how instances are named — so from an ordinary shell an elevated session shows as
  `Opaque` with no name. Run it elevated and the blind spot is gone; it belongs to
  the shell, not the session.
- **Nothing on screen distinguishes an elevated session** — no prompt, no badge.
  `Get-GreenroomInstance` is how you tell.

Elevation is inherited on a bare re-run, like grants and the working directory, and
says so each time. Revoke it explicitly:

```powershell
Install-GreenroomInstance -Name desktop-admin -Elevated:$false
```

Background: [docs/gotchas.md §6](docs/gotchas.md).

**Before you install**, read [docs/provisioning.md](docs/provisioning.md). Two
prerequisites fail *silently* if unmet — a CLI without `--remote-control`, and
`defaultShell: "bash"` on a host where `bash` does not resolve. The installer
checks both, but knowing why matters when something is off.

### Several instances

```powershell
Install-GreenroomInstance -Name desktop-admin -TriggerDelay PT1M
Install-GreenroomInstance -Name render-admin  -TriggerDelay PT2M -WorkingDirectory D:\render-admin
```

Stagger the delays so they do not race at logon.

---

## Use

```powershell
Get-GreenroomInstance                             # what is running
Show-GreenroomSession    desktop-admin            # reveal it
Hide-GreenroomSession    desktop-admin            # put it away, session keeps running
Switch-GreenroomSession  desktop-admin            # whichever it is not
Restart-GreenroomSession desktop-admin
```

With exactly one instance running, the name can be omitted.

`Show-` and `Hide-` are approved verbs and they are also literally what happens: the
window exists the whole time and these call `ShowWindow` on it. "Attach" was always a
euphemism for a visibility toggle.

**Everything emits objects**, so the listing feeds the actions:

```powershell
Get-GreenroomInstance | Where-Object { -not $_.Visible } | Show-GreenroomSession
Get-GreenroomInstance | Where-Object Elevated
Get-GreenroomInstance | Where-Object { $null -eq $_.Window } | Restart-GreenroomSession
```

Every state-changing command supports `-WhatIf` and `-Confirm`. `-Verbose` explains
what a command decided and why, including the specific reason a window could not be
resolved.

No PATH entry, no shim, no profile change: the module resolves by name once it is on
the module path.

---

## How it works

```
Task Scheduler  (at logon, +delay, Interactive, no elevation)
  └── wscript.exe greenroom-watchdog.vbs <instance>       ← born hidden, SW_HIDE
        └── pwsh greenroom-watchdog.ps1 -Instance <name>   ← supervisor, 1s poll
              └── wt.exe -w new  (hidden)
                    └── pwsh greenroom-launch.ps1 -Instance <name>
                          └── claude.exe --remote-control <name> [--add-dir ...]
```

| Path | |
|---|---|
| `<module path>\Greenroom\` | the module — the commands you type |
| `<module path>\Greenroom\Assets\` | watchdog, launcher, vbs entry point — task-invoked, never by you |
| `%USERPROFILE%\.claude\greenroom\<instance>\config.json` | resolved paths and grants |
| `%USERPROFILE%\.claude\greenroom\<instance>\session.json` | the recorded window handle |
| `%USERPROFILE%\.claude\greenroom\<instance>\watchdog.log` | supervisor log |
| `%USERPROFILE%\.claude\greenroom\<instance>\launch.log` | per-session launch log |

The `.vbs` finds the watchdog next to itself and the watchdog finds the launcher next
to itself, so the whole chain relocates with the module and the registered task points
into wherever it was installed.

The watchdog polls once a second and restarts a dead session. Crash-loop guard:
more than 5 restarts in 5 minutes triggers a 2-minute backoff. Measured recovery
after a kill on the reference host was ~1.4 s.

**[docs/gotchas.md](docs/gotchas.md) is the part worth reading** — five Windows
behaviours that defeated more obvious designs, and the reason the architecture
looks like this. If you are porting the concept elsewhere, start there; the scripts
are disposable, that reasoning is not.

---

## Repository layout

```
Greenroom/
  Greenroom.psd1                manifest — ModuleVersion is the only version slot
  Greenroom.psm1                loads Private then Public, exports only Public
  Greenroom.format.ps1xml       the table view for Greenroom.Instance
  Public/                       one file per exported command
  Private/                      helpers, unreachable from outside the module
  Assets/                       watchdog, launcher, vbs entry point, settings template
tests/                          Pester
docs/gotchas.md                 why it is built this way
docs/provisioning.md            host prerequisites and why each is required
.github/rulesets/main.json      branch protection payload, applied from the tree
CHANGELOG.md
```

`Public/` versus `Private/` is the API boundary: `Get-Command -Module Greenroom` shows
exactly the supported surface and nothing else.

The changelog records what a release contains. Iterations live in `git log` and the
pull request record — the repository is the diff.

### Tests

```powershell
Invoke-Pester ./tests
Invoke-ScriptAnalyzer -Path ./Greenroom -Recurse -Severity Error,Warning
```

The analyzer runs with **no settings file and no exclusions**. Where a rule genuinely
does not apply — the `lParam` Win32's `EnumWindowsProc` delegate requires and the
callback ignores — it is suppressed at that function with the reason, so a real finding
elsewhere still fails.

---

## Contributing

**`main` rejects direct pushes for everyone, including admins.** Branch, commit,
push, open a PR.

The **PR title becomes the commit message on `main`**, so write it as a conventional
commit. The PR body is a free-form record and is never linted.

---

## Verifying

Do not trust a green line from the installer for anything it cannot observe.

1. **No window should have appeared.** Only you can confirm this.
2. `Show-GreenroomSession <instance>` → the session appears.
3. **`/rc active` in the footer.** If absent, `/login` inside the session.
4. `Hide-GreenroomSession <instance>` → it disappears; `Get-GreenroomInstance` still shows it.
5. **Cold reboot.** The only test that proves the logon trigger fires and that the
   delay is long enough for whatever the session depends on. Nothing substitutes
   for it. After logging back in, wait ~90 s and check `watchdog.log`.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Session starts then dies, repeatedly, silently | Almost always a CLI without `--remote-control`. Check `claude --help` |
| Session never starts | `watchdog.log` — usually the `claude.exe` path or a missing login |
| A terminal flashes at logon | Something launched the session directly instead of via the `.vbs` |
| TUI renders as boxes | Launched under conhost. Check `wt` in `config.json` |
| Trust dialog on first start | The seed was dropped by another Claude process. Installer re-seeds; if it reports RE-SEED FAILED, close other sessions and re-run |
| `/rc active` missing | Not logged in, or logged in with a `setup-token` |
| `cannot resolve the window` | The instance has no usable window record — most often a session started before the record existed. `Restart-GreenroomSession <instance>` creates one |
| Wrong `claude.exe` picked | Pass `-ClaudeExe` |
| `Import-Module Greenroom` → "no valid module file was found" | You are in Windows PowerShell 5.1. It searches `Documents\WindowsPowerShell\Modules`; the module installs to `Documents\PowerShell\Modules`. It reads as *missing* rather than *incompatible*. Run `pwsh` |
| `requires a minimum Windows PowerShell version of '7.4'` | The accurate version of the row above — 5.1 found the manifest by path. Same fix: run `pwsh` |

Restart one instance:

```powershell
Stop-ScheduledTask  -TaskName greenroom-<instance>
Start-ScheduledTask -TaskName greenroom-<instance>
```

**Never `Stop-Process -Name claude`.** A host with Claude Desktop installed has
several distinct `claude.exe` binaries; matching by name kills all of them,
including the session you are working in. Filter by path or by the instance token.

---

## Uninstall

```powershell
Uninstall-GreenroomInstance -Name desktop-admin
Uninstall-GreenroomInstance -Name desktop-admin -KeepState
```

The working directory is never touched. Trust entries in `~/.claude.json` are left
in place.

---

## License

**GNU Affero General Public License v3.0 or later** — see [LICENSE](LICENSE).

Copyright © 2026 Tyler Vigario.

Use it, modify it, break it, run it in production, charge for installing and
supporting it. What you may not do is take it closed. Modifications you distribute
come back under the same terms, so the next person who wants to tinker with it can.

That is the whole intent: earning a living with this is fine, enclosing it is not.

Third-party marks are the property of their owners. This project is not affiliated
with or endorsed by Anthropic.
