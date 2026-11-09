#!/usr/bin/env bash
# Find and optionally merge the low-risk Dependabot PRs.
#
# Usage: dependabot-lockfile-prs.sh [--merge|--risky]
#
# A candidate is an open Dependabot PR that changes only dependency files:
# requirements .in and .txt, package.json, or a lock file. Each candidate is
# low-risk when all of these hold:
#   - CI has no failing check and nothing pending
#   - the bump is not a major version change
#   - a backend bump does not touch a package that a .in file pins with ==
#     unless the PR also updates that .in (pip-compile would revert it)
#
# Without a flag, print every candidate with its verdict. With --risky, print
# only the candidates that are not low-risk. With --merge,
# approve and squash merge each low-risk PR in turn, waiting for Dependabot
# to rebase the next one and for CI to pass before continuing.
#
# Run it from a checkout of the target repo: gh picks the repo from the
# checkout and the .in files are read from disk. Set REQ_DIR when the .in
# files live somewhere other than backend/requirements.
set -euo pipefail

flag=${1:-}
req_dir=${REQ_DIR:-backend/requirements}
# jq regex, so dots are escaped with a doubled backslash
dep_files='(\\.in|\\.txt|package\\.json|package-lock\\.json|yarn\\.lock|pnpm-lock\\.yaml)$'

compile_note() {
  # $1 package, $2 changed files. Says whether pip-compile keeps the bump.
  local pkg=$1 files=$2 spec
  case "$files" in *"$req_dir"*) ;; *) echo "-"; return ;; esac
  spec=$(grep -hiE "^${pkg}(\[[^]]*\])?\s*(==|$|\s|#)" "$req_dir"/*.in 2>/dev/null | head -1 || true)
  if [ -z "$spec" ]; then echo "transitive"
  elif [[ "$spec" == *"=="* ]]; then
    case "$files" in *.in*) echo "pin-updated" ;; *) echo "pinned-in-.in" ;; esac
  else echo "unpinned-in-.in"
  fi
}

verdict() {
  # $1 state, $2 fails, $3 pending, $4 note, $5 title
  local from to
  [ "$2" -gt 0 ] && { echo "ci-failing"; return; }
  [ "$3" -gt 0 ] && { echo "ci-pending"; return; }
  [ "$4" = "pinned-in-.in" ] && { echo "compile-reverts"; return; }
  from=$(sed -E 's/.* from ([0-9]+)\..*/\1/' <<<"$5")
  to=$(sed -E 's/.* to ([0-9]+)\..*/\1/' <<<"$5")
  [ "$from" != "$to" ] && { echo "major"; return; }
  case "$1" in CLEAN|BLOCKED|BEHIND) echo "low-risk" ;; *) echo "$1" ;; esac
}

candidates() {
  gh pr list --state open --author app/dependabot --limit 100 \
    --json number,title,files,mergeStateStatus,statusCheckRollup \
    --jq '
      .[]
      | select(all(.files[].path; test("'"$dep_files"'")))
      | [
          .number,
          .mergeStateStatus,
          ([.statusCheckRollup[]? | select(.conclusion == "FAILURE")] | length),
          ([.statusCheckRollup[]? | select(.status != "COMPLETED")] | length),
          ([.files[].path] | join(" ")),
          .title
        ]
      | @tsv' \
  | while IFS=$'\t' read -r number state fails pending files title; do
      pkg=$(sed -E 's/.*bump ([^ ]+) from .*/\1/' <<<"$title")
      note=$(compile_note "$pkg" "$files")
      printf '%s\t%s\t%s\t%s\n' "$number" "$(verdict "$state" "$fails" "$pending" "$note" "$title")" "$note" "$title"
    done
}

wait_and_merge() {
  # $1 PR number. Waits for a clean, green head, then approves and merges.
  local n=$1 tries=0 state st
  while :; do
    state=$(gh pr view "$n" --json state --jq .state)
    [ "$state" != "OPEN" ] && { echo "  $n is $state, skipping"; return; }
    st=$(gh pr view "$n" --json mergeStateStatus,statusCheckRollup --jq '
      "\(.mergeStateStatus) pending=\([.statusCheckRollup[]? | select(.status != "COMPLETED")] | length) fail=\([.statusCheckRollup[]? | select(.conclusion == "FAILURE")] | length)"')
    echo "  $n: $st"
    case "$st" in
      "CLEAN pending=0 fail=0") break ;;
      *"fail="[1-9]*) echo "  $n has a failing check, skipping"; return ;;
    esac
    tries=$((tries+1)); [ $tries -gt 40 ] && { echo "  timed out on $n, skipping"; return; }
    sleep 30
  done
  gh pr review "$n" --approve >/dev/null 2>&1 || true
  gh pr merge "$n" --squash
  echo "  merged $n"
}

rows=$(candidates)
[ "$flag" = "--risky" ] && rows=$(awk -F'\t' '$2!="low-risk"' <<<"$rows")
printf 'PR\tverdict\tcompile\ttitle\n%s\n' "$rows" | column -t -s $'\t'

[ "$flag" = "--merge" ] || exit 0

echo
low=$(awk -F'\t' '$2=="low-risk"{print $1}' <<<"$rows")
[ -z "$low" ] && { echo "nothing low-risk to merge"; exit 0; }
for n in $low; do
  echo "== $n =="
  wait_and_merge "$n"
done
