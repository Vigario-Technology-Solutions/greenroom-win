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
