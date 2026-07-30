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

**`bypass_actors: []`** — an actor-based exemption is inherited by anything
authenticating as that actor. On a single-owner repository "repository admin"
exempts the owner and every automation acting on the owner's behalf, which is the
entire population the rule exists to constrain. To push directly, set `enforcement`
to `disabled` first — a deliberate, visible act.

**`required_status_checks`** — five contexts, one per job in
`.github/workflows/ci.yml`: `manifest`, `parse`, `json`, `analyze`, `test`. The
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

## Applying it

Apply this **after** all five have reported at least once on a pull request. A
required context that has never run cannot be distinguished from one that is
merely pending, so applying it first wedges the branch with no obvious cause.
