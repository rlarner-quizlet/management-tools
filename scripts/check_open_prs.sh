#!/usr/bin/env bash
# check_open_prs.sh - List open pull requests for all repositories in a GitHub team
#
# Usage:
#   ./check_open_prs.sh --org <org> --team <team>
#   ./check_open_prs.sh --org <org> --team <team> [--author <username>] [--label <label>]
#
# Prerequisites:
#   - GitHub CLI (gh) installed and authenticated: https://cli.github.com/
#
# Examples:
#   ./check_open_prs.sh --org my-org --team backend-team
#   ./check_open_prs.sh --org my-org --team backend-team --author octocat
#   ./check_open_prs.sh --org my-org --team backend-team --label "needs review"

set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
ORG=""
TEAM=""
AUTHOR=""
LABEL=""

# ── Helpers ─────────────────────────────────────────────────────────────────
usage() {
  # Print the leading comment block (lines 2-14) at the top of this file
  sed -n '2,/^[^#]/{ /^#/{ s/^# \{0,1\}//; p } }' "$0"
  exit 1
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."
}

# ── Argument parsing ─────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --org)    ORG="$2";    shift 2 ;;
    --team)   TEAM="$2";   shift 2 ;;
    --author) AUTHOR="$2"; shift 2 ;;
    --label)  LABEL="$2";  shift 2 ;;
    -h|--help) usage ;;
    *) die "Unknown option: $1" ;;
  esac
done

[[ -n "$ORG"  ]] || die "--org is required"
[[ -n "$TEAM" ]] || die "--team is required"

require_cmd gh

# ── Fetch team repositories ──────────────────────────────────────────────────
echo "Fetching repositories for team '${TEAM}' in org '${ORG}'..."

mapfile -t REPOS < <(
  gh api \
    --paginate \
    "/orgs/${ORG}/teams/${TEAM}/repos" \
    --jq '.[].name' 2>/dev/null
)

if [[ ${#REPOS[@]} -eq 0 ]]; then
  die "No repositories found for team '${TEAM}' in org '${ORG}'. " \
      "Check that the team slug and org name are correct and that you have access."
fi

echo "Found ${#REPOS[@]} repositories. Checking for open PRs..."
echo ""

# ── Build optional gh pr list flags ─────────────────────────────────────────
EXTRA_FLAGS=()
[[ -n "$AUTHOR" ]] && EXTRA_FLAGS+=("--author" "$AUTHOR")
[[ -n "$LABEL"  ]] && EXTRA_FLAGS+=("--label"  "$LABEL")

# ── Iterate repositories and list open PRs ───────────────────────────────────
TOTAL=0

for REPO in "${REPOS[@]}"; do
  PR_OUTPUT=$(
    gh pr list \
      --repo "${ORG}/${REPO}" \
      --state open \
      --json number,title,author,createdAt,url \
      --template \
        '{{range .}}  #{{.number}} [{{.author.login}}] {{.title}} ({{timeago .createdAt}})
    {{.url}}
{{end}}' \
      "${EXTRA_FLAGS[@]}" 2>/dev/null
  ) || {
    echo "  [skipped – insufficient access]"
    continue
  }

  COUNT=$(
    gh pr list \
      --repo "${ORG}/${REPO}" \
      --state open \
      --json number \
      --jq 'length' \
      "${EXTRA_FLAGS[@]}" 2>/dev/null
  ) || COUNT=0

  if [[ "$COUNT" -gt 0 ]]; then
    echo "── ${ORG}/${REPO} (${COUNT} open PR(s)) ──"
    echo "$PR_OUTPUT"
    TOTAL=$((TOTAL + COUNT))
  fi
done

echo "────────────────────────────────────────"
echo "Total open PRs: ${TOTAL}"
