# CI/CD — what is here, and where it diverges from the estate document

The estate-wide design is `docs/cicd-final-state.typ` in `server-admin`. That
document is the guide; this one records what was actually built here, every point
where this repository differs from it, and why. Where a divergence is a decision
rather than a consequence, it is marked as a decision and left open — the estate
document lists D1–D8 as decisions for the owner, and settling one silently would
defeat the point of having listed it.

Nothing here changes live branch protection. See **Applying the ruleset** at the
end.

---

## What was added

| Path | Purpose |
|---|---|
| `justfile` | Task runner. `just check` is the whole gate. |
| `ci/check.ps1` | The gate's logic: parse, static analysis, JSON validity. |
| `PSScriptAnalyzerSettings.psd1` | Analyzer config; every exclusion names its cause. |
| `cliff.toml` | git-cliff config. The changelog is generated from subjects. |
| `.commitlintrc.js` | Conventional Commits, same type set as the other repos. |
| `package.json`, `package-lock.json`, `.nvmrc` | Tooling-only; node exists to run commitlint. |
| `.github/workflows/check.yml` | Runs `just check`. Required. |
| `.github/workflows/pr-title.yml` | commitlint on the PR title. Required. |
| `.github/workflows/main-subject.yml` | commitlint on subjects pushed to main. Not required. |
| `.github/rulesets/main.json` | Adds the two required-check contexts. Not yet applied. |

`just check` passes on this tree. It found one real defect on its first run: the
gate's own script defined `Test-Json`, which shadows PowerShell's built-in cmdlet
of that name. Renamed to `Test-JsonFiles`.

---

## Divergences from the estate document

### 1 · The gate is `just check`, and CI runs nothing else

The estate document says nothing about a task runner — `server-admin`'s justfile
only imports the `press` document pipeline, so there was no pattern to copy. The
rule adopted here is that CI runs `just check` and nothing more, so a green local
run and a green pull request mean the same thing. Any check reachable only from CI
would make the pull request the only place a failure can be found.

**Consequence:** `just` must exist on the runner. It is installed with
`extractions/setup-just@v3`, which is a third-party action — see divergence 6.

### 2 · The gate's logic is a script, not `just` recipe bodies

`just`'s shebang recipes (`#!/usr/bin/env pwsh`) require `cygpath` on Windows and
fail outright without it. Measured here: `error: could not find cygpath executable
to translate recipe parse shebang interpreter path`. Since Windows is this
repository's entire audience, the logic lives in `ci/check.ps1` and the recipes are
thin wrappers. It is also directly runnable — `pwsh ./ci/check.ps1` — so a host
with neither `just` nor a network can still verify the tree.

### 3 · The gate runs on Linux, for a Windows-only codebase

`ubuntu-latest`, not `windows-latest`. Nothing in the gate executes the scripts —
parsing and static analysis only read them — so the Windows-only cmdlets inside
are irrelevant to the checker, and `pwsh` is preinstalled on the Ubuntu images.
This follows the document's cost rule (*"Private: group jobs — minute optimisation
is real work"*): private minutes are billed, and Windows runners are billed at a
multiplier.

**This is a real limitation, stated rather than hidden.** No check here proves the
scripts *run* on Windows. A test that installed an instance and attached to it
would need a Windows runner and a Claude Code login, so it is out of reach; that
verification stays manual and is what the reference-host measurements in the pull
requests are.

### 4 · One job, not a fan-out

The document makes this conditional on cost: private groups jobs, public fans out.
This repository is private, so one `check` job. If it goes public, splitting parse
/ analyze / json is then free and makes a red X name the actual failure.

### 5 · No path filters on any workflow

Direct from the document: a required check with a path filter never reports on a
pull request that touches nothing it matches, and the branch wedges waiting for a
check that will never arrive. No `paths:` anywhere.

### 6 · Third-party actions are pinned by tag, not by SHA

D5 in the document is *"SHA-pin third-party actions? All repos or none."* It is
listed as undecided. `server-admin` currently uses tags (`actions/checkout@v6`),
so this repository matches it rather than diverging unilaterally — "all repos or
none" is only meaningful if it is answered once for the estate.

**Open decision.** The third-party action here is `extractions/setup-just@v3`.
`actions/*` and `github/*` are first-party. If D5 is answered "SHA-pin", this file
and that workflow change together.

### 7 · The changelog is generated, and the current file was seeded by hand

`cliff.toml` produces `CHANGELOG.md` from commit subjects. Because squash merges
land `PR_TITLE` with a `BLANK` body, a commit on main is one conventional-commit
subject and nothing else — that is the entire input, with no bodies to parse and
no stacked footers.

The committed `CHANGELOG.md` is a hand-written stub: a header and `## 0.1.0 —
Initial release.` It carries no date, because 0.1.0 was never tagged and nothing in
the repository establishes one. Generation takes over at the first real release;
`cliff.toml`'s header is byte-identical to the stub's so regeneration does not
fight it.

`just changelog` previews and writes nothing. `just changelog-write` is the only
sanctioned way the file changes, and it belongs in a version-bump pull request,
gated like any other — which is the document's read-only release shape: *"The bump
and changelog land as an ordinary gated PR; the release only creates a tag."*

### 8 · `docs`, `ci`, `build`, `chore` and `test` are skipped in the changelog

The document says the type encodes release impact. Types that describe how the
repository is maintained rather than what a user receives produce no changelog
line. Breaking changes are exempt via `protect_breaking_commits`, so a `chore!:`
that removes a flag still appears.

### 9 · Linting main is kept, as a notification

The document argues for this and it is implemented in `main-subject.yml`, not
required, because it runs after the merge and requiring it could only block the
next unrelated pull request.

**It earns its place immediately.** This repository already contains a subject
git-cliff silently drops:

```
feat: make attach work on elevated instances instead of refusing, and stop       dropping sessions that cannot be identified
```

129 characters with a run of spaces from a wrap artifact — over the 120-character
limit, so commitlint rejects it and git-cliff skips it with only a warning about
"1 commit(s) skipped due to parse error(s)". It is a branch commit, so a squash
merge discards it harmlessly. A **rebase** merge would replay it onto main and
lose it from the changelog with no signal, which is exactly the gap the document
identifies. `rebase` is in `allowed_merge_methods`, so the gap is live.

---

## Deliberately not built

These are the estate document's own open decisions. Implementing any of them
means answering a question that was explicitly left to the owner.

| | Question | Status here |
|---|---|---|
| **D1** | Advisory or gating? | **Answered: gating.** The document recommends it everywhere, and the payload adds the required contexts. Not applied yet. |
| **D2** | Read-only release, or a machine identity? | Open. No release workflow exists, so nothing here needs a credential. |
| **D3** | Who prepares the version-bump PR? | Open. `just changelog-write` exists for whoever does. |
| **D4** | Environment gate on tagging? | Open, and moot until a release path exists. |
| **D5** | SHA-pin third-party actions? | Open. Tag-pinned for now, matching `server-admin`. |
| **D6** | Retire the existing release App? | Not applicable — this repository has none. |
| **D7** | Protect the repo that builds and signs? | Not applicable — nothing is built or signed here. |
| **D8** | Security surface: all repos or public only? | Open, and partly priced: secret scanning and push protection are free on public repositories only, and this one is private. |

No release or tagging workflow was written. A tag-only release is the document's
recommended shape and needs no bypass actor, because tags are a separate ref
namespace from branches — but building it would settle D2, D3 and D4 by
implication.

---

## Applying the ruleset

Protection lives in the tree, and it is applied deliberately rather than by a
workflow. Committing this payload changes nothing on GitHub. To apply it:

```powershell
$id = gh api repos/Vigario-Technology-Solutions/greenroom-win/rulesets --jq '.[] | select(.name=="main: PR only") | .id'
gh api --method PUT repos/Vigario-Technology-Solutions/greenroom-win/rulesets/$id `
  --input .github/rulesets/main.json
```

Then verify, because an enforcement claim that is not read back from the live
ruleset is just a comment:

```powershell
gh api repos/Vigario-Technology-Solutions/greenroom-win/rulesets/$id `
  --jq '.rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks'
```

**Order matters.** Apply this only after the workflows are on `main` and have been
seen to report. A required context that never reports blocks every pull request,
including the one that would fix it, and with zero bypass actors the only way out
is the document's sanctioned manoeuvre: relax the rule, merge the fix, tighten it
again, verify.

**The job names are the contexts.** `check` and `pr-title` are the `name:` fields
in their workflows. Renaming a job silently disables its gate — the ruleset keeps
waiting for a context nothing produces.
