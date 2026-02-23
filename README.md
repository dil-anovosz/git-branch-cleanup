# git-branch-cleanup

A shell script that safely identifies and deletes stale Git branches — both local and remote — while preserving branches with active work.

## Features

- **Safe by default** — runs in dry-run mode unless you explicitly pass `--execute`
- **Squash-merge detection** — uses the GitHub CLI to detect branches whose PRs were squash-merged (not visible to `git branch --merged`)
- **Author-filtered remote deletion** — only deletes remote branches where you are the last commit author, preventing accidental deletion of others' branches
- **Automatic email discovery** — detects both your Git email and your GitHub noreply email via `gh api`
- **Open PR protection** — never deletes branches with open pull requests
- **Interactive force mode** — with `--force`, prompts per-branch for unmerged branches that have no PR

## Requirements

- **Git** (any recent version)
- **[GitHub CLI (`gh`)](https://cli.github.com/)** — authenticated and with access to the repository. Required for squash-merge detection and noreply email discovery. The script still works without `gh`, but will skip Step 4 (unmerged branch PR lookups).
- **Python 3** — used for lightweight JSON parsing of `gh` output
- **Bash 4+** — uses associative features like `declare -a`

## Installation

### Option A: Shell alias (recommended)

Add this function to your `~/.zshrc` (or `~/.bashrc`):

```bash
git-cleanup() {
  bash <(curl -fsSL https://raw.githubusercontent.com/dil-anovosz/git-branch-cleanup/main/cleanup-branches.sh) "$@"
}
```

Then reload your shell:

```bash
source ~/.zshrc
```

This lets you run `git-cleanup` from any Git repository without cloning or copying anything. The script is fetched directly from GitHub each time, so updates take effect immediately.

### Option B: Clone and copy

Clone this repository:

```bash
git clone https://github.com/dil-anovosz/git-branch-cleanup.git
```

Copy the script into any Git repository where you want to clean up branches:

```bash
cp git-branch-cleanup/cleanup-branches.sh /path/to/your/repo/
chmod +x /path/to/your/repo/cleanup-branches.sh
```

## Quick Start

```bash
# Using the alias (Option A):
cd /path/to/your/repo
git-cleanup                # dry-run (default)
git-cleanup --execute      # actually delete branches

# Using the local script (Option B):
cd /path/to/your/repo
./cleanup-branches.sh
./cleanup-branches.sh --execute
```

## Usage

```
./cleanup-branches.sh [--dry-run|--execute] [--force]
```

### Flags

| Flag | Description |
|---|---|
| `--dry-run` | Show what would be deleted without actually deleting anything. **This is the default.** |
| `--execute` | Perform the actual deletions. |
| `--force` | Include branches that have no associated PR and are not merged. In execute mode, prompts for confirmation per branch. |
| `--help`, `-h` | Print usage information and exit. |

### Examples

```bash
# Dry run (default) — safe to run anytime
./cleanup-branches.sh

# Actually delete the branches
./cleanup-branches.sh --execute

# Include orphaned branches (no PR) with per-branch confirmation
./cleanup-branches.sh --execute --force

# Preview what --force would do
./cleanup-branches.sh --dry-run --force
```

## How It Works

The script runs through five steps:

### Step 1 — Preparation

- Runs `git fetch --prune origin` to sync remote tracking state and remove stale references
- Verifies you are on the `main` branch and pulls the latest changes
- Detects your email addresses:
  - Your local Git email from `git config user.email`
  - Your GitHub noreply email, derived via `gh api user` (format: `<id>+<username>@users.noreply.github.com`)

### Step 2 — Delete merged local branches

Finds all local branches fully merged into `main` using `git branch --merged main`, excluding `main` itself. Deletes each with `git branch -d`.

### Step 3 — Delete merged remote branches

Finds all remote branches merged into `main` using `git branch -r --merged main`. For each branch:
- Checks the last commit's author email
- **Only deletes if the author matches your identity** (Git email or GitHub noreply email)
- Skips and reports branches belonging to other authors

### Step 4 — Handle unmerged branches (squash-merge detection)

For branches **not** detected as merged by Git (common with squash-merge workflows):
- Queries GitHub via `gh pr list` to find the associated PR
- **MERGED PR** → safe to delete (the branch was squash-merged)
- **OPEN PR** → skip (active work)
- **CLOSED PR** → delete (abandoned)
- **No PR found** → skip unless `--force` is passed, then prompt for confirmation

The same author filter from Step 3 applies to remote branches in this step.

### Step 5 — Summary report

Prints:
- Count of deleted local and remote branches
- List of branches that were kept, with the reason (open PR, no PR, different author)

## Safety Guarantees

| Scenario | Behavior |
|---|---|
| Branch has an open PR | **Never deleted** |
| Branch has no PR and is not merged | **Skipped** unless `--force` is passed |
| Remote branch authored by someone else | **Skipped** (author filter) |
| Script run without `--execute` | **Nothing is deleted** (dry-run) |
| Not on `main` branch | **Script exits** with an error |
| `gh` CLI not available | Steps 1-3 still work; Step 4 is skipped with a warning |

## Output Legend

| Prefix | Meaning |
|---|---|
| `[DRY]` | Would be deleted (dry-run mode) |
| `[DEL]` | Actually deleted (execute mode) |
| `[SKIP]` | Kept intentionally (open PR, different author) |
| `[WARN]` | Kept because no PR was found — review manually |
| `[INFO]` | Informational status message |
| `[OK]` | Summary / success message |
| `[ERR]` | Error — script may exit |

## Limitations

- The script must be run from a Git repository with an `origin` remote
- Squash-merge detection requires `gh` to be authenticated with access to the repository
- The author filter uses the **last commit** on the branch — if someone else force-pushed over your branch, it may be skipped
- Branch-to-PR matching uses `gh pr list --head <branch>`, which relies on the branch name matching exactly

## License

MIT
