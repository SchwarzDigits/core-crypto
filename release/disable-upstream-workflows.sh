#!/usr/bin/env bash
# Disables every GitHub Actions workflow of the fork except .github/workflows/digits-release.yml.
# Wire's workflows come along with each merge from upstream, and some of them start on any tag. Run
# this after each merge from upstream, before pushing a release tag; GitHub lists a new workflow once
# a push has brought it.
#
#   release/disable-upstream-workflows.sh [<owner>/<repo>]    (default SchwarzDigits/core-crypto)
set -euo pipefail
repo="${1:-SchwarzDigits/core-crypto}"
keep=.github/workflows/digits-release.yml
# One page holds them all; gh's pagination of this list broke off with truncated JSON.
list="$(gh api "repos/$repo/actions/workflows?per_page=100")"
if [ "$(jq .total_count <<<"$list")" -gt 100 ]; then
  echo "more than 100 workflows; page through the list" >&2
  exit 1
fi
jq -r '.workflows[] | "\(.id) \(.state) \(.path)"' <<<"$list" |
  while read -r id state path; do
    # gh would read the rest of the list from stdin.
    if [ "$path" = "$keep" ]; then
      [ "$state" = active ] || gh api -X PUT "repos/$repo/actions/workflows/$id/enable" </dev/null
      echo "active    $path"
    elif [ "$state" = active ]; then
      gh api -X PUT "repos/$repo/actions/workflows/$id/disable" </dev/null
      echo "disabled  $path"
    fi
  done
