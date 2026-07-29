# Why it is built this way

Five Windows behaviours defeated more obvious designs. Each one is the reason for a
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

## 5. Windows Terminal hosts multiple windows in ONE process

On a host running two instances, both sessions walk up to the *same*
`WindowsTerminal.exe` PID, and that PID owns two `CASCADIA_HOSTING` windows.
Taking the first one is a coin flip on every attach and detach — this is the normal
two-instance case, not an edge case.

**Fix:** Claude Code titles the window with the working directory's leaf name, plus
an animated spinner glyph — so match on substring, never equality. When that still
does not resolve uniquely, print the candidates and refuse. Acting on the wrong
window hides or reveals the wrong session, which is worse than doing nothing.

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
