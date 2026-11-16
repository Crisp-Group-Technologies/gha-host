#!/usr/bin/env bash
# GitHub API helpers for host-side scripts. Source after common.sh and load_config.

gh_call() { "$GHA_HOME/scripts/get-token.sh" call "$@"; }

# gh_list_runners: print a JSON array of all org runners (paginated)
gh_list_runners() {
  local page=1 out="[]" body n
  while ((page <= 20)); do
    body=$(gh_call GET "/orgs/$GH_ORG/actions/runners?per_page=100&page=$page") || return 1
    out=$(jq -c -s '.[0] + .[1].runners' <(echo "$out") <(echo "$body"))
    n=$(jq '.runners | length' <<<"$body")
    ((n < 100)) && break
    page=$((page + 1))
  done
  echo "$out"
}

# gh_runners_with_prefix PREFIX: JSON array of runners whose name starts with PREFIX
gh_runners_with_prefix() {
  gh_list_runners | jq -c --arg p "$1" '[.[] | select(.name | startswith($p))]'
}

gh_delete_runner() { gh_call DELETE "/orgs/$GH_ORG/actions/runners/$1" >/dev/null; }
