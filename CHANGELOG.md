# Changelog

Notable changes between released versions. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

### Fixed

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
