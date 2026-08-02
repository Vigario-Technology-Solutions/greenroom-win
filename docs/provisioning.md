# Host provisioning

What a host needs before an instance will run, and why each item is a requirement
rather than a preference.

`Install-GreenroomInstance` checks everything on this page and refuses or warns rather than
letting you build a setup that fails silently. Every failure in this architecture is
invisible, because the window is hidden, so a check that runs at install time is
worth far more than a note telling you to look.

`Greenroom/Assets/settings.template.json` carries the shape of a working
`%USERPROFILE%\.claude\settings.json`, with the reasoning for each key inline. Fill
in your own values — the template ships none.

---

## Prerequisites

| | |
|---|---|
| Windows | 10 or 11 |
| PowerShell | **5.1+** — in-box Windows PowerShell suffices; pwsh 7 preferred, see below |
| Windows Terminal | **required** — see [gotchas](gotchas.md#2-do-not-use-conhost-to-dodge-1) |
| Claude Code CLI | must support `--remote-control [name]` |
| claude.ai login | full `/login`, not `claude setup-token` |

### PowerShell version

Greenroom runs on **Windows PowerShell 5.1 or PowerShell 7**. The manifest declares
`PowerShellVersion = '5.1'` and `CompatiblePSEditions = 'Core', 'Desktop'`, and the module
imports and passes its full test suite on both. 5.1 is the floor because it **ships in-box
on every Windows host** — nothing to install — and running on a stock machine is the whole
point of the project.

**pwsh 7 is preferred, not required.** The installer and the logon `.vbs` resolve a shell
the same way: pwsh 7 first — WinGet's version-independent alias, then the install path —
and Windows PowerShell 5.1 only when no pwsh 7 is found. On a host with pwsh 7 nothing
changes; on one without, the in-box shell carries the session.

Prefer pwsh 7 where you can. It is the actively developed edition; 5.1 is frozen and takes
security fixes but no features, and any pwsh 7 you do run should itself be a
[supported release](https://learn.microsoft.com/powershell/scripting/install/powershell-support-lifecycle).
Greenroom is written to run identically on both, and the one place the editions genuinely
diverge — parsing `~/.claude.json`, which can hold keys differing only in drive-letter
case — is isolated behind two helpers (`JavaScriptSerializer` on 5.1, `System.Text.Json`
and `-AsHashtable` on 7) that the tests exercise under each edition.

PowerShell 7 is **not part of Windows** and never arrives through Windows Update. Windows
ships Windows PowerShell 5.1, a separate product on the Windows lifecycle. `pwsh` is always
an explicit install, so "the host is fully updated" says nothing about whether it has
PowerShell 7 at all — which is exactly why the floor is the shell that is always present.

### CLI version

`--remote-control [name]` is absent in 2.1.92 and present from 2.1.218. Launching
without it kills the session instantly inside a hidden window; the watchdog restarts
it, the crash-loop guard trips, and nothing surfaces anywhere. This is the worst
failure mode in the design, so `Install-GreenroomInstance` asserts the flag before registering
anything.

Note `--remote-control-session-name-prefix` is a **different** flag that exists on
builds lacking the one you need. A bare substring check passes on those.

### Which `claude.exe`

A host with Claude Desktop installed has several. Resolution order is WinGet Links
→ PATH → `~\.local\bin`. The WinGet Links shim is preferred because it is keyed on
package ID rather than version, so the recorded path survives upgrades — and it is
deliberately not resolved through its symlink, which would bake in a versioned path
that breaks on the next update.

Excluded as never-valid targets: `Program Files\WindowsApps` (Store Desktop),
`AnthropicClaude` (standalone Desktop), and `AppData\Roaming\Claude\claude-code`
(Desktop's private bundled CLI).

Override with `-ClaudeExe` if your layout is unusual.

### Login

Remote Control requires a full claude.ai login. `claude setup-token` credentials are
rejected, and the rejection is silent in a hidden window. Run `claude` once
interactively, `/login`, then confirm `/rc active` appears in the footer after the
supervised session starts.

---

## If `defaultShell` is `bash`

This is the one host setting greenroom inspects, and only because getting it wrong
breaks the supervised session invisibly — not because greenroom has an opinion about
your configuration.

Git for Windows puts `<git-root>\cmd` and `<git-root>\mingw64\bin` on PATH.
**Neither contains `bash.exe`.** So a stock Git install satisfies `git` and fails
`bash`, and if `defaultShell` is `bash`, every Bash tool call then fails silently.

Add **`<git-root>\bin`** to your user PATH — it contains exactly three files:
`bash.exe`, `git.exe`, `sh.exe`.

Do **not** add `<git-root>\usr\bin`. It also contains bash, which makes it look
correct, but it is several hundred files that shadow Windows `echo`, `expand`,
`find`, `link`, `sort`, `tee`, and `timeout`.

### Verifying, and the false negative

A shell spawned from an existing process inherits a **stale environment block**, so
checking from the terminal you just made the change in — or from anything an agent
spawns — reports failure even when the registry is correct.

Verify from a terminal opened fresh from Explorer or the Start menu:

```powershell
Get-Command bash, sh, git | Select-Object Name, Source
```

`Install-GreenroomInstance` distinguishes the two cases: not-on-PATH-anywhere versus
on-PATH-in-the-registry-but-not-in-this-process. They need different responses, and
they are otherwise indistinguishable.

If a session is already running when you change PATH, restart its task — it still
holds the old block.

---

## Directory access

Each instance launches with access to its working directory and nothing else.
Anything more is granted at install time and passed as `--add-dir` on the launch
line, so the grant is scoped to that instance and visible in the process list:

```powershell
Install-GreenroomInstance -Name desktop-admin -AdditionalDirectories "$env:USERPROFILE"

Install-GreenroomInstance -Name render-admin -WorkingDirectory D:\render-admin `
              -AdditionalDirectories D:\models
```

No `-AdditionalDirectories` means no extra access. The installer refuses to grant a
path that does not exist. Widening later is a re-run with the new grant, effective at
the next session restart.

This governs only what the supervisor launches. Anything granted host-wide in your
own Claude configuration applies to every session on the machine regardless, which is
outside greenroom's control and worth knowing when reasoning about an instance's real
reach.

---

## Trust

Remote Control will not connect from an untrusted directory, and the trust dialog is
modal — in a hidden window that means the session hangs with no visible reason.

`Install-GreenroomInstance` seeds `hasTrustDialogAccepted` for the working directory in
`~/.claude.json` before first launch, in **both** slash forms, then re-reads the file
after launch to confirm the seed survived. It does not assume: on any host with
Claude Desktop there are always other `claude.exe` processes, and any of them can
rewrite that file in between. If the seed is gone it re-seeds and restarts once, and
says so plainly if that fails.

It refuses to write `~/.claude.json` at all if the result would not parse as JSON.

**This is the only file outside greenroom's own directories that installing writes.**
`-NoTrustSeed` declines it entirely — run `claude` once in the working directory and
accept the dialog yourself, and greenroom then touches nothing but
`~\.local\bin\greenroom` and `~\.claude\greenroom\<instance>`.
