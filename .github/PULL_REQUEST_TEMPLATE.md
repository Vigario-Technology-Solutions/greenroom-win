<!--
The PR TITLE is the entire commit message on main.

Merges are squash-only and the body is discarded, so the title is the whole permanent
record — and CI lints it with `cog verify` before the merge button exists. Conventional
Commits: `feat`, `fix`, or any other type as a label; `!` for a breaking change.

Anything you write below is for the reviewer and is not kept.
-->

## What this changes

<!-- One or two sentences. The problem, not the diff — the diff is right there. -->

## Why

<!-- What made the previous behaviour wrong. If it was measured, say what was measured. -->

## How it was verified

<!-- Not "tests pass" — CI reports that. What did you actually run, and on what?
     If it touches the launcher, the watchdog or anything under Assets/, say whether you
     exercised it against a live instance, since the gate cannot. -->

- [ ] `pwsh ./ci/check.ps1` is green locally
- [ ] Tests are hermetic — no dependency on this host's printers, paths, module versions or
      installed tools
- [ ] If it changes behaviour on both PowerShell editions, it was run on both
      (`test-core` and `test-desktop` cover this in CI)

## Notes

<!-- Anything a future reader will want and cannot get from the diff: a trap avoided, a
     dead end not worth revisiting, a measurement. docs/gotchas.md is for what still bites;
     rationale belongs in the commit. -->
