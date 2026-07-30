# Rulesets

`main.json` is the branch protection payload for this repository, applied under the
name **`main-protection`**. A ruleset is named for what it targets rather than what
it contains, because contents change and targets do not — this file was called
`main: PR only` until required checks were added to it, at which point the name
described protection that no longer existed.

It is committed because a ruleset is applied state that lives only on GitHub: it
vanishes silently on repository recreate, rename or fork, and nothing in a clone
reveals it is gone.

The file is the source of truth. Apply it, do not hand-configure — this payload
went several commits describing protection that had been set by hand and never
matched it, which is the failure the file exists to prevent:

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

**`allowed_merge_methods: squash`** — no merge commits and no rebase. A second
parent buys nothing merging into linear history, and rebase replays a branch's
commits onto `main` verbatim, so nothing that checked the pull request title has
covered them. Keeping it would mean the rules here apply to some commits on main
and not others, decided by which button was pressed. Re-allow it only alongside
something that lints the commits it lets through.

**`deletion`, `non_fast_forward`** — the branch cannot be removed or rewritten.

**`required_linear_history`** — not the same lever as disabling merge commits in
the repository settings. Merge methods are settings: one API call re-enables them,
touching no ruleset and leaving nothing in the ruleset history. The rule holds the
shape against a setting drifting back.

**`bypass_actors`** — exactly one, the release App, and `actor_id` is `0` until
that App exists. An actor-based exemption is inherited by anything authenticating
as that actor, which is why "repository admin" is not used: on a single-owner
repository it exempts the owner and every automation acting on the owner's
behalf, the entire population the rule exists to constrain. An App is a narrower
actor — it is only ever itself, its installation token lasts an hour, and
revoking it is uninstalling it.

It is here because a release has to write `main` and the alternative is worse. A
pull request opened with the built-in `GITHUB_TOKEN` does not trigger
`on: pull_request`, so a release PR would sit forever on six required contexts
that can never report. The App pushes one commit containing only `CHANGELOG.md`
and the manifest, built by `cog bump` from commits that already passed the gate.

**`actor_id: 0` is a placeholder and applying it is safe** — a bypass list naming
an actor that does not exist is equivalent to an empty one. Replace it with the
real App id once the App exists, then re-apply; until then the release workflow
cannot push, which is the correct failure.

To push by hand instead, set `enforcement` to `disabled` first — a deliberate,
visible act.

**`required_status_checks`** — six contexts, one per job that must pass:
`manifest`, `parse`, `json`, `analyze` and `test` from `.github/workflows/ci.yml`,
and `pr-title` from `.github/workflows/commit-convention.yml`. A context is a job
name, and jobs live wherever their trigger puts them — `pr-title` runs on events
the gate does not, so it is a different workflow and still a required check. The
list is meant to *be* the list of what must pass. A single aggregate job
depending on the others would report one context in place of five, and what a
reviewer sees would stop being what is enforced — and a job missing from its
`needs:` would leave this reading as complete while covering less, with nothing
anywhere to report the gap.

The cost is real: renaming a job here is a protection change, and forgetting to
make it one leaves this file waiting on a context nothing will ever report,
which is indistinguishable from one merely pending. That trade is taken because
the two failures are not comparable — a wedged branch is loud, immediate, and
fixed by whoever caused it, while silent under-coverage is a false belief held
indefinitely.

And the wedge is guarded: the `json` phase asserts every context named here
resolves to a job in the workflow, so a typo fails the check that introduced it
rather than the branch afterwards.

`strict_required_status_checks_policy` is `false`. Requiring a branch to be up to
date with `main` before merging turns every merge into a rebase-and-rerun for
everyone behind it, which on a single-maintainer repository buys serialisation
nobody asked for. `required_linear_history` already keeps the graph readable.

`history`, in that same workflow, is deliberately **not** here. It runs on pushes,
so it would never report on a pull request, and a required context that cannot
report wedges the branch permanently.

## Applying it

Apply this **after** all six have reported at least once on a pull request. A
required context that has never run cannot be distinguished from one that is
merely pending, so applying it first wedges the branch with no obvious cause.
