# Rulesets

`main.json` is the branch protection payload, applied under the name
**`main-protection`**. It is committed because a ruleset is applied state that
lives only on GitHub: it vanishes silently on repository recreate, rename or fork,
and nothing in a clone reveals it is gone.

**The file is the source of truth. Apply it; do not hand-configure.** This payload
spent several commits describing protection that had been set by hand and never
matched it, which is the failure it exists to prevent.

```bash
# create
gh api repos/<org>/<repo>/rulesets --method POST --input .github/rulesets/main.json

# update an existing one
gh api repos/<org>/<repo>/rulesets/<id> --method PUT --input .github/rulesets/main.json
```

Read back what is enforced from the **rules** endpoint. The legacy
branch-protection API reports `enforcement_level: off` even where a ruleset is
demonstrably active, which is a good way to conclude protection is missing when it
is not:

```bash
gh api repos/<org>/<repo>/rules/branches/main
```

## Things that will catch you

**A required context is a job name, and renaming a job is a protection change.**
Rename one without updating this file and the ruleset waits forever on a context
nothing will ever report — indistinguishable from one merely pending, so the
branch wedges with no visible cause. The `json` check asserts every context here
resolves to a job in a workflow, so a typo fails the pull request that introduced
it rather than the branch afterwards.

**A job that cannot report on a pull request must never be required.** `history`
in `commit-convention.yml` runs only on pushes, which is why it is deliberately
absent from the payload.

**Apply only after every context has reported at least once.** A context that has
never run cannot be distinguished from one that is pending.

**`pull_request` requires zero approving reviews, deliberately.** GitHub does not
allow approving your own pull request, so any non-zero count deadlocks a
single-owner repository outright. Do not "fix" this.

**`bypass_actors` holds one entry, the release App, with `actor_id: 0` until that
App exists.** A bypass list naming a nonexistent actor is equivalent to an empty
one — safe to apply, and the release workflow simply cannot push until the real id
replaces it.

The exemption belongs to the **actor**, not to `release.yml`: anything that can
mint the App's token can push to `main` unreviewed. Keeping
`RELEASE_APP_CLIENT_ID` and `RELEASE_APP_PRIVATE_KEY` on an environment with a
required reviewer is what keeps that narrow.

To push by hand instead, set `enforcement` to `disabled` first — a deliberate,
visible act rather than a standing exemption.
