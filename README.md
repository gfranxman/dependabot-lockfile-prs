# dependabot-lockfile-prs

Find the low-risk Dependabot pull requests in a repo. With a flag, merge
them one at a time.

## Requirements

- `gh` (the GitHub CLI), logged in with permission to review and merge
- No separate `jq` install. The script uses the `--jq` flag of `gh`.

## Usage

Run the script from a checkout of the target repo:

```
dependabot-lockfile-prs.sh            # report only
dependabot-lockfile-prs.sh --merge    # approve and squash merge the low-risk set
```

The script reads the `.in` files from disk, so it must run inside the
checkout. If the pip-compile `.in` files are not in `backend/requirements`,
set `REQ_DIR` to their repo-relative path.

## What counts as a candidate

An open Dependabot PR whose changed files are all dependency files:
requirements `.in` or `.txt`, `package.json`, or a lock file.

## What counts as low-risk

A candidate is low-risk if all of these conditions are true:

- CI has no failing check and nothing pending.
- The bump is not a major version change.
- A backend bump does not leave a `==` pin in a `.in` file unchanged. The
  next `pip-compile` reverts a `.txt`-only bump of a pinned package.

Every other candidate prints the reason instead: `ci-failing`,
`ci-pending`, `major`, `compile-reverts`, or the raw merge state such as
`DIRTY`.

## The compile column

Backend requirements `.txt` files are compiled from `.in` files, so the
report says whether the bump survives the next compile:

| value | meaning |
|---|---|
| `pin-updated` | the `.in` pins the package with `==` and the PR updated it |
| `pinned-in-.in` | the `.in` pins the package and the PR did not touch it |
| `unpinned-in-.in` | the `.in` lists the package without a version |
| `transitive` | no `.in` names the package |
| `-` | not a backend PR |

## Merge mode

With `--merge`, the script takes the low-risk rows in order. For each one it
waits until the head is clean with green checks, approves it as you, and
squash merges it. It skips a PR that Dependabot closes mid-run, one that
starts failing, or one that stays unmergeable for twenty minutes.

The approval is yours, so read the report first.
