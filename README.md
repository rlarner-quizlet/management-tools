# management-tools
Tools for managing software projects

## Prerequisites

- [GitHub CLI (`gh`)](https://cli.github.com/) — installed and authenticated (`gh auth login`)

## Scripts

### `scripts/check_open_prs.sh` — List open PRs for a team

Prints every open pull request across all repositories belonging to a GitHub
team, with the PR number, author, title, age, and URL.

**Usage**

```bash
./scripts/check_open_prs.sh --org <org> --team <team-slug> [--author <username>] [--label "<label>"]
```

| Flag | Required | Description |
|------|----------|-------------|
| `--org` | ✅ | GitHub organization name |
| `--team` | ✅ | Team slug (the URL-friendly team name) |
| `--author` | | Filter PRs by a specific GitHub username |
| `--label` | | Filter PRs that have a specific label |

**Examples**

```bash
# All open PRs for the backend-team in my-org
./scripts/check_open_prs.sh --org my-org --team backend-team

# Open PRs authored by octocat
./scripts/check_open_prs.sh --org my-org --team backend-team --author octocat

# Open PRs that carry the "needs review" label
./scripts/check_open_prs.sh --org my-org --team backend-team --label "needs review"
```

**Sample output**

```
Fetching repositories for team 'backend-team' in org 'my-org'...
Found 3 repository/repositories. Checking for open PRs...

── my-org/api-service (2 open PR(s)) ──
  #42 [alice] Add rate limiting (3 days ago)
    https://github.com/my-org/api-service/pull/42
  #41 [bob] Fix null pointer in auth handler (5 days ago)
    https://github.com/my-org/api-service/pull/41

── my-org/frontend (1 open PR(s)) ──
  #18 [carol] Update dashboard layout (1 day ago)
    https://github.com/my-org/frontend/pull/18

────────────────────────────────────────
Total open PRs: 3
```
