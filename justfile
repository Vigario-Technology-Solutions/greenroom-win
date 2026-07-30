# greenroom-win task runner.
#
# `just check` is the whole gate: CI runs exactly that and nothing else, so a green
# local run and a green pull request mean the same thing. Anything CI enforced that was
# not reachable from here would make the pull request the only place a failure can be
# found.
#
# Recipes run under pwsh on every platform so there is one dialect rather than two, and
# the gate's logic lives in ci/check.ps1 -- just's shebang recipes require cygpath on
# Windows, which is this repository's whole audience.
#
# The gate needs NOTHING but pwsh. That is deliberate: it has to stay runnable on a host
# with no network and no extra tooling, which is the situation you are in precisely when
# something is already broken.

set shell := ["pwsh", "-NoLogo", "-NoProfile", "-Command"]

# Show the recipes.
default:
    @just --list --unsorted

# Everything CI enforces: manifest, parse, json, static analysis, tests.
check:
    @pwsh -NoProfile -File ./ci/check.ps1

# Validate the module manifest.
manifest:
    @pwsh -NoProfile -File ./ci/check.ps1 -Phase manifest

# Parse every .ps1, .psd1 and .ps1xml.
parse:
    @pwsh -NoProfile -File ./ci/check.ps1 -Phase parse

# Validate every JSON file, including the branch-protection payload.
json:
    @pwsh -NoProfile -File ./ci/check.ps1 -Phase json

# PSScriptAnalyzer, default rules, no settings file.
analyze:
    @pwsh -NoProfile -File ./ci/check.ps1 -Phase analyze

# Pester.
test:
    @pwsh -NoProfile -File ./ci/check.ps1 -Phase test
