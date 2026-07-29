# greenroom-win task runner.
#
# `just check` is the whole gate: CI runs exactly that and nothing else, so a
# green local run and a green pull request mean the same thing. Anything CI
# enforces that is not reachable from here would make the pull request the only
# place a failure can be found, which is the trap this file exists to avoid.
#
# Recipes run under pwsh on every platform, including the Linux runner, so there
# is one dialect rather than two. The gate's logic lives in ci/check.ps1 -- just's
# shebang recipes require cygpath on Windows, and Windows is the whole audience.

set shell := ["pwsh", "-NoLogo", "-NoProfile", "-Command"]

# Recipe parameters reach recipes as environment variables. `title` relies on it:
# a subject passed through shell quoting would break on an apostrophe, because
# just quotes for POSIX (`'\''`) and pwsh escapes by doubling instead.
set export := true

# Show the recipes.
default:
    @just --list --unsorted

# Everything CI enforces: parse, static analysis, JSON validity.
check:
    @pwsh -NoProfile -File ./ci/check.ps1

# Parse every .ps1 and .psd1.
parse:
    @pwsh -NoProfile -File ./ci/check.ps1 -Phase parse

# PSScriptAnalyzer, using the exclusions in PSScriptAnalyzerSettings.psd1.
analyze:
    @pwsh -NoProfile -File ./ci/check.ps1 -Phase analyze

# Validate every JSON file, including the branch-protection payload.
json:
    @pwsh -NoProfile -File ./ci/check.ps1 -Phase json

# Lint a PR title the way CI will: `just title "feat: add a thing"`.
title subject:
    @Write-Output $env:subject | npx --no-install commitlint --verbose

# Preview the changelog the unreleased commits would produce. Writes nothing.
changelog:
    @git-cliff --unreleased

# Regenerate CHANGELOG.md from history. Belongs in a version-bump PR, gated as usual.
changelog-write:
    @git-cliff --output CHANGELOG.md
