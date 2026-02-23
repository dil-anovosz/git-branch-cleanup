#!/usr/bin/env bash
set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
MODE="dry-run"
FORCE=false

for arg in "$@"; do
  case "$arg" in
    --execute) MODE="execute" ;;
    --dry-run)  MODE="dry-run" ;;
    --force)    FORCE=true ;;
    --help|-h)
      echo "Usage: $0 [--dry-run|--execute] [--force]"
      echo ""
      echo "  --dry-run   Show what would be deleted without doing it (default)"
      echo "  --execute   Actually delete the branches"
      echo "  --force     Also delete branches with no PR (prompts per branch)"
      exit 0
      ;;
    *)
      echo "Unknown flag: $arg" >&2
      echo "Run $0 --help for usage." >&2
      exit 1
      ;;
  esac
done

# ─── Color helpers ───────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { printf "${CYAN}[INFO]${RESET}  %s\n" "$*"; }
ok()      { printf "${GREEN}[OK]${RESET}    %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${RESET}  %s\n" "$*"; }
skip()    { printf "${YELLOW}[SKIP]${RESET}  %s\n" "$*"; }
err()     { printf "${RED}[ERR]${RESET}   %s\n" "$*" >&2; }
action()  { printf "${BOLD}[DEL]${RESET}   %s\n" "$*"; }
dry()     { printf "${BOLD}[DRY]${RESET}   %s\n" "$*"; }

# ─── Counters ────────────────────────────────────────────────────────────────
deleted_local=0
deleted_remote=0
declare -a kept_branches=()

track_kept() {
  # $1 = branch name, $2 = reason
  kept_branches+=("$1 ($2)")
}

# ─── Step 1: Preparation ────────────────────────────────────────────────────
echo ""
printf "${BOLD}══════ Branch Cleanup (mode: %s) ══════${RESET}\n" "$MODE"
echo ""

info "Fetching and pruning remote tracking branches..."
git fetch --prune origin

current_branch=$(git symbolic-ref --short HEAD)
if [[ "$current_branch" != "main" ]]; then
  err "You must be on the 'main' branch. Currently on '$current_branch'."
  exit 1
fi

info "Pulling latest main..."
git pull --ff-only origin main

# Build list of user emails for author filtering
user_email=$(git config user.email)
declare -a user_emails=("$user_email")
# Derive GitHub noreply email via gh CLI (ID+username@users.noreply.github.com)
if [[ "$user_email" != *"noreply.github.com"* ]] && command -v gh &>/dev/null; then
  gh_user_json=$(gh api user --jq '.login,.id' 2>/dev/null || true)
  if [[ -n "$gh_user_json" ]]; then
    gh_login=$(echo "$gh_user_json" | sed -n '1p')
    gh_id=$(echo "$gh_user_json" | sed -n '2p')
    if [[ -n "$gh_login" && -n "$gh_id" ]]; then
      user_emails+=("${gh_id}+${gh_login}@users.noreply.github.com")
    fi
  fi
fi

info "User emails for author filter: ${user_emails[*]}"
echo ""

author_matches() {
  local email="$1"
  for ue in "${user_emails[@]}"; do
    if [[ "$email" == "$ue" ]]; then
      return 0
    fi
  done
  return 1
}

# ─── Step 2: Delete merged local branches ────────────────────────────────────
printf "${BOLD}── Step 2: Merged local branches ──${RESET}\n"

merged_local=$(git branch --merged main | sed 's/^[* ]*//' | grep -v '^main$' || true)

if [[ -z "$merged_local" ]]; then
  info "No merged local branches to delete."
else
  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    if [[ "$MODE" == "execute" ]]; then
      action "Deleting local branch: $branch"
      git branch -d "$branch"
    else
      dry "Would delete local branch: $branch"
    fi
    deleted_local=$((deleted_local + 1))
  done <<< "$merged_local"
fi
echo ""

# ─── Step 3: Delete merged remote branches (author-filtered) ────────────────
printf "${BOLD}── Step 3: Merged remote branches ──${RESET}\n"

merged_remote=$(git branch -r --merged main | sed 's/^[* ]*//' | grep -v 'origin/main' | grep -v 'origin/HEAD' | grep '^origin/' || true)

if [[ -z "$merged_remote" ]]; then
  info "No merged remote branches to delete."
else
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    branch="${ref#origin/}"
    # Check author of last commit
    last_author=$(git log -1 --format='%ae' "$ref" 2>/dev/null || echo "unknown")
    if ! author_matches "$last_author"; then
      skip "Remote branch '$branch' — last author is '$last_author' (not you)"
      track_kept "origin/$branch" "different author: $last_author"
      continue
    fi
    if [[ "$MODE" == "execute" ]]; then
      action "Deleting remote branch: $branch"
      git push origin --delete "$branch"
    else
      dry "Would delete remote branch: $branch"
    fi
    deleted_remote=$((deleted_remote + 1))
  done <<< "$merged_remote"
fi
echo ""

# ─── Step 4: Handle unmerged branches (squash-merge detection) ───────────────
printf "${BOLD}── Step 4: Unmerged branches (PR lookup) ──${RESET}\n"

# Check if gh CLI is available
if ! command -v gh &>/dev/null; then
  err "'gh' CLI not found. Skipping squash-merge detection for unmerged branches."
  echo ""
else
  # 4a: Unmerged local branches
  all_local=$(git branch | sed 's/^[* ]*//' | grep -v '^main$' || true)
  unmerged_local=""
  if [[ -n "$all_local" ]]; then
    while IFS= read -r branch; do
      [[ -z "$branch" ]] && continue
      if ! echo "$merged_local" | grep -qxF "$branch"; then
        unmerged_local+="$branch"$'\n'
      fi
    done <<< "$all_local"
  fi

  if [[ -n "$unmerged_local" ]]; then
    info "Checking unmerged local branches against GitHub PRs..."
    while IFS= read -r branch; do
      [[ -z "$branch" ]] && continue
      pr_json=$(gh pr list --state all --head "$branch" --json state,mergedAt --limit 1 2>/dev/null || echo "[]")
      pr_state=$(echo "$pr_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['state'] if d else 'NONE')" 2>/dev/null || echo "NONE")

      case "$pr_state" in
        MERGED)
          if [[ "$MODE" == "execute" ]]; then
            action "Deleting local branch (squash-merged PR): $branch"
            git branch -D "$branch"
          else
            dry "Would delete local branch (squash-merged PR): $branch"
          fi
          deleted_local=$((deleted_local + 1))
          ;;
        OPEN)
          skip "Local branch '$branch' has an OPEN PR — keeping"
          track_kept "$branch" "open PR"
          ;;
        CLOSED)
          if [[ "$MODE" == "execute" ]]; then
            action "Deleting local branch (closed/abandoned PR): $branch"
            git branch -D "$branch"
          else
            dry "Would delete local branch (closed/abandoned PR): $branch"
          fi
          deleted_local=$((deleted_local + 1))
          ;;
        NONE)
          if [[ "$FORCE" == true ]]; then
            if [[ "$MODE" == "execute" ]]; then
              printf "${YELLOW}Branch '%s' has no PR. Delete? [y/N]: ${RESET}" "$branch"
              read -r confirm
              if [[ "$confirm" =~ ^[Yy]$ ]]; then
                action "Deleting local branch (no PR, forced): $branch"
                git branch -D "$branch"
                deleted_local=$((deleted_local + 1))
              else
                skip "Kept local branch '$branch' (user declined)"
                track_kept "$branch" "no PR — user declined"
              fi
            else
              dry "Would prompt to delete local branch (no PR): $branch"
              deleted_local=$((deleted_local + 1))
            fi
          else
            warn "Local branch '$branch' has no PR and is not merged — skipping (use --force to include)"
            track_kept "$branch" "no PR, not merged"
          fi
          ;;
      esac
    done <<< "$unmerged_local"
  else
    info "No unmerged local branches remaining."
  fi

  echo ""

  # 4b: Unmerged remote branches
  all_remote=$(git branch -r | sed 's/^[* ]*//' | grep -v 'origin/main' | grep -v 'origin/HEAD' | grep '^origin/' || true)
  unmerged_remote=""
  if [[ -n "$all_remote" ]]; then
    while IFS= read -r ref; do
      [[ -z "$ref" ]] && continue
      if ! echo "$merged_remote" | grep -qxF "$ref"; then
        unmerged_remote+="$ref"$'\n'
      fi
    done <<< "$all_remote"
  fi

  if [[ -n "$unmerged_remote" ]]; then
    info "Checking unmerged remote branches against GitHub PRs..."
    while IFS= read -r ref; do
      [[ -z "$ref" ]] && continue
      branch="${ref#origin/}"

      # Author filter
      last_author=$(git log -1 --format='%ae' "$ref" 2>/dev/null || echo "unknown")
      if ! author_matches "$last_author"; then
        skip "Remote branch '$branch' — last author is '$last_author' (not you)"
        track_kept "origin/$branch" "different author: $last_author"
        continue
      fi

      pr_json=$(gh pr list --state all --head "$branch" --json state,mergedAt --limit 1 2>/dev/null || echo "[]")
      pr_state=$(echo "$pr_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['state'] if d else 'NONE')" 2>/dev/null || echo "NONE")

      case "$pr_state" in
        MERGED)
          if [[ "$MODE" == "execute" ]]; then
            action "Deleting remote branch (squash-merged PR): $branch"
            git push origin --delete "$branch"
          else
            dry "Would delete remote branch (squash-merged PR): $branch"
          fi
          deleted_remote=$((deleted_remote + 1))
          ;;
        OPEN)
          skip "Remote branch '$branch' has an OPEN PR — keeping"
          track_kept "origin/$branch" "open PR"
          ;;
        CLOSED)
          if [[ "$MODE" == "execute" ]]; then
            action "Deleting remote branch (closed/abandoned PR): $branch"
            git push origin --delete "$branch"
          else
            dry "Would delete remote branch (closed/abandoned PR): $branch"
          fi
          deleted_remote=$((deleted_remote + 1))
          ;;
        NONE)
          if [[ "$FORCE" == true ]]; then
            if [[ "$MODE" == "execute" ]]; then
              printf "${YELLOW}Remote branch '%s' has no PR. Delete? [y/N]: ${RESET}" "$branch"
              read -r confirm
              if [[ "$confirm" =~ ^[Yy]$ ]]; then
                action "Deleting remote branch (no PR, forced): $branch"
                git push origin --delete "$branch"
                deleted_remote=$((deleted_remote + 1))
              else
                skip "Kept remote branch '$branch' (user declined)"
                track_kept "origin/$branch" "no PR — user declined"
              fi
            else
              dry "Would prompt to delete remote branch (no PR): $branch"
              deleted_remote=$((deleted_remote + 1))
            fi
          else
            warn "Remote branch '$branch' has no PR and is not merged — skipping (use --force to include)"
            track_kept "origin/$branch" "no PR, not merged"
          fi
          ;;
      esac
    done <<< "$unmerged_remote"
  else
    info "No unmerged remote branches remaining."
  fi
fi

# ─── Step 5: Summary ────────────────────────────────────────────────────────
echo ""
printf "${BOLD}══════ Summary ══════${RESET}\n"
echo ""

if [[ "$MODE" == "dry-run" ]]; then
  ok "DRY RUN — no branches were actually deleted."
  echo "  Local branches that would be deleted:  $deleted_local"
  echo "  Remote branches that would be deleted: $deleted_remote"
  echo ""
  echo "Run with --execute to perform the deletions."
else
  ok "Cleanup complete."
  echo "  Local branches deleted:  $deleted_local"
  echo "  Remote branches deleted: $deleted_remote"
fi

if [[ ${#kept_branches[@]} -gt 0 ]]; then
  echo ""
  printf "${BOLD}Branches kept:${RESET}\n"
  for entry in "${kept_branches[@]}"; do
    echo "  - $entry"
  done
fi

echo ""
