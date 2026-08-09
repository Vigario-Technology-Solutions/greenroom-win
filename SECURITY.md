# Security policy

## Reporting a vulnerability

**Report privately, through GitHub:**
[Report a vulnerability](https://github.com/Vigario-Technology-Solutions/greenroom-win/security/advisories/new).

Private vulnerability reporting is enabled on this repository, so the report stays
between you and the maintainer until there is a fix to publish. Please do not open a
public issue for something exploitable.

There is no bounty and no SLA to promise. This is a small project with one maintainer;
what you will get is an acknowledgement and an honest answer about whether and when it
will be fixed.

## What versions are supported

Only the latest release on the
[PowerShell Gallery](https://www.powershellgallery.com/packages/Greenroom) is supported.
While the major version is zero there are no backports — a fix ships in the next release,
and older versions are not patched.

## What is in scope

greenroom installs a scheduled task, resolves and launches `claude.exe`, writes per-instance
state under `~/.claude/greenroom/`, and seeds workspace trust in `~/.claude.json`. Anything
that lets a lower-privileged user influence what an instance runs, what it runs *as*, or
which directories it can reach is in scope. Elevated instances are worth particular
attention.

Things worth knowing before reporting:

- **`-Elevated` runs the session as administrator.** That is the documented purpose of the
  switch, not a vulnerability in itself.
- **Trust seeding writes to `~/.claude.json`.** Also deliberate, and documented.
- **greenroom does not handle credentials.** It launches a CLI that manages its own
  authentication; there are no secrets in the module or its state files.

## What is out of scope

Vulnerabilities in Claude Code, Windows Terminal, or Windows itself. Report those to their
respective vendors — this project is not affiliated with or endorsed by Anthropic.
