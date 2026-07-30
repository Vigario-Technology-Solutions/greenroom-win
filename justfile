# greenroom-win task runner.
#
# `just check` is the whole gate. CI runs the same phases out of this file, one per job,
# so a red X names the failure -- which is what keeps a green local run and a green pull
# request meaning the same thing. Anything CI enforced that was not reachable from here
# would make the pull request the only place a failure can be found.
#
# Recipes run under pwsh on every platform so there is one dialect rather than two, and
# the gate's logic lives in ci/check.ps1 -- just's shebang recipes require cygpath on
# Windows, which is this repository's whole audience.
#
# The gate needs NOTHING but pwsh. That is deliberate: it has to stay runnable on a host
# with no network and no extra tooling, which is the situation you are in precisely when
# something is already broken.

set shell := ["pwsh", "-NoLogo", "-NoProfile", "-Command"]

# Recipe parameters reach recipes as environment variables. `verify` relies on it: a
# subject passed through shell quoting breaks on an apostrophe, because just quotes for
# POSIX (`'\''`) while pwsh escapes by doubling instead.
set export := true

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

# The two below need cocogitto on PATH (a release binary from
# github.com/cocogitto/cocogitto). `just check` deliberately does not -- the gate stays
# runnable with nothing but pwsh, and commit tooling is not something you should have to
# install to find out whether the tree is sound.

# Lint a subject the way CI lints a pull request title: `just verify "feat: add a thing"`.
verify subject:
    @cog verify $env:subject

# Lint the whole history, as the post-merge check does.
lint:
    @cog check

# What the next release would be, and what would be in it. Writes nothing.
next:
    @cog bump --auto --dry-run
    @cog changelog

# Release. Normally run by the workflow, not by hand -- it commits, tags and pushes.
release version="--auto":
    @cog bump {{ if version == "--auto" { "--auto" } else { "--version " + version } }} --annotated "greenroom-win {{{{version}}}}"
