# greenroom-win

Always-on **Claude Code Remote Control** sessions on Windows. Each instance starts
hidden at logon, stays supervised, and is revealed on demand with its full live
scrollback — not a resumed copy.

A green room is where the performer waits: always there, out of sight, called on
stage the moment you want them.

Several instances run side by side on one host, each with its own working
directory, its own directory grants, and its own name in the Remote Control UI.

> **Status: 0.1.0, unreleased.** The mechanism is proven single-instance on one
> host. The two-instance path is implemented and reasoned through but not yet
> verified end to end.

---

## Scope

Everything needed to stand an instance up lives here, and the installer does as much
of it as it can without being asked twice. It resolves the right `claude.exe`,
asserts the flag it depends on, checks the host settings that fail silently, seeds
trust, registers the task, starts the session, and verifies what it can observe.
`install.ps1 -Instance <name>` is the whole procedure.

**One thing is deliberately not here: memory.** What an instance should *know* is
personal and specific to whoever runs it — it does not belong in a repository that
anyone can clone, and it is conveyed separately.

Everything else — settings shape, host prerequisites, branch protection payload — is
in the tree.

---

## Install

```powershell
git clone <this repo>
cd greenroom-win
Get-ChildItem -Recurse | Unblock-File   # if it arrived as an archive
.\install.ps1 -Instance desktop-admin
```

With a directory grant:

```powershell
.\install.ps1 -Instance desktop-admin -AdditionalDirectories "$env:USERPROFILE"
```

| Switch | |
|---|---|
| `-Instance` | required; 1–32 chars, letters/digits/`.`/`-`/`_`, **no spaces** |
| `-WorkingDirectory` | default `%USERPROFILE%\<instance>` |
| `-AdditionalDirectories` | per-instance grants, **default none** |
| `-TriggerDelay` | logon delay, default `PT1M` |
| `-ClaudeExe` | override CLI detection |
| `-Elevated` | run the session as admin, **default off** — see below |
| `-NoTrustSeed`, `-NoStart` | skip those steps |

Idempotent — re-run any time. It will not kill a running session; new config
applies at the next restart.

### Elevated instances

`-Elevated` registers the task with `RunLevel Highest`, so the session runs with a
full admin token and no UAC prompt. **Requires an elevated installer** — registering
`RunLevel Highest` is refused from a normal shell.

It is off by default because it changes how the instance is operated, not as a
security posture:

- **`attach` and `detach` prompt for elevation.** UIPI stops a normal shell from
  showing or hiding an elevated window, and the calls fail by returning `false`
  rather than erroring — so `greenroom` re-launches itself through UAC and the
  elevated copy does the work. Pass `-NoElevate` to get a plain refusal instead.
- **`greenroom list` has a blind spot unless it is run elevated too.**
  `Win32_Process.CommandLine` reads as NULL across integrity levels, and that is
  how instances are named — so from an ordinary shell an elevated session shows as
  `(unreadable)` rather than by name. Run `list` elevated and the blind spot is
  gone; it belongs to the shell, not the session.
- **Nothing on screen distinguishes an elevated session** — no prompt, no badge.
  `greenroom list` is how you tell.

Elevation is inherited on a bare re-run, like grants and the working directory, and
says so each time. Revoke it explicitly:

```powershell
.\install.ps1 -Instance desktop-admin -Elevated:$false
```

Background: [docs/gotchas.md §6](docs/gotchas.md).

**Before you install**, read [docs/provisioning.md](docs/provisioning.md). Two
prerequisites fail *silently* if unmet — a CLI without `--remote-control`, and
`defaultShell: "bash"` on a host where `bash` does not resolve. The installer
checks both, but knowing why matters when something is off.

### Several instances

```powershell
.\install.ps1 -Instance desktop-admin -TriggerDelay PT1M
.\install.ps1 -Instance render-admin  -TriggerDelay PT2M -WorkingDirectory D:\render-admin
```

Stagger the delays so they do not race at logon.

---

## Use

```powershell
greenroom list
greenroom attach desktop-admin
greenroom detach desktop-admin
greenroom toggle desktop-admin
greenroom status desktop-admin
```

With exactly one instance running, the name can be omitted.

`install.ps1` places the command in `%USERPROFILE%\.local\bin`, which is normally
already on PATH, so no PATH edit and no profile change are needed. One command,
one shim per shell — the shape npm's `cmd-shim` and Scoop both use:

| | |
|---|---|
| `greenroom.ps1` | PowerShell resolves this natively from PATH, with full parameter and `ValidateSet` completion. One process |
| `greenroom.cmd` | four-line forwarder, no logic. `.PS1` is not in `PATHEXT`, so cmd.exe and the Run box cannot run the script directly and need it |

PowerShell prefers the `.ps1` over a same-named `.cmd`, so the extra shell hop is
paid only by cmd, where it is unavoidable.

```powershell
greenroom <Tab>            # attach detach status toggle list
greenroom attach -I<Tab>   # -Instance
```

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
| `%USERPROFILE%\.local\bin\greenroom.ps1` | the operator command |
| `%USERPROFILE%\.local\bin\greenroom.cmd` | generated cmd/Run-box shim |
| `%USERPROFILE%\.local\bin\greenroom\` | watchdog, launcher, vbs entry point — task-invoked |
| `%USERPROFILE%\.claude\greenroom\<instance>\config.json` | resolved paths and grants |
| `%USERPROFILE%\.claude\greenroom\<instance>\watchdog.log` | supervisor log |
| `%USERPROFILE%\.claude\greenroom\<instance>\launch.log` | per-session launch log |

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
install.ps1 / uninstall.ps1
bin/                            watchdog, launcher, attach/detach control
docs/gotchas.md                 why it is built this way
docs/provisioning.md            host prerequisites and why each is required
templates/settings.template.json
.github/rulesets/main.json      branch protection payload, applied from the tree
CHANGELOG.md
VERSION
```

The changelog records what a release contains. Iterations live in `git log` and the
pull request record — the repository is the diff.

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
2. `greenroom attach <instance>` → the session appears.
3. **`/rc active` in the footer.** If absent, `/login` inside the session.
4. `greenroom detach <instance>` → it disappears; `list` still shows it.
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
| `attach` reports AMBIGUOUS | The recorded window handle is missing or stale and no title matches either. `greenroom restart <instance>` re-records it |
| Wrong `claude.exe` picked | Pass `-ClaudeExe` |

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
.\uninstall.ps1 -Instance desktop-admin
.\uninstall.ps1 -Instance desktop-admin -KeepState -RemoveScripts
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
