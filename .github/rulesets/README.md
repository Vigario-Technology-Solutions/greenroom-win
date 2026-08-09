# Rulesets

Two payloads, applied under the names **`main-protection`** and
**`tag-protection`** — named for what they target, never for what they contain, so
a name stays true when the rules inside it change.

| File | Applied as | Target |
|---|---|---|
| `main.json` | `main-protection` | the default branch |
| `tag-protection.json` | `tag-protection` | every tag |

They are committed because a ruleset is applied state that lives only on GitHub: it
vanishes silently on repository recreate, rename or fork, and nothing in a clone
reveals it is gone.

**The file is the source of truth. Apply it; do not hand-configure.** This payload
spent several commits describing protection that had been set by hand and never
matched it, which is the failure it exists to prevent.

**Both payloads are applied, and each is a separate call.** Applying one leaves the
other unenforced with nothing to indicate it — which is the exact failure this
directory exists to prevent, so it is worth being explicit that there are two.

```bash
# create
gh api repos/<org>/<repo>/rulesets --method POST --input .github/rulesets/main.json
gh api repos/<org>/<repo>/rulesets --method POST --input .github/rulesets/tag-protection.json

# update an existing one -- ids differ per ruleset, so list them first
gh api repos/<org>/<repo>/rulesets --jq '.[] | "\(.id)  \(.name)"'
gh api repos/<org>/<repo>/rulesets/<main-id> --method PUT --input .github/rulesets/main.json
gh api repos/<org>/<repo>/rulesets/<tag-id>  --method PUT --input .github/rulesets/tag-protection.json
```

Read back what is enforced from the **rules** endpoint. The legacy
branch-protection API reports `enforcement_level: off` even where a ruleset is
demonstrably active, which is a good way to conclude protection is missing when it
is not:

```bash
gh api repos/<org>/<repo>/rules/branches/main
```

**There is no tag equivalent of that endpoint.** `rules/tags/<tag>` returns 404 even
with `tag-protection` active, so verifying the tag payload means reading the ruleset
back by id and comparing it to the file:

```bash
gh api repos/<org>/<repo>/rulesets/<tag-id> --jq '{name, target, enforcement, bypass_actors, rules: [.rules[].type]}'
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

**`bypass_actors` holds one entry: the release App, by its APP ID** — the number,
not the `Iv23li...` Client ID that goes in the workflow's secret. **Install the App
on the repository before applying**, or the whole `PUT` fails with a 422:
*"Invalid bypass actor"*. GitHub will not accept an actor it cannot resolve, which
is also why the `actor_id: 0` placeholder this file once carried made the payload
un-appliable rather than merely inert.

**`bypass_mode: always` bypasses every rule in the ruleset, not just the
pull-request one** — so the App could in principle force-push or delete `main`, not
merely skip review. Scoping that down means splitting this into two rulesets, one
carrying the PR and status-check rules with the bypass and one carrying the
integrity rules without. Considered and declined for a single-owner repository;
revisit if more actors ever hold a bypass.

The exemption belongs to the **actor**, not to `release.yml`: anything that can
mint the App's token can push to `main` unreviewed. That is why
`RELEASE_APP_CLIENT_ID` and `RELEASE_APP_PRIVATE_KEY` live on the `release`
environment — required reviewer, limited to `main` — rather than repository-wide.

To push by hand instead, set `enforcement` to `disabled` first — a deliberate,
visible act rather than a standing exemption.

## `tag-protection`

One version must never name two sets of bits. The tag is published as the name of
what shipped, so it has to keep meaning that whether or not anything builds from it.

`deletion` and `non_fast_forward`, over `~ALL` tags. Creating a tag is neither, so
the release still tags normally — which is why this payload carries **no bypass
actor at all**, unlike `main-protection`. Nothing needs an exemption to do the one
thing releases do.

**It only holds for annotated tags.** `non_fast_forward` blocks re-pointing an
annotated tag, but a *lightweight* tag moved to a descendant is a fast-forward and
passes. Immutability therefore rests on releases being cut with `--annotated`, which
`release.yml` does; a lightweight tag would slip past this ruleset without error.

This arrives with the first tag and not before — a rule guarding a namespace nothing
writes to is a claim without a subject.
