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
| PowerShell | **7.4+** — the manifest declares `PowerShellVersion = '7.4'`, so 7.0–7.3 refuse to import |
| Windows Terminal | **required** — see [gotchas](gotchas.md#3-do-not-use-conhost-to-dodge-2) |
| Claude Code CLI | must support `--remote-control [name]` |
| claude.ai login | full `/login`, not `claude setup-token` |

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
