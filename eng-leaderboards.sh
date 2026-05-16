#!/bin/zsh
set +x

CACHE_FILE="${0:A:h}/streak_cache.json"
USE_CACHE=1
POST_TO_SLACK=0
PRINT_SLACK_MESSAGE=0
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"

while (( $# > 0 )); do
  case "$1" in
    --no-cache)
      USE_CACHE=0
      ;;
    --post-to-slack)
      POST_TO_SLACK=1
      ;;
    --print-slack-message)
      PRINT_SLACK_MESSAGE=1
      ;;
    --slack-webhook-url)
      shift
      if [[ -z "${1:-}" ]]; then
        echo "Missing value for --slack-webhook-url" >&2
        exit 1
      fi
      SLACK_WEBHOOK_URL="$1"
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--no-cache] [--post-to-slack] [--print-slack-message] [--slack-webhook-url <url>]" >&2
      exit 1
      ;;
  esac
  shift
done

# GROWTH_ENGINEERS=(scvsoft-federicocolombatti scvsoft-tano)
GROWTH_ENGINEERS=(bryceeller-qz nanditanaik-qz rlarner-quizlet scv-roma-caro scvsoft-ayelensanchez scvsoft-briangrajeda scvsoft-damianpisaturo scvsoft-danielwyrytowski scvsoft-federicocolombatti
scvsoft-leilaybanez scvsoft-miguelgonzalez scvsoft-rodrigobalazs scvsoft-tano yangli-qz)

# Add any vacations so their streaks will freeze
declare -A VACATIONS
VACATIONS[2026-04-15]="nanditanaik-qz"
VACATIONS[2026-04-17]="scvsoft-damianpisaturo"
VACATIONS[2026-04-20]="rlarner-quizlet"
VACATIONS[2026-04-21]="rlarner-quizlet scv-roma-caro"
VACATIONS[2026-04-22]="rlarner-quizlet scv-roma-caro"
VACATIONS[2026-04-23]="scv-roma-caro"

PR_LOOKBACK_LIMIT="${PR_LOOKBACK_LIMIT:-100}"

# REPOS=(quizlet/go-services)
REPOS=(quizlet/quizlet-web quizlet/go-services quizlet/quizlet-infrastructure quizlet/monitoring-infra quizlet/quizlet-shared-config)


day_of_week=$(date +%u)
# handle the previous work day being a friday
if [[ "$day_of_week" == "1" ]]; then
  PREVIOUS_WORK_DAY=$(date -v-3d +%Y-%m-%d)
else
  PREVIOUS_WORK_DAY=$(date -v-1d +%Y-%m-%d)
fi
echo "Previous work day: $PREVIOUS_WORK_DAY"
overall_had_errors=0
declare -A GROWTH_ENGINEER_SET
for eng in "${GROWTH_ENGINEERS[@]}"; do
  GROWTH_ENGINEER_SET[$eng]=1
done

# ── Helpers ────────────────────────────────────────────────────────────────────

# Run gh using stored auth and ignore possibly stale env tokens.
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

function post_to_slack() {
  local message="$1"
  if (( ! POST_TO_SLACK )); then
    return
  fi
  if [[ -z "$SLACK_WEBHOOK_URL" ]]; then
    echo "Warning: --post-to-slack set but no webhook URL provided (set SLACK_WEBHOOK_URL or --slack-webhook-url)." >&2
    return
  fi
  if ! curl -fsS -X POST -H "Content-Type: application/json" \
    --data "$(jq -n --arg text "$message" '{text: $text}')" \
    "$SLACK_WEBHOOK_URL" >/dev/null; then
    echo "Warning: failed to post leaderboard to Slack webhook." >&2
    return
  fi
  echo "Posted leaderboard to Slack."
}

function is_on_vacation() {
  local date_str=$1
  local eng=$2
  local off_today="${VACATIONS[$date_str]}"
  [[ " $off_today " == *" $eng "* ]]
}

# Populates associative array $merged_on_date with logins who merged on $1
function get_mergers() {
  local date_str=$1
  for repo in "${REPOS[@]}"; do
    local prs_output
    # Query for the last N PRs on the date, because querying for each GROWTH_ENGINEER ran into GitHub API rate limiting
    if ! run_gh_capture search prs --repo "$repo" --merged-at "$date_str" --json number \
      --jq '[.[].number] | .[]' --limit "$PR_LOOKBACK_LIMIT"; then
      warn_gh_failure "failed to search merged PRs for $repo on $date_str"
      current_day_had_errors=1
      overall_had_errors=1
      continue
    fi
    prs_output="$REPLY"
    local prs=(${=prs_output})
    for pr in "${prs[@]}"; do
      [[ -n "$pr" ]] || continue
      local pr_creator
	  # get the merged PR's creator
      if ! run_gh_capture api "/repos/$repo/pulls/$pr" --jq '.user.login'; then
        warn_gh_failure "failed to fetch merged PR metadata for $repo#$pr"
        current_day_had_errors=1
        overall_had_errors=1
        continue
      fi
      pr_creator="$REPLY"
      # skip PRs from non-growth engineers
      [[ -n "${GROWTH_ENGINEER_SET[$pr_creator]}" ]] || continue
      [[ -n "$pr_creator" ]] && merged_on_date[$pr_creator]=1
    done
  done
}

# Populates associative array $reviewed_on_date with logins who reviewed on $1
# Searches PRs updated on $1 and $1+1 to catch reviews that span midnight
function get_reviewers() {
  local date_str=$1
  local next_date=$(date -j -v+1d -f "%Y-%m-%d" "$date_str" +%Y-%m-%d)
  local tmpfile=$(mktemp)
  local -A seen_prs

  for repo in "${REPOS[@]}"; do
    for search_date in "$date_str" "$next_date"; do
      local prs_output
	  # get all the PRs that were updated
      if ! run_gh_capture search prs --repo "$repo" --updated "$search_date" --json number \
        --jq '[.[].number] | .[]' --limit $PR_LOOKBACK_LIMIT; then
        warn_gh_failure "failed to search updated PRs for $repo on $search_date"
        current_day_had_errors=1
        overall_had_errors=1
        continue
      fi
      prs_output="$REPLY"
      local prs=(${=prs_output})
      for pr in "${prs[@]}"; do
        [[ -n "$pr" ]] || continue
        local key="$repo:$pr"
        if [[ -z "${seen_prs[$key]}" ]]; then
          seen_prs[$key]=1
          local pr_creator
		  # get the Creator so we don't count them as a reviewer
          if ! run_gh_capture api "/repos/$repo/pulls/$pr" --jq '.user.login'; then
            warn_gh_failure "failed to fetch PR creator for $repo#$pr"
            current_day_had_errors=1
            overall_had_errors=1
            continue
          fi
          pr_creator="$REPLY"
          [[ -n "${GROWTH_ENGINEER_SET[$pr_creator]}" ]] || continue
		  # write the names of the reviewers for the PR to a temporary file
          if ! run_gh_capture api --paginate "/repos/$repo/pulls/$pr/reviews" \
            --jq ".[] | select((.submitted_at // \"\") | startswith(\"$date_str\")) | select(.user.login != \"$pr_creator\") | .user.login"; then
            warn_gh_failure "failed to fetch reviews for $repo#$pr"
            current_day_had_errors=1
            overall_had_errors=1
          else
            print -r -- "$REPLY" >> "$tmpfile"
          fi
        fi
      done
    done
  done

  # build the list of reviewers for the day from the temp file created above
  while IFS= read -r reviewer; do
    [[ -n "$reviewer" ]] && reviewed_on_date[$reviewer]=1
  done < "$tmpfile"
  rm "$tmpfile"
}

# Writes current streaks to cache file
function save_cache() {
  (( USE_CACHE )) || return

  local merge_json="{"
  local review_json="{"
  local first=1
  for eng in "${GROWTH_ENGINEERS[@]}"; do
    (( first )) || { merge_json+=","; review_json+="," }
    merge_json+="\"$eng\":${merge_streak[$eng]}"
    review_json+="\"$eng\":${review_streak[$eng]}"
    first=0
  done
  merge_json+="}"
  review_json+="}"

  echo "{\"last_checked\":\"$PREVIOUS_WORK_DAY\",\"merge_streaks\":$merge_json,\"review_streaks\":$review_json}" \
    | jq '.' > "$CACHE_FILE"
  echo "Cache saved."
}

# ── Load cache ─────────────────────────────────────────────────────────────────

declare -A merge_streak
declare -A review_streak
engineers_count=0

if (( ! USE_CACHE )); then
  last_checked=""
  for eng in "${GROWTH_ENGINEERS[@]}"; do
    merge_streak[$eng]=0
    review_streak[$eng]=0
  done
  echo "Cache disabled (--no-cache), starting fresh"
elif [[ -f "$CACHE_FILE" ]]; then
  last_checked=$(jq -r '.last_checked' "$CACHE_FILE")
  for eng in "${GROWTH_ENGINEERS[@]}"; do
    merge_streak[$eng]=$(jq -r --arg e "$eng" '.merge_streaks[$e] // 0' "$CACHE_FILE")
    review_streak[$eng]=$(jq -r --arg e "$eng" '.review_streaks[$e] // 0' "$CACHE_FILE")
  done
  echo "Cache loaded (last checked: $last_checked)"
else
  last_checked=""
  for eng in "${GROWTH_ENGINEERS[@]}"; do
    merge_streak[$eng]=0
    review_streak[$eng]=0
  done
  echo "No cache found, starting fresh"
fi

# ── Check dates ────────────────────────────────────────────────────────────────

if [[ "$last_checked" == "$PREVIOUS_WORK_DAY" ]]; then
  echo "Already up to date."
else
  if [[ -z "$last_checked" ]]; then
    start_epoch=$(date -j -f "%Y-%m-%d" "$PREVIOUS_WORK_DAY" +%s)
  else
    start_epoch=$(( $(date -j -f "%Y-%m-%d" "$last_checked" +%s) + 86400 ))
  fi
  previous_work_day_epoch=$(date -j -f "%Y-%m-%d" "$PREVIOUS_WORK_DAY" +%s)

  current_epoch=$start_epoch
  while (( current_epoch <= previous_work_day_epoch )); do
    date_str=$(date -j -r $current_epoch +%Y-%m-%d)
    day_of_week=$(date -j -r $current_epoch +%u)
    (( current_epoch += 86400 ))

    (( day_of_week >= 6 )) && continue

    echo "Checking for activity on $date_str..."
    current_day_had_errors=0

    declare -A merged_on_date
    get_mergers "$date_str"

    declare -A reviewed_on_date
    get_reviewers "$date_str"

    if (( current_day_had_errors )); then
      echo "Skipping streak update for $date_str due to incomplete GitHub data."
      unset merged_on_date reviewed_on_date
      continue
    fi

    for eng in "${GROWTH_ENGINEERS[@]}"; do
      if [[ -n "${merged_on_date[$eng]}" ]]; then
        (( merge_streak[$eng]++ ))
      elif is_on_vacation "$date_str" "$eng"; then
		echo "$eng is on vacation on $date_str - freezing their merge streak"
      else
        merge_streak[$eng]=0
      fi

      if [[ -n "${reviewed_on_date[$eng]}" ]]; then
        (( review_streak[$eng]++ ))
      elif is_on_vacation "$date_str" "$eng"; then
		echo "$eng is on vacation on $date_str - freezing their review streak"
      else
        review_streak[$eng]=0
      fi
    done

    unset merged_on_date reviewed_on_date
  done

  if (( overall_had_errors )); then
    echo "Run completed with GitHub query errors; cache not updated."
    echo "Re-run the script after connectivity/auth issues are resolved."
  else
    if (( USE_CACHE )); then
      save_cache
    else
      echo "Cache disabled (--no-cache), not writing cache."
    fi
  fi
fi

# ── Print results ──────────────────────────────────────────────────────────────

echo "\nMerge streaks (work days in a row) as of $PREVIOUS_WORK_DAY:"
merge_streak_lines=()
engineers_count=0
while read count eng; do
  (( count > 0 )) || continue
  line="• $eng — $count day(s) 🔥"
  merge_streak_lines+=("$line")
  echo "$line"
  (( engineers_count++ ))
done < <(
  for eng in "${GROWTH_ENGINEERS[@]}"; do
    echo "${merge_streak[$eng]} $eng"
  done | sort -k1,1nr
)
merge_engineers_count=$engineers_count
echo "$engineers_count Growth Engineers merged a PR yesterday"

echo "\nReview streaks (work days in a row) as of $PREVIOUS_WORK_DAY:"
engineers_count=0
review_streak_lines=()
while read count eng; do
  (( count > 0 )) || continue
  line="• $eng — $count day(s) 🔥"
  review_streak_lines+=("$line")
  echo "$line"
  (( engineers_count++ ))
done < <(
  for eng in "${GROWTH_ENGINEERS[@]}"; do
    echo "${review_streak[$eng]} $eng"
  done | sort -k1,1nr
)
review_engineers_count=$engineers_count
echo "$engineers_count reviewers yesterday!"

slack_message="🏆 _Growth Leaderboards_"$'\n\n'

slack_message+="🔀 _Merge Streaks:_"$'\n'
if (( ${#merge_streak_lines[@]} == 0 )); then
  slack_message+="_(none — 0 engineers merged a PR yesterday)_"$'\n'
else
  slack_message+="${(j:\n:)merge_streak_lines}"$'\n'
  slack_message+="_${merge_engineers_count} Growth Engineers merged a PR yesterday_"$'\n'
fi

slack_message+=$'⠀\n'

slack_message+="👀 _Review Streaks:_"$'\n'
if (( ${#review_streak_lines[@]} == 0 )); then
  slack_message+="_(none — 0 engineers reviewed yesterday)_"$'\n'
else
  slack_message+="${(j:\n:)review_streak_lines}"$'\n'
  slack_message+="_${review_engineers_count} engineers reviewed yesterday!_ 🎉"
fi

post_to_slack "$slack_message"

if (( PRINT_SLACK_MESSAGE )); then
  echo "$slack_message"
fi
