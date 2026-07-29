# Why it is built this way

Six Windows behaviours defeated more obvious designs. Each one is the reason for a
specific piece of the architecture, and each cost real debugging time that is
invisible in the finished code.

If you are porting this concept to another platform, this file is the part worth
reading. The scripts are disposable; these are not.

---

## 1. Hiding a console from inside the process is too late

The OS creates the window **visible** at creation, and PowerShell needs roughly
370 ms to boot before any of your code runs — measured as a 367 ms flash of a
visible terminal at every logon.

Nothing you call from inside the process fixes this, because by the time you can
call anything the window has already been shown.

**Fix:** never let it be visible. `wscript.exe` is a GUI-subsystem binary, so it
allocates no console of its own, and `sh.Run(cmd, 0, False)` passes
`STARTF_USESHOWWINDOW` with `SW_HIDE` in `STARTUPINFO` at process creation. The
window is *born* hidden, and still exists for a later `ShowWindow`.

## 2. Windows 11 hands consoles off to Windows Terminal

Windows Terminal is a separate process parented to the console-handoff broker
(svchost), not to your launcher. Hiding your own pseudo-console does nothing —
Windows Terminal owns the visible window.

Worse, `PseudoConsoleWindow` reports `IsWindowVisible = true` at 0×0, so a naive
visibility check returns a **false pass**. Any real check must enumerate all
top-level windows and exclude zero-area ones.

## 3. Do not use conhost to dodge #2

conhost does no font fallback, and no console-registerable font — Consolas, Lucida
Console, Cascadia — contains the glyphs the Claude Code TUI draws: ✳ U+2733,
⏵ U+23F5, ⏺ U+23FA, ✦ U+2726. Verified by glyph-map inspection. Under conhost the
interface renders as boxes.

Windows Terminal honours `SW_HIDE` **and** does fallback, which is why it satisfies
both constraints at once and is a hard requirement rather than a preference.

## 4. Remote Control will not run from a home directory

The startup trust dialog never persists trust for a home directory, so Remote
Control never connects and the trust prompt repeats forever. Always use a project
subdirectory.

Trust is keyed on the **literal cwd string**, so `C:\x` and `C:/x` are separate
entries with independent trust values. Seeding one and starting with the other
re-prompts. Both forms must be seeded.

That literal-string keying is worth remembering beyond trust: anything else Claude
Code keys on a working directory keys on the exact string, so the same class of
mismatch — slash direction, drive-letter casing — reappears wherever a path is used
as an identifier.

**The concrete consequence: relocating an instance orphans its memory.** Claude
Code stores per-project state under `~/.claude/projects/<slug>/`, where the slug is
the literal working-directory string with every non-alphanumeric character replaced
by a dash. Change the working directory and the slug changes with it, so the
instance starts against an empty store — no memory, and nothing for `-c` to
continue.

```
~/desktop-admin       ->  C--Users-tyler-desktop-admin
~/src/desktop-admin   ->  C--Users-tyler-src-desktop-admin
```

**Carrying that state is the operator's job, not greenroom's.** Relocating takes a
deliberate `-WorkingDirectory` on an already-installed instance; it cannot happen by
accident. Provision it the same way you would any other move:

```powershell
Copy-Item -Path (Join-Path $old '*') -Destination $new -Recurse -Force
```

greenroom deliberately does not do this. `~/.claude/projects/` is Claude Code's data
model, not greenroom's — the contents change between versions, a target slug may
already hold state, and there is no obviously correct merge policy. greenroom writes
only what a session needs in order to start at all (trust, its own state) and warns
about everything else; see the marketplace check, which prints exactly what to remove
from `settings.json` rather than editing it. An instance with an empty memory store
starts fine. It is degraded, not broken, which puts it below that bar.

## 5. Windows Terminal hosts multiple windows in ONE process

On a host running two instances, both sessions walk up to the *same*
`WindowsTerminal.exe` PID, and that PID owns two `CASCADIA_HOSTING` windows.
Taking the first one is a coin flip on every attach and detach — this is the normal
two-instance case, not an edge case.

**Fix:** launch the session with `--name <instance>`. Claude Code renders the
window title as `<glyph> <name>`, so the title becomes something greenroom
controls and can match on.

Match the name **anchored at the end**. Two independent reasons:

- the leading glyph is an animated spinner and changes while the session works
  (observed as `✳` idle and `⠂` busy), so the front of the string is not stable;
- an unanchored substring lets `admin` match `admin-2`, which leaves the shorter
  instance permanently unresolvable — the same collision the watchdog's
  command-line pattern already guards against.

When it still does not resolve uniquely, print the candidates and refuse. Acting
on the wrong window hides or reveals the wrong session, which is worse than doing
nothing.

> **Earlier versions of this document claimed Claude Code titles the window with
> the working directory's leaf name. That was wrong.** Without `--name` the title
> is `Claude Code` until the conversation acquires an auto-generated title, and
> then it is *that* — it changes as the conversation changes and is never tied to
> the directory. Matching the leaf therefore found nothing against a live session,
> and the failure was masked because resolution short-circuits whenever the host
> process owns only one window.

## 6. An elevated session cannot be attached from an unelevated shell

Elevation is opt-in per instance (`install.ps1 -Elevated`), and it is off by
default — but the reason is operational, not a security posture. **Elevation breaks
attach and detach**, in the silent way, and that is a behaviour change the operator
has to know about rather than inherit.

Registering the task at all requires an elevated installer: `RunLevel Highest`
returns `Access is denied` from a normal shell. Measured, not assumed. The
installer therefore checks up front rather than at `Register-ScheduledTask`, which
is the last step — failing there would leave the instance half-built, with files
copied and trust seeded but nothing registered to run it.

User Interface Privilege Isolation stops a lower-integrity process from driving a
higher-integrity window. `ShowWindow` and `SetForegroundWindow` against an elevated
session's window from a normal shell do not raise, do not prompt, and do not warn:
they **return `false` and change nothing**. The script would print `attached` and
the window would stay hidden.

That is the worst possible shape for this project. Everything here is already
invisible because the window is hidden; a call that reports success while doing
nothing removes the last signal there was.

**Fix:** `install.ps1` records `elevated` in `config.json`, and `greenroom.ps1`
checks it *before* touching a window. When the instance is elevated and the shell
is not, it **re-launches itself through UAC** and lets the elevated copy do the
work, so `attach` still attaches.

A UAC prompt is fine here precisely because this is an interactive command someone
just typed. That is the mirror image of the logon path, where a UAC dialog behind a
hidden window would be an invisible hang — which is why the session takes its token
from the task trigger instead of prompting. Same mechanism, opposite conclusion,
decided by whether a human is already looking at the screen. `-NoElevate` restores
the plain refusal for scripted callers that must not block.

Window *enumeration* is unaffected: `EnumWindows`, `GetClassName` and
`GetWindowText` work across integrity levels. Only acting is blocked.

### Process discovery is affected, though, and that is the sharper edge

**`Win32_Process.CommandLine` is NULL for any process the querying shell lacks
query rights on.** Measured on the reference host against `ctfmon.exe`,
`TabTip.exe` and `Bitwarden.exe` — all three enumerate normally and all three
expose no command line to an ordinary shell.

An elevated `claude.exe` lands in exactly that class, which breaks the identifying
assumption everything here rests on: sessions are found by matching
`--remote-control <instance>` on the command line. With no command line there is no
token to match, so an elevated session is **visible as a process but
unidentifiable**, and a naive filter drops it — reporting "no session running" for
one that is running.

So discovery now collects those separately and reports them as `(opaque)` rather
than discarding them. It cannot say *which* instance an opaque process is; it can
say that something is there and that elevation is needed to name it. That is worth
more than a confident wrong answer.

The watchdog is unaffected — `RunLevel Highest` covers the whole `wscript` →
watchdog → `wt` → `claude` chain, so an elevated instance's supervisor is itself
elevated and always sees its own session.

Nothing on screen distinguishes an elevated session from a normal one — the token
comes from the task trigger, so there is no prompt and no badge. `greenroom list`
grew an `Elevated` column to make it legible.

---

## Two smaller ones

**Identify sessions by the instance name on the command line.** The name passed to
`--remote-control` does double duty: it labels the session in the Remote Control UI
*and* puts a unique token in the process command line. A supervisor matching bare
`--remote-control` adopts whichever session it sees first and then fights the other
supervisor over it. Anchor the match so `admin` cannot match `admin-2`.

**Never match `claude.exe` by process name.** A machine with Claude Desktop
installed has several distinct `claude.exe` binaries in unrelated locations.
`Stop-Process -Name claude` takes out all of them, including the session you are
working in. Filter by path or by the instance token.

---

## The general lesson

Every failure in this architecture is silent, because the window is hidden. A
misconfiguration that would be obvious in a visible terminal — a missing flag, a
modal dialog, a plugin load error — presents as "it just doesn't work" with no
output anywhere.

So the installer verifies rather than warns wherever it can, and refuses to
register anything until the prerequisites that fail silently are confirmed
present. Any port of this concept should hold the same line.
