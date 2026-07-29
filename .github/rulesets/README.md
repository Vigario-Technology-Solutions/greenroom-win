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

## Not included

`required_status_checks` is absent because this repository has no CI. Adding a
required check whose job never reports wedges the branch permanently, so the rule
only goes in alongside the workflow that satisfies it.
