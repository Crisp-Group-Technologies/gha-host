#!/usr/bin/env bash
# get-token.sh - mint GitHub tokens for org-level self-hosted runners.
#
# Standalone on purpose: it is copied into the runner image (as gha-get-token)
# and also used on the host. It needs only bash, curl, jq and openssl.
#
# Usage:
#   get-token.sh registration        print a runner registration token
#   get-token.sh remove              print a runner removal token
#   get-token.sh token               print an API token (PAT, or App installation token)
#   get-token.sh call METHOD PATH    call the GitHub REST API, print the response body
#
# Environment:
#   GH_ORG (required)    GH_API_URL (default https://api.github.com)
#   GH_AUTH              auto | app | pat   (default auto)
#   GH_APP_ID, GH_APP_INSTALLATION_ID (optional, looked up), GH_APP_KEY_FILE
#   GH_PAT_FILE
set -euo pipefail
# make `x=$(cmd)` failures inside helper functions abort the script (bash >= 4.4)
shopt -s inherit_errexit

API="${GH_API_URL:-https://api.github.com}"
ORG="${GH_ORG:-}"
AUTH="${GH_AUTH:-auto}"

die() { echo "get-token: $*" >&2; exit 1; }
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# gh_curl TOKEN METHOD URL [curl args...]  (token goes via stdin, not argv)
gh_curl() {
  local tok=$1 method=$2 url=$3
  shift 3
  printf 'header = "Authorization: Bearer %s"\n' "$tok" |
    curl --fail-with-body -sS --retry 3 --retry-delay 2 --max-time 60 -K - \
      -X "$method" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$@" "$url"
}

resolve_auth() {
  case "$AUTH" in
    app | pat) echo "$AUTH" ;;
    auto)
      if [[ -n "${GH_APP_ID:-}" && -r "${GH_APP_KEY_FILE:-/nonexistent}" ]]; then
        echo app
      elif [[ -r "${GH_PAT_FILE:-/nonexistent}" ]]; then
        echo pat
      else
        die "no credentials: set GH_APP_ID + GH_APP_KEY_FILE, or GH_PAT_FILE"
      fi
      ;;
    *) die "GH_AUTH must be auto, app or pat (got '$AUTH')" ;;
  esac
}

app_jwt() {
  local now header payload unsigned sig
  [[ -n "${GH_APP_ID:-}" ]] || die "GH_APP_ID not set"
  [[ -r "${GH_APP_KEY_FILE:-}" ]] || die "GH_APP_KEY_FILE not readable"
  now=$(date +%s)
  header='{"alg":"RS256","typ":"JWT"}'
  payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$GH_APP_ID")
  unsigned="$(printf %s "$header" | b64url).$(printf %s "$payload" | b64url)"
  sig=$(printf %s "$unsigned" | openssl dgst -sha256 -sign "$GH_APP_KEY_FILE" -binary | b64url)
  printf '%s.%s' "$unsigned" "$sig"
}

api_token() {
  local mode jwt inst
  mode=$(resolve_auth)
  if [[ $mode == pat ]]; then
    [[ -r "${GH_PAT_FILE:-}" ]] || die "GH_PAT_FILE not readable"
    tr -d ' \r\n' <"$GH_PAT_FILE"
    return
  fi
  jwt=$(app_jwt)
  inst="${GH_APP_INSTALLATION_ID:-}"
  if [[ -z $inst ]]; then
    inst=$(gh_curl "$jwt" GET "$API/orgs/$ORG/installation" | jq -er .id) ||
      die "could not look up the App installation for org '$ORG' (is the App installed on it?)"
  fi
  gh_curl "$jwt" POST "$API/app/installations/$inst/access_tokens" | jq -er .token
}

[[ -n $ORG ]] || die "GH_ORG not set"
cmd="${1:-}"
case "$cmd" in
  registration | remove)
    tok=$(api_token)
    gh_curl "$tok" POST "$API/orgs/$ORG/actions/runners/${cmd}-token" | jq -er .token
    ;;
  token)
    api_token
    echo
    ;;
  call)
    method="${2:-}"
    path="${3:-}"
    [[ -n $method && $path == /* ]] || die "usage: get-token.sh call METHOD /path"
    tok=$(api_token)
    gh_curl "$tok" "$method" "$API$path"
    ;;
  *) die "usage: get-token.sh registration|remove|token|call METHOD PATH" ;;
esac
