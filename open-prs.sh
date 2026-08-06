#!/bin/zsh
set +x

PR_SEARCH_LIMIT="${PR_SEARCH_LIMIT:-100}"

ENGINEERS=(aarongregory-qz arturonieto-qz bryceeller-qz chrisopperwall-qz nanditanaik-qz q-lucas-tannus rlarner-quizlet
scv-roma-caro scvsoft-ayelensanchez scvsoft-briangrajeda scvsoft-damianpisaturo scvsoft-danielwyrytowski scvsoft-federicocolombatti
scvsoft-leilaybanez scvsoft-miguelgonzalez scvsoft-rodrigobalazs scvsoft-tano shogotanaka-qz yangli-qz)

REPOS=(quizlet/quizlet-web quizlet/go-services quizlet/quizlet-infrastructure quizlet/monitoring-infra quizlet/quizlet-shared-config)

function gh_safe() {
  env -u GH_TOKEN -u GITHUB_TOKEN gh "$@"
}

function run_gh_capture() {
  local err_file output gh_exit_code
  err_file=$(mktemp)

  if output=$(gh_safe "$@" 2>"$err_file"); then
    REPLY="$output"
    GH_LAST_COMMAND="gh $*"
    GH_LAST_ERROR=""
    GH_LAST_STATUS=0
    rm -f "$err_file"
    return 0
  fi

  gh_exit_code=$?
  REPLY=""
  GH_LAST_COMMAND="gh $*"
  GH_LAST_ERROR=$(<"$err_file")
  GH_LAST_STATUS=$gh_exit_code
  rm -f "$err_file"
  return $gh_exit_code
}

function warn_gh_failure() {
  local context="$1"
  local indented_error

  echo "Warning: $context" >&2
  [[ -n "$GH_LAST_COMMAND" ]] && echo "  Command: $GH_LAST_COMMAND" >&2
  echo "  Exit code: ${GH_LAST_STATUS:-unknown}" >&2

  if [[ -n "$GH_LAST_ERROR" ]]; then
    indented_error="${GH_LAST_ERROR//$'\n'/$'\n  '}"
    echo "  gh error: $indented_error" >&2
  else
    echo "  gh error: (no stderr output)" >&2
  fi
}

declare -A REPO_SET
for repo in "${REPOS[@]}"; do
  REPO_SET[$repo]=1
done

tmpfile=$(mktemp)
had_errors=0

for eng in "${ENGINEERS[@]}"; do
  if ! run_gh_capture search prs --author "$eng" --state open \
    --json number,title,repository,url,createdAt --limit "$PR_SEARCH_LIMIT" -- "-is:draft"; then
    warn_gh_failure "failed to search open non-draft PRs for $eng"
    had_errors=1
    continue
  fi

  [[ -n "$REPLY" ]] || continue
  print -r -- "$REPLY" | jq -r --arg eng "$eng" \
    '.[] | [.repository.nameWithOwner, (.number|tostring), .title, $eng, .url, ((now - (.createdAt|fromdateiso8601))/86400|floor|tostring)] | @tsv' >> "$tmpfile"
done

if [[ ! -s "$tmpfile" ]]; then
  echo "No open non-draft PRs found."
  rm -f "$tmpfile"
  (( had_errors )) && exit 1
  exit 0
fi

echo "Open non-draft PRs by repo and number:"

current_repo=""
match_count=0
while IFS=$'\t' read -r repo pr title eng url days; do
  [[ -n "${REPO_SET[$repo]}" ]] || continue

  if [[ "$repo" != "$current_repo" ]]; then
    echo
    echo "$repo"
    current_repo="$repo"
  fi

  echo "- ${days}d - $url - $title - $eng"
  (( match_count++ ))
done < <(sort -t $'\t' -k1,1 -k2,2n "$tmpfile")

if (( match_count == 0 )); then
  echo "No open non-draft PRs found in configured repos."
fi

rm -f "$tmpfile"

if (( had_errors )); then
  echo
  echo "Completed with GitHub query errors; results may be incomplete." >&2
  exit 1
fi
