# Rulesets

`main.json` is the branch protection payload for this repository. It is committed
because a ruleset is applied state that lives only on GitHub: it vanishes silently
on repository recreate, rename or fork, and nothing in a clone reveals it is gone.

The file is the source of truth. Apply it, do not hand-configure:

```bash
# create
gh api repos/<org>/<repo>/rulesets --method POST --input .github/rulesets/main.json

# update an existing one
gh api repos/<org>/<repo>/rulesets/<id> --method PUT --input .github/rulesets/main.json
```

Read back what is actually enforced — from the **rules** endpoint, not the legacy
branch-protection API, which reports `enforcement_level: off` even where a ruleset
is demonstrably active:

```bash
gh api repos/<org>/<repo>/rules/branches/main
```

## Why each rule

**`pull_request`, 0 approvals** — a single owner cannot approve their own pull
request, so requiring one deadlocks the repository. The pull request is the record;
the approval count adds nothing when there is one reviewer.

**`allowed_merge_methods: squash, rebase`** — no merge commits. A second parent
buys nothing merging into linear history.

**`deletion`, `non_fast_forward`** — the branch cannot be removed or rewritten.

**`required_linear_history`** — not the same lever as disabling merge commits in
the repository settings. Merge methods are settings: one API call re-enables them,
touching no ruleset and leaving nothing in the ruleset history. The rule holds the
shape against a setting drifting back.

**`required_status_checks: check, pr-title`** — the contexts are the `name:` fields
of those jobs. Renaming a job silently disables its gate, because the ruleset keeps
waiting for a context nothing produces. `history` is deliberately *not* required: it
runs after the merge, so requiring it could only block the next unrelated pull
request.

**`bypass_actors`: the release App, and nothing else** — this was `[]`, and the
reasoning for that still holds for humans: an actor-based exemption is inherited by
anything authenticating as that actor, and "repository admin" on a single-owner
repository exempts the owner and every automation acting on their behalf, which is
the entire population the rule exists to constrain.

The App is the one exception, because the release commit carries the bumped
`ModuleVersion` and the generated changelog and therefore has to land on `main`. The
alternative — a release pull request — cannot work: a pull request opened with the
built-in `GITHUB_TOKEN` does not trigger `on: pull_request`, so the required checks
would never report and it could never merge.

The grant is scoped to what a release actually does: one commit containing only
`CHANGELOG.md` and the manifest, produced by `cog bump` from commits that already
passed the gate. The App holds `Contents: Read and write` on this repository and
nothing else.

## Before applying

**`actor_id: 0` is a placeholder** and must be replaced with the App's real id. It is
not a wildcard — applying it as `0` grants nothing, and the first release run would be
refused by `main`.

```powershell
gh api /repos/Vigario-Technology-Solutions/greenroom-win/installation --jq '.app_id'
```

**The `name` must match the live ruleset.** It is `main-protection`. An earlier
revision of this file said `main: PR only`, so an apply-by-name would have matched
nothing and silently done nothing.

**Order matters.** Apply only after `check` and `pr-title` are on `main` and have been
seen to report. A required context that never reports blocks every pull request,
including the one that would fix it; the way out is relax → merge → tighten → verify.
