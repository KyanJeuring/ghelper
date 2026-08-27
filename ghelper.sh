#!/usr/bin/env bash

if ((BASH_VERSINFO[0] < 4)); then
  echo "GHelper requires Bash 4 or newer."
  exit 1
fi

# When sourced (common for shell helpers), do not change global shell options.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  IFS=$'\n\t'
fi

GHELPER_VERSION="v1.7.0"

# ==================================================
# Configuration
# ==================================================

### Default git host used by gclone for SSH and HTTPS URLs (internal)
GHELPER_SSH_HOST="${GHELPER_SSH_HOST:-github.com}"

### Space-separated list of branches protected from accidental history rewrites (internal)
GHELPER_PROTECTED_BRANCHES="${GHELPER_PROTECTED_BRANCHES:-main master}"

# ==================================================
# Logging and confirmation helpers (internal)
# ==================================================

### Basic logging function (internal)
log() {
  printf '%b\n' "$*"
}

_log_emit() {
  local level="$1"
  shift

  local prefix
  if [[ -t 1 ]]; then
    case "$level" in
      INFO)  prefix='\033[0;34m\033[1m[INFO]\033[0m' ;;
      OK)    prefix='\033[0;32m\033[1m[OK]\033[0m' ;;
      WARN)  prefix='\033[0;33m\033[1m[WARN]\033[0m' ;;
      ERROR) prefix='\033[0;31m\033[1m[ERROR]\033[0m' ;;
      *)     prefix="[$level]" ;;
    esac
  else
    prefix="[$level]"
  fi

  log "$prefix $*"
}

info() { _log_emit INFO "$@"; }
ok()   { _log_emit OK "$@"; }
warn() { _log_emit WARN "$@"; }
err()  { _log_emit ERROR "$@"; }

### Confirmation prompt (internal)
confirm() {
  read -rp "$1 [y/n]: " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

# ==================================================
# Git safety helpers (internal)
# ==================================================

### List of deprecated functions
DEPRECATED_FUNCTIONS=(
  gdiffs
  gdiffc
  gdiffp
  gdiffb
  gdiffpromote
  whatwillpromote
)

### Remove deprecated functions automatically
for fn in "${DEPRECATED_FUNCTIONS[@]}"; do
  if declare -F "$fn" >/dev/null; then
    warn "'$fn' is deprecated and has been removed"
    unset -f "$fn"
  fi
done

### safety check before rewriting main history (internal)
_guard_main_rewrite() {
  local branch upstream commit_hash commit_msg
  local protected

  branch=$(git branch --show-current 2>/dev/null) || return 1
  upstream=$(git rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>/dev/null) || true

  commit_hash=$(git rev-parse --short HEAD 2>/dev/null) || return 1
  commit_msg=$(git log -1 --pretty=%s 2>/dev/null) || return 1

  local is_protected=0
  for protected in $GHELPER_PROTECTED_BRANCHES; do
    [[ "$branch" == "$protected" ]] && { is_protected=1; break; }
  done

  [[ "$is_protected" -eq 0 ]] && return 0

  local branch_upper="${branch^^}"
  warn "You are on ${branch_upper} and about to rewrite history"
  [[ -n "$upstream" ]] && warn "Upstream: $upstream"

  if [[ -n "$upstream" && "$upstream" != */"$branch" ]]; then
    warn "NOTE: upstream does not look like ${branch} (it is '$upstream')"
  fi

  warn "Commit to be removed: $commit_hash  $commit_msg"
  warn "This affects everyone pulling from ${branch}."
  log

  read -rp "Type '${branch_upper} $commit_hash' to continue: " ans
  [[ "$ans" == "${branch_upper} $commit_hash" ]]
}

### safety check before force-pushing (internal)
_abort_reset() {
  git rev-parse ORIG_HEAD >/dev/null 2>&1 || {
    err "No reset to abort"
    return 1
  }

  git reset --hard ORIG_HEAD &&
  ok "Operation aborted"
}

### Check if a branch exists locally or remotely (internal)
_branch_exists() {
  git show-ref --verify --quiet "refs/heads/$1" ||
  git show-ref --verify --quiet "refs/remotes/origin/$1"
}

### Get a writable temporary directory (internal)
_tmp_dir() {
  printf '%s' "${TMPDIR:-${TEMP:-${TMP:-/tmp}}}"
}

# ==================================================
# GHelper command listing
# ==================================================

## List available GHelper commands with descriptions
ghelp() {
  info "GHelper commands"
  log

  local GHELPER_ROOT
  GHELPER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

  shopt -s nullglob
  local files=(
    "${BASH_SOURCE[0]}"
    "$GHELPER_ROOT"/commands/*.sh
  )
  shopt -u nullglob

  ((${#files[@]})) || {
    warn "No ghelper command files found"
    return
  }

  awk '
    # Detect separator lines
    /^# [=]{5,}$/ {
      prev_sep = 1
      next
    }

    # Section title must be BETWEEN separators
    prev_sep && /^# / {
      section = substr($0, 3)
      prev_sep = 0
      in_section = 1
      next
    }

    # Anything else cancels separator expectation
    {
      prev_sep = 0
    }

    # Documented public commands
    /^## / && in_section {
      desc = substr($0, 4)
      while (getline > 0) {
        if ($0 ~ /^[[:space:]]*$/) continue
        if ($0 ~ /^[[:space:]]*# shellcheck/) continue
        break
      }

      if ($0 ~ /^[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*\(\)/) {
        name = $0
        sub(/^[[:space:]]*/, "", name)
        sub(/\(\).*/, "", name)

        # Ignore internal helpers
        if (name ~ /^_/) next

        printf "[%s]\n%-22s %s\n", section, name, desc
      }
    }
  ' "${files[@]}" |
  awk '
    /^\[/ {
      if ($0 != last) {
        if (NR > 1) print ""
        print $0
        last = $0
      }
      next
    }
    { print "  " $0 }
  '
}

## Show GHelper version
gversion() {
  echo "GHelper $GHELPER_VERSION"
}

# ==================================================
# Git helpers
# ==================================================

## Go to git repository root
groot() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  groot

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  groot         # cd to the root of the current git repository
EOF
    return 0
  fi

  local r
  r=$(git rev-parse --show-toplevel 2>/dev/null) || {
    err "Not inside a git repository"
    return 1
  }
  cd "$r" || return 1
}

## Clone a repository, auto-detecting SSH or HTTPS
gclone() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gclone <repo> [username] [host] [-t <target-dir>] [--https]

OPTIONS:
  -t, --target <dir>    Clone into a specific directory (default: repo name)
  --https               Force HTTPS instead of SSH
  -h, --help            Show this help message

EXAMPLES:
  gclone my-repo                        # Clone <detected-user>/my-repo via SSH
  gclone my-repo other-user             # Clone other-user/my-repo via SSH
  gclone my-repo github.com             # Clone from GitHub with detected user
  gclone my-repo gitlab.com             # Clone from GitLab with detected user
  gclone my-repo other-user github.com  # Clone from GitHub with explicit user
  gclone my-repo other-user gitlab.com  # Clone from GitLab with explicit user
  gclone my-repo --https                # Clone via HTTPS (no SSH key needed)
  gclone my-repo -t /tmp/mydir          # Clone into a specific directory

NOTES:
  - Username is detected from Git config based on the selected host (GitHub, GitLab, etc.)
  - Host defaults to github.com, or $GHELPER_SSH_HOST if set
  - SSH is tried first; if it fails, HTTPS is offered as a fallback
  - Use --https to skip SSH entirely
EOF
    return 0
  fi

  local repo user host target
  local use_https=0
  local args=()

  host="${GHELPER_SSH_HOST:-github.com}"
  target=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -t|--target)
        [[ -n "${2:-}" ]] || { err "Missing argument for $1"; return 1; }
        target="$2"
        shift 2
        ;;
      --https)
        use_https=1
        shift
        ;;
      -*)
        err "Unknown option: $1"
        return 1
        ;;
      *)
        args+=("$1")
        shift
        ;;
    esac
  done

  case "${#args[@]}" in
    1)
      repo="${args[0]}"
      ;;
    2)
      repo="${args[0]}"
      if [[ "${args[1]}" == *.* ]]; then
        host="${args[1]}"
      else
        user="${args[1]}"
      fi
      ;;
    3)
      repo="${args[0]}"
      user="${args[1]}"
      host="${args[2]}"
      ;;
    *)
      err "Usage: gclone <repo> [username] [host] [-t <target-dir>] [--https]"
      return 1
      ;;
  esac

  if [[ -z "$user" ]]; then
    case "$host" in
      github.com|*.github.com)
        user="$(git config --global --get github.user 2>/dev/null || echo "")"
        ;;
      gitlab.com|*.gitlab.com)
        user="$(git config --global --get gitlab.user 2>/dev/null || echo "")"
        ;;
    esac

    if [[ -z "$user" ]]; then
      user="$(git config --global --get user.name 2>/dev/null || echo "")"
    fi
  fi

  if [[ -z "$user" || ! "$user" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    err "Could not determine a valid username for $host"

    local fallback_name
    fallback_name="$(git config --global --get user.name 2>/dev/null || echo "")"

    if [[ -n "$fallback_name" ]]; then
      err "Fallback to user.name ('$fallback_name') failed (not a valid username)"
    else
      err "No fallback available from user.name"
    fi

    log
    info "Set your username with one of:"
    info "  git config --global github.user <username>"
    info "  git config --global gitlab.user <username>"
    info "Or ensure your git config 'user.name' is a valid username"
    log
    info "Or pass it explicitly:"
    info "  gclone <repo> <username> [host]"

    return 1
  fi

  target="${target:-$repo}"

  [[ "$repo" =~ ^[a-zA-Z0-9._-]+$ ]] || { err "Invalid repository name: '$repo'"; return 1; }
  [[ "$user" =~ ^[a-zA-Z0-9._-]+$ ]] || { err "Invalid username: '$user'"; return 1; }
  [[ "$host" =~ ^[a-zA-Z0-9._-]+$ ]] || { err "Invalid host: '$host'"; return 1; }

  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    err "Cannot clone inside an existing Git repository"
    return 1
  fi

  if [[ -e "$target" ]]; then
    err "Target directory already exists: $target"
    return 1
  fi

  local ssh_url="git@$host:$user/$repo.git"
  local https_url="https://$host/$user/$repo.git"

  if (( use_https )); then
    info "Cloning $user/$repo via HTTPS"
    if git clone "$https_url" "$target"; then
      ok "Clone complete -> $target"
    else
      err "Clone failed"
      return 1
    fi
    return 0
  fi

  info "Checking SSH access for $user/$repo"
  local ssh_check_err
  ssh_check_err="$(git ls-remote "$ssh_url" 2>&1 >/dev/null || true)"

  if [[ -z "$ssh_check_err" ]]; then
    info "Cloning $user/$repo via SSH ($host)"
    if git clone "$ssh_url" "$target"; then
      ok "Clone complete -> $target"
    else
      err "Clone failed"
      return 1
    fi
    return 0
  fi

  local ssh_check_err_lower
  ssh_check_err_lower="$(printf '%s' "$ssh_check_err" | tr '[:upper:]' '[:lower:]')"

  if [[ "$ssh_check_err_lower" == *"repository not found"* \
    || "$ssh_check_err_lower" == *"project not found"* \
    || "$ssh_check_err_lower" == *"could not be found"* \
    || "$ssh_check_err_lower" == *"does not exist"* \
    || "$ssh_check_err_lower" == *"access denied"* \
    || "$ssh_check_err_lower" == *"don't have permission"* \
    || "$ssh_check_err_lower" == *"do not have permission"* ]]; then
    err "Repository not found or access denied: $user/$repo on $host"
    err "Check that the repository name, username, host, and access rights are correct"
    return 1
  fi

  local https_check_err
  https_check_err="$(git ls-remote "$https_url" 2>&1 >/dev/null || true)"

  local https_check_err_lower
  https_check_err_lower="$(printf '%s' "$https_check_err" | tr '[:upper:]' '[:lower:]')"

  if [[ "$https_check_err_lower" == *"repository not found"* \
    || "$https_check_err_lower" == *"project not found"* \
    || "$https_check_err_lower" == *"could not be found"* \
    || "$https_check_err_lower" == *"not found"* \
    || "$https_check_err_lower" == *"does not exist"* \
    || "$https_check_err_lower" == *"access denied"* \
    || "$https_check_err_lower" == *"authentication failed"* \
    || "$https_check_err_lower" == *"unauthorized"* \
    || "$https_check_err_lower" == *"forbidden"* ]]; then
    err "Repository not found or access denied: $user/$repo on $host"
    err "Check that the repository name, username, host, and access rights are correct"
    return 1
  fi

  warn "SSH access failed for $ssh_url"
  warn "This can happen if SSH is not configured or access is not available for $host"
  log
  info "Falling back to HTTPS: $https_url"
  read -rp "Clone via HTTPS instead? [y/n]: " ans
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    info "Cloning $user/$repo via HTTPS"
    if git clone "$https_url" "$target"; then
      ok "Clone complete -> $target"
    else
      err "Clone failed"
      return 1
    fi
  else
    err "Clone aborted"
    err "To set up SSH keys, visit: https://$host/settings/keys"
    return 1
  fi
}

# ==================================================
# Git repo templating
# ==================================================

## Add .gitignore from GHelper template
create-gitignore() {
  local GHELPER_ROOT
  GHELPER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  local template="$GHELPER_ROOT/templates/.gitignore"

  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<EOF
USAGE:
  create-gitignore

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  create-gitignore      # Copy .gitignore template into the current repository root

NOTES:
  - Requires a user-provided template at:
      $template
  - GHelper does not install template files automatically
  - Create the templates directory and add your own .gitignore template before using this command
  - Will not overwrite an existing .gitignore
EOF
    return 0
  fi

  groot "$@" || return 1

  if [[ -f .gitignore ]]; then
    warn ".gitignore already exists in repo root"
    return 1
  fi

  [[ -f "$template" ]] || {
    err "Template not found: $template"
    info "GHelper does not install template files automatically"
    info "Create your own template at:"
    info "  $template"
    return 1
  }

  cp "$template" .gitignore && ok ".gitignore added to repository"
}

## Add .gitattributes from GHelper template
create-gitattributes() {
  local GHELPER_ROOT
  GHELPER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  local template="$GHELPER_ROOT/templates/.gitattributes"

  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<EOF
USAGE:
  create-gitattributes

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  create-gitattributes      # Copy .gitattributes template into the current repository root

NOTES:
  - Requires a user-provided template at:
      $template
  - GHelper does not install template files automatically
  - Create the templates directory and add your own .gitattributes template before using this command
  - Will not overwrite an existing .gitattributes
EOF
    return 0
  fi

  groot "$@" || return 1

  if [[ -f .gitattributes ]]; then
    warn ".gitattributes already exists in repo root"
    return 1
  fi

  [[ -f "$template" ]] || {
    err "Template not found: $template"
    info "GHelper does not install template files automatically"
    info "Create your own template at:"
    info "  $template"
    return 1
  }

  cp "$template" .gitattributes && ok ".gitattributes added to repository"
}

## Apply all templates from GHelper to current repo
gtemplate() {
  local GHELPER_ROOT
  GHELPER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
  local template_dir="$GHELPER_ROOT/templates"

  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<EOF
USAGE:
  gtemplate

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  gtemplate     # Apply all templates to the current repository

NOTES:
  - Applies all user-provided templates from:
      $template_dir
  - GHelper does not install template files automatically
  - Create the templates directory and add your own template files before using this command
  - Prompts before overwriting existing files
  - Initializes a git repo if not already inside one
EOF
    return 0
  fi

  local applied=0 skipped=0 overwritten=0 failed=0
  local reply name target template
  local old_nullglob repo_root

  [[ -d "$template_dir" ]] || {
    err "Template directory not found: $template_dir"
    info "GHelper does not install template files automatically"
    info "Create the directory and add your own templates:"
    info "  mkdir -p \"$template_dir\""
    return 1
  }

  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
      err "Failed to resolve repository root"
      return 1
    }
    cd "$repo_root" || return 1
  else
    info "Not a Git repository, initializing one"
    git init >/dev/null 2>&1 || {
      err "git init failed"
      return 1
    }

    repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || {
      err "git init succeeded but repo root could not be resolved"
      return 1
    }

    cd "$repo_root" || return 1
  fi

  info "Applying git templates from: $template_dir"

  old_nullglob=$(shopt -p nullglob)
  shopt -s nullglob

  for template in "$template_dir"/* "$template_dir"/.*; do
    name="$(basename "$template")"
    [[ "$name" == "." || "$name" == ".." ]] && continue

    target="$PWD/$name"

    if [[ -e "$target" ]]; then
      warn "$name already exists"
      printf "Overwrite %s? [y/n]: " "$name"
      read -r reply

      case "$reply" in
        y|Y|yes|YES)
          [[ -n "$target" && "$target" != "/" ]] || {
            err "Refusing to remove unsafe path: $target"
            failed=$((failed + 1))
            continue
          }

          rm -rf "$target" || {
            err "Failed to remove existing: $name"
            failed=$((failed + 1))
            continue
          }

          if cp -r "$template" "$target"; then
            ok "$name overwritten"
            overwritten=$((overwritten + 1))
          else
            err "Failed to copy: $name"
            failed=$((failed + 1))
          fi
          ;;
        *)
          warn "Skipped $name"
          skipped=$((skipped + 1))
          ;;
      esac

      continue
    fi

    if cp -r "$template" "$target"; then
      ok "$name added"
      applied=$((applied + 1))
    else
      err "Failed to add template: $name"
      failed=$((failed + 1))
    fi
  done

  eval "$old_nullglob"

  info "Templates added: $applied"
  info "Templates overwritten: $overwritten"
  info "Templates skipped: $skipped"

  [[ "$failed" -gt 0 ]] && {
    err "Templates failed: $failed"
    return 1
  }

  return 0
}

# ==================================================
# Git status & inspection
# ==================================================

## Show git status
gs() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gs [--short]

OPTIONS:
  -s, --short   Show summary only (no file list)
  -h, --help    Show this help message

EXAMPLES:
  gs            # Show full status with file list
  gs --short    # Show summary only
EOF
    return 0
  fi

  local branch upstream
  local ahead=0 behind=0
  local staged=0 unstaged=0 untracked=0 stash=0
  local local_head remote_head
  local state="CLEAN"
  local SHOW_FILES=1
  local MAX_FILES=5

  case "${1:-}" in
    --short|-s)
      SHOW_FILES=0
      ;;
  esac

  if [[ -t 1 ]]; then
    C_STAGED="\033[0;32m"
    C_UNSTAGED="\033[0;33m"
    C_UNTRACKED="\033[0;31m"
    C_RESET="\033[0m"
  else
    C_STAGED=""; C_UNSTAGED=""; C_UNTRACKED=""; C_RESET=""
  fi

  _gs_line() {
    printf "%-8s %s" "$1" "$2"
  }

  _gs_files() {
    local label="$1" color="$2"; shift 2
    local files=("$@")
    local total="${#files[@]}"
    local shown=0

    for f in "${files[@]}"; do
      (( shown++ > MAX_FILES )) && break
      info "         ${color}${label}:${C_RESET} $f"
    done

    (( total > MAX_FILES )) &&
      info "         ${color}… +$((total - MAX_FILES)) more${C_RESET}"
  }

  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    err " Not a git repository"
    return 1
  }

  branch="$(git branch --show-current)"
  local_head="$(git rev-parse --short HEAD)"

  if upstream="$(git rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>/dev/null)"; then
    read -r behind ahead < <(
      git rev-list --left-right --count "$upstream"...HEAD
    )
    remote_head="$(git rev-parse --short "$upstream" 2>/dev/null)"
  else
    upstream=""
    remote_head="N/A"
  fi

  if git rev-parse --verify REBASE_HEAD >/dev/null 2>&1; then
    state="REBASE"
  elif git rev-parse --verify MERGE_HEAD >/dev/null 2>&1; then
    state="MERGE"
  elif git rev-parse --verify CHERRY_PICK_HEAD >/dev/null 2>&1; then
    state="CHERRY-PICK"
  elif ! git symbolic-ref -q HEAD >/dev/null; then
    state="DETACHED"
  fi

  local staged_files=()
  local unstaged_files=()
  local untracked_files=()

  while IFS= read -r line; do
    local xy="${line:0:2}"
    local rest="${line:3}"

    case "$xy" in
      "??")
        ((untracked++))
        untracked_files+=("$rest")
        ;;
      R*)
        ((staged++))
        staged_files+=("${rest/ -> / -> }")
        ;;
      [AMDC]" ")
        ((staged++))
        staged_files+=("$rest")
        ;;
      " "[MD])
        ((unstaged++))
        unstaged_files+=("$rest")
        ;;
      *)
        ((staged++))
        ((unstaged++))
        staged_files+=("$rest")
        unstaged_files+=("$rest")
        ;;
    esac
  done < <(git status --porcelain)

  (( staged || unstaged || untracked )) && state="DIRTY"

  stash="$(git stash list 2>/dev/null | wc -l)"

  local _pad_ok="  "
  local _pad_err=" "
  local _pad_none=""

  info "${_pad_none}$(_gs_line BRANCH   "$branch")"
  [[ -n "$upstream" ]] && info "${_pad_none}$(_gs_line UPSTREAM "$upstream")"

  if (( ahead || behind )); then
    warn "${_pad_none}$(_gs_line SYNC "Ahead: $ahead | Behind: $behind")"
  else
    ok "${_pad_ok}$(_gs_line SYNC "Up to date")"
  fi

  info "${_pad_none}$(_gs_line HEAD "Remote: $remote_head | Local: $local_head")"

  if (( staged || unstaged || untracked )); then
    warn "${_pad_none}$(_gs_line WORK "staged: $staged | unstaged: $unstaged | untracked: $untracked")"

    if (( SHOW_FILES )); then
      mapfile -t staged_files   < <(printf '%s\n' "${staged_files[@]}"   | sort)
      mapfile -t unstaged_files < <(printf '%s\n' "${unstaged_files[@]}" | sort)
      mapfile -t untracked_files< <(printf '%s\n' "${untracked_files[@]}"| sort)

      (( staged ))    && _gs_files "Staged"    "$C_STAGED"    "${staged_files[@]}"
      (( unstaged ))  && _gs_files "Unstaged"  "$C_UNSTAGED"  "${unstaged_files[@]}"
      (( untracked )) && _gs_files "Untracked" "$C_UNTRACKED" "${untracked_files[@]}"
    fi
  fi

  (( stash )) && warn "${_pad_none}$(_gs_line STASH "$stash")"

  case "$state" in
    CLEAN)   ok   "${_pad_ok}$(_gs_line STATE CLEAN)" ;;
    DIRTY)   warn "${_pad_none}$(_gs_line STATE DIRTY)" ;;
    *)       err  "${_pad_err}$(_gs_line STATE "$state")" ;;
  esac
}

## Pretty git log
gl() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gl

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  gl            # Show pretty graph log for all branches
EOF
    return 0
  fi

  git log --oneline --graph --all --decorate
}

## Show recent HEAD positions (default: 20 reflog entries)
ghead() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  ghead [number]

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  ghead         # Show last 20 HEAD positions
  ghead 10      # Show last 10 HEAD positions

SHOWS:
  - Commits
  - Amended commits
  - Branch checkouts / switches
  - Pulls
  - Resets
  - Merges
  - Rebases
  - Cherry-picks
  - Reverts
  - Other HEAD movements recorded in the reflog

NOTES:
  - HEAD@{0} is the current HEAD position
  - HEAD@{1} is usually the position before the last HEAD movement
  - Use grestorehead HEAD@{N} to restore a previous position
EOF
    return 0
  fi

  local limit="${1:-20}"

  [[ "$limit" =~ ^[0-9]+$ ]] || {
    err "Usage: ghead [number-of-lines]"
    return 1
  }

  (( limit < 1 )) && {
    err "Line count must be >= 1"
    return 1
  }

  info "Recent HEAD positions (newest first)"
  log

  git reflog \
    --date=relative \
    --format='%h%x09%gd%x09%gs' \
    | head -n "$limit" \
    | awk -F '\t' '
  BEGIN {
    blue    = "\033[0;34m"
    green   = "\033[0;32m"
    yellow  = "\033[0;33m"
    magenta = "\033[0;35m"
    cyan    = "\033[0;36m"
    red     = "\033[0;31m"
    reset   = "\033[0m"

    msg_width = 48
  }

  function trunc(s, w) {
    return (length(s) > w) ? substr(s, 1, w - 1) "…" : s
  }

  {
    hash = $1

    # Actual numeric reflog position.
    selector = "HEAD@{" (NR - 1) "}"

    # With --date=relative, %gd contains something like:
    # HEAD@{2 minutes ago}
    time = $2
    sub(/^HEAD@\{/, "", time)
    sub(/\}$/, "", time)
    time = "(" time ")"

    line = $3

    type  = "ACTION"
    color = yellow
    msg   = line

    # Normal commit
    if (line ~ /^commit:/) {
      type  = "COMMIT"
      color = green
      sub(/^commit: /, "", msg)
    }

    # Amended commit
    else if (line ~ /^commit \(amend\):/) {
      type  = "AMEND"
      color = green
      sub(/^commit \(amend\): /, "", msg)
    }

    # Initial commit
    else if (line ~ /^commit \(initial\):/) {
      type  = "COMMIT"
      color = green
      sub(/^commit \(initial\): /, "", msg)
    }

    # Checkout / switch
    else if (line ~ /^checkout:/) {
      type  = "CHECKOUT"
      color = cyan
      sub(/^checkout: moving from /, "", msg)
    }

    # Reset
    else if (line ~ /^reset:/) {
      type  = "RESET"
      color = yellow
      sub(/^reset: moving to /, "", msg)
      msg = "-> " msg
    }

    # Pull
    else if (line ~ /^pull/) {
      type  = "PULL"
      color = cyan
    }

    # Merge
    else if (line ~ /^merge/) {
      type  = "MERGE"
      color = magenta
    }

    # Rebase
    else if (line ~ /^rebase/) {
      type  = "REBASE"
      color = magenta
    }

    # Cherry-pick
    else if (line ~ /^cherry-pick/) {
      type  = "CHERRY"
      color = magenta
      sub(/^cherry-pick: /, "", msg)
    }

    # Revert
    else if (line ~ /^revert/) {
      type  = "REVERT"
      color = red
      sub(/^revert: /, "", msg)
    }

    # Branch operation
    else if (line ~ /^branch:/) {
      type  = "BRANCH"
      color = cyan
      sub(/^branch: /, "", msg)
    }

    # Clone
    else if (line ~ /^clone:/) {
      type  = "CLONE"
      color = cyan
      sub(/^clone: /, "", msg)
    }

    # Anything else recorded in HEAD reflog
    else {
      type  = "ACTION"
      color = yellow
    }

    msg = trunc(msg, msg_width)

    printf "%s%-10s%s  %s[%-8s]%s  %-*s %s%s%s  %s\n",
      blue, selector, reset,
      color, type, reset,
      msg_width, msg,
      blue, time, reset,
      hash
  }'

  log
  info "Tip: HEAD@{1} is usually the state before your last HEAD movement"
  info "Restore with:"
  info "  grestorehead HEAD@{N}"
}

## Show git differences
gdiff() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gdiff [<path>...]
  gdiff -s [<path>...]
  gdiff -c <ref1> <ref2> [<path>...]
  gdiff -b <branch1> <branch2> [<path>...]
  gdiff -r [<path>...]

COMPARISON OPTIONS:
  -s, --staged              Show staged changes
  -c, --commits A B         Compare two commits or revisions
  -b, --branches A B        Compare two branches
  -r, --remote              Compare origin/<current-branch> to HEAD

DISPLAY OPTIONS:
  -t, --stat                Show diff statistics
  -n, --name-only           Show only changed file names
  -w, --word-diff           Show word-level differences
  --merge-base              Compare from merge base with --branches
  --ignore-whitespace       Ignore whitespace changes
  -U, --context <number>    Number of context lines to show

OTHER:
  --                        Treat all remaining arguments as paths
  --explain                 Explain comparison direction and refs
  -h, --help                Show this help message

EXAMPLES:
  gdiff
  gdiff src/main.sh
  gdiff -s
  gdiff -s src/main.sh

  gdiff -c HEAD~1 HEAD
  gdiff src/main.sh -c HEAD~3 HEAD
  gdiff -c HEAD@{2} HEAD src/

  gdiff -b main dev
  gdiff src/ -b main dev
  gdiff -b main dev --merge-base

  gdiff -r
  gdiff README.md -r

  gdiff -b main dev --stat
  gdiff -c HEAD~5 HEAD --name-only
  gdiff README.md --word-diff
  gdiff --ignore-whitespace -b main dev
  gdiff -U 5 src/main.sh

  gdiff -- -filename-starting-with-dash

TIP:
  Run 'gdiff --explain' to understand comparison direction and refs.
EOF
    return 0
  fi

  if [[ "${1:-}" == "--explain" ]]; then
    cat <<'EOF'
GDIFF COMPARISON GUIDE

Comparisons are directional:

  A  ->  B

means:

  Show what changed when going from A to B.


COMMITS / REVISIONS

  gdiff -c <ref1> <ref2>

The first ref is the starting state.
The second ref is the destination state.

Example:

  gdiff -c HEAD~1 HEAD

  HEAD~1  ->  HEAD

Shows what changed from the previous commit to the current commit.
This is useful for seeing what the latest commit introduced.

Reversing the refs:

  gdiff -c HEAD HEAD~1

  HEAD  ->  HEAD~1

shows the comparison in the opposite direction.

Additions become removals and removals become additions.


COMMON REFS

  HEAD          Current commit
  HEAD~1        One commit before HEAD
  HEAD~2        Two commits before HEAD
  HEAD@{1}      Previous HEAD reflog position
  abc123        Commit hash
  tag           Tag resolving to a commit


BRANCHES

  gdiff -b <branch1> <branch2>

The first branch is the starting state.
The second branch is the destination state.

Example:

  gdiff -b main dev

  main  ->  dev

Shows what differs on dev compared with main.

Reversing the branches:

  gdiff -b dev main

  dev  ->  main

shows the comparison in the opposite direction.

Additions and removals are therefore reversed.


MERGE BASE

  gdiff -b main dev --merge-base

Instead of directly comparing the tips of main and dev, this uses the
point where the branches diverged as the starting state:

  merge-base(main, dev)  ->  dev

This is useful for seeing what dev introduced since it branched away
from main.


PATHS

Paths can be combined with any applicable comparison:

  gdiff -c HEAD~3 HEAD src/
  gdiff README.md -b main dev
  gdiff -r src/

Only matching paths are included in the comparison.

Paths may appear before or after the comparison option:

  gdiff src/main.sh -c HEAD~3 HEAD
  gdiff -c HEAD~3 HEAD src/main.sh

Both perform the same comparison.


SPECIAL PATHS

Use -- when a path starts with a dash:

  gdiff -- -example.txt

Everything after -- is treated as a path.
EOF
    return 0
  fi

  groot || return 1

  local mode="working"
  local mode_set=0

  local ref1=""
  local ref2=""
  local branch=""

  local merge_base=0
  local parsing_options=1

  local paths=()
  local diff_args=()

  # Set comparison mode and prevent conflicting modes.
  _gdiff_set_mode() {
    local new_mode="$1"

    if (( mode_set )) && [[ "$mode" != "$new_mode" ]]; then
      err "Only one comparison mode can be used at a time"
      return 1
    fi

    mode="$new_mode"
    mode_set=1
  }

  # Validate a commit-ish/ref.
  _gdiff_validate_ref() {
    local ref="$1"

    git rev-parse --verify "$ref^{commit}" >/dev/null 2>&1 || {
      err "Commit or revision not found: $ref"
      return 1
    }
  }

  # Validate a local or remote branch.
  _gdiff_validate_branch() {
    local branch_name="$1"

    if git show-ref --verify --quiet "refs/heads/$branch_name"; then
      return 0
    fi

    if git show-ref --verify --quiet "refs/remotes/$branch_name"; then
      return 0
    fi

    err "Branch not found: $branch_name"
    return 1
  }

  # Parse arguments.
  while [[ $# -gt 0 ]]; do
    # Everything after -- is a path.
    if (( ! parsing_options )); then
      paths+=("$1")
      shift
      continue
    fi

    case "$1" in
      --)
        parsing_options=0
        shift
        ;;

      -s|--staged|--cached)
        _gdiff_set_mode "staged" || return 1
        shift
        ;;

      -c|--commits)
        _gdiff_set_mode "commits" || return 1

        [[ $# -ge 3 ]] || {
          err "Usage: gdiff --commits <ref1> <ref2> [<path>...]"
          return 1
        }

        ref1="$2"
        ref2="$3"

        _gdiff_validate_ref "$ref1" || return 1
        _gdiff_validate_ref "$ref2" || return 1

        shift 3
        ;;

      -b|--branches)
        _gdiff_set_mode "branches" || return 1

        [[ $# -ge 3 ]] || {
          err "Usage: gdiff --branches <branch1> <branch2> [<path>...]"
          return 1
        }

        ref1="$2"
        ref2="$3"

        _gdiff_validate_branch "$ref1" || return 1
        _gdiff_validate_branch "$ref2" || return 1

        shift 3
        ;;

      -r|--remote)
        _gdiff_set_mode "remote" || return 1
        shift
        ;;

      -t|--stat)
        diff_args+=("--stat")
        shift
        ;;

      -n|--name-only)
        diff_args+=("--name-only")
        shift
        ;;

      -w|--word-diff)
        diff_args+=("--word-diff")
        shift
        ;;

      --merge-base)
        merge_base=1
        shift
        ;;

      --ignore-whitespace)
        diff_args+=("--ignore-all-space")
        shift
        ;;

      -U|--context)
        [[ -n "${2:-}" ]] || {
          err "Missing context line count"
          return 1
        }

        [[ "$2" =~ ^[0-9]+$ ]] || {
          err "Context must be a non-negative number"
          return 1
        }

        diff_args+=("-U$2")
        shift 2
        ;;

      -h|--help)
        err "Place -h or --help as the first argument"
        return 1
        ;;

      --explain)
        err "Place --explain as the first argument"
        return 1
        ;;

      -*)
        err "Unknown option: $1"
        info "Use '--' before paths that begin with '-'"
        return 1
        ;;

      *)
        paths+=("$1")
        shift
        ;;
    esac
  done

  # --merge-base only makes sense for branch comparisons.
  if (( merge_base )) && [[ "$mode" != "branches" ]]; then
    err "--merge-base can only be used with --branches"
    return 1
  fi

  case "$mode" in
    working)
      if git diff --quiet HEAD -- "${paths[@]}"; then
        info "No differences found"
        return 0
      fi

      git diff "${diff_args[@]}" HEAD -- "${paths[@]}"
      ;;

    staged)
      if git diff --cached --quiet -- "${paths[@]}"; then
        info "No staged differences found"
        return 0
      fi

      git diff --cached "${diff_args[@]}" -- "${paths[@]}"
      ;;

    commits)
      if git diff --quiet "$ref1" "$ref2" -- "${paths[@]}"; then
        info "No differences found between $ref1 and $ref2"
        return 0
      fi

      git diff "${diff_args[@]}" "$ref1" "$ref2" -- "${paths[@]}"
      ;;

    branches)
      local branch_range

      if (( merge_base )); then
        branch_range="$ref1...$ref2"
      else
        branch_range="$ref1..$ref2"
      fi

      if git diff --quiet "$branch_range" -- "${paths[@]}"; then
        if (( merge_base )); then
          info "No differences found from merge base of $ref1 to $ref2"
        else
          info "No differences found between $ref1 and $ref2"
        fi

        return 0
      fi

      git diff "${diff_args[@]}" "$branch_range" -- "${paths[@]}"
      ;;

    remote)
      branch="$(git branch --show-current 2>/dev/null)"

      [[ -n "$branch" ]] || {
        err "Detached HEAD — cannot diff against remote"
        return 1
      }

      git remote get-url origin >/dev/null 2>&1 || {
        err "Remote 'origin' does not exist"
        return 1
      }

      info "Fetching origin"

      git fetch origin >/dev/null 2>&1 || {
        err "Failed to fetch origin"
        return 1
      }

      git rev-parse --verify "origin/$branch" >/dev/null 2>&1 || {
        err "Remote branch origin/$branch does not exist"
        return 1
      }

      info "Comparing origin/$branch -> HEAD"

      if git diff --quiet "origin/$branch" HEAD -- "${paths[@]}"; then
        info "No differences found against origin/$branch"
        return 0
      fi

      git diff "${diff_args[@]}" "origin/$branch" HEAD -- "${paths[@]}"
      ;;
  esac
}

## Show active git SSH host for current repository
ghost() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  ghost

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  ghost     # Show SSH host, user, and repo URL for origin remote
EOF
    return 0
  fi

  local url host repo

  groot "$@" || return 1

  url=$(git remote get-url origin 2>/dev/null) || {
    err "No origin remote found"
    return 1
  }

  if [[ "$url" =~ ^git@([^:]+):(.+)\.git$ ]]; then
    host="${BASH_REMATCH[1]}"
    repo="${BASH_REMATCH[2]}"

    info "Git SSH host status"
    printf "  Host: %s\n" "$host"
    printf "  Repo: %s\n" "$repo"
    printf "  URL:  %s\n" "$url"
  else
    warn "Origin remote is not using SSH"
    printf "  URL: %s\n" "$url"
  fi
}

## Show git context (branch, upstream, ahead, behind)
gwhere() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gwhere

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  gwhere        # Show current branch, upstream, and ahead/behind counts
EOF
    return 0
  fi

  local b upstream ahead behind
  b=$(git branch --show-current 2>/dev/null) || return 1
  upstream=$(git rev-parse --abbrev-ref "@{u}" 2>/dev/null || echo "-")
  ahead=$(git rev-list --count "@{u}..HEAD" 2>/dev/null || echo 0)
  behind=$(git rev-list --count "HEAD..@{u}" 2>/dev/null || echo 0)

  info "Git context"
  printf "  Branch:   %s\n" "$b"
  printf "  Upstream: %s\n" "$upstream"
  printf "  Ahead:    %s\n" "$ahead"
  printf "  Behind:   %s\n" "$behind"
}

# ==================================================
# Git staging, committing
# ==================================================

## Stage all changes
# shellcheck disable=SC2120
ga() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  ga [<path>...]

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  ga                                 # Stage all changes in the working tree
  ga path/to/file.txt                # Stage one file
  ga path/file1.txt path/file2.txt   # Stage multiple files
  ga src/ docs/                      # Stage multiple paths
  ga path/*.txt                      # Stage files matching a wildcard
  ga */path                          # Stage matching paths one level deep
  ga path/*/something                # Stage matching nested paths
EOF
    return 0
  fi

  if [[ $# -eq 0 ]]; then
    git add . && ok "All changes staged"
    return $?
  fi

  git add -- "$@" && ok "Selected path(s) staged"
}

## Commit staged changes
gc() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gc <message> [<paragraph>...] [-c <co-author>]

OPTIONS:
  -c <co-author>    Add a co-author (can be used multiple times)
  -h, --help        Show this help message

EXAMPLES:
  gc 'Fix login bug'
  gc 'Fix login bug' 'Details about the fix'
  gc 'Fix login bug' -c 'Alice <alice@example.com>'
  gc 'Fix login bug' 'Details' -c 'Alice <alice@example.com>' -c 'Bob <bob@example.com>'

NOTES:
  - Only commits changes that are already staged
  - Unstaged and untracked changes are left untouched
EOF
    return 0
  fi

  if git diff --cached --quiet; then
    info "Nothing staged to commit"
    return 0
  fi

  if [[ $# -eq 0 ]]; then
    err "Commit message required"
    err "Usage:"
    err "  gc 'Subject'"
    err "  gc 'Subject' 'Next paragraph' 'Another paragraph'"
    err "  gc 'Subject' -c 'Co-author <email>'"
    err "  gc 'Subject' 'Next paragraph' -c 'Co-author <email>'"
    err "  Tip: Add co-authors at the end. Use -c multiple times to add multiple co-authors"
    return 1
  fi

  local messages=()
  local coauthors=()

  messages+=("$1")
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c)
        [[ -z "${2:-}" ]] && {
          err "Missing co-author value"
          return 1
        }

        coauthors+=("$2")
        shift 2
        ;;
      *)
        messages+=("$1")
        shift
        ;;
    esac
  done

  local args=()

  for msg in "${messages[@]}"; do
    args+=("-m" "$msg")
  done

  for ca in "${coauthors[@]}"; do
    args+=("-m" "Co-authored-by: $ca")
  done

  git commit "${args[@]}" && ok "Changes committed"
}

## Amend last commit (message and/or content)
gca() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gca <message> [<paragraph>...] [-c <co-author>]

OPTIONS:
  -c, --coauthor <co-author>    Add a co-author (can be used multiple times)
  -h, --help                    Show this help message

EXAMPLES:
  gca 'Fix typo in commit message'
  gca 'New subject' 'Body paragraph'
  gca 'New subject' -c 'Alice <alice@example.com>'

NOTES:
  - Warns if the last commit is already pushed to upstream
  - A force-push will be required if commit is already on remote
EOF
    return 0
  fi

  if [[ $# -eq 0 ]]; then
    err "Commit message required"
    err "Usage:"
    err "  gca 'New subject'"
    err "  gca 'New subject' 'Next paragraph'"
    err "  gca 'New subject' -c 'Co-author <email>'"
    err "  gca 'New subject' 'Body' -c 'Co-author <email>' [-c ...]"
    err "  Tip: Add co-authors at the end. Use -c multiple times for multiple co-authors"
    return 1
  fi

  local upstream
  upstream=$(git rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>/dev/null || true)

  if [[ -n "$upstream" ]] && git merge-base --is-ancestor HEAD "$upstream"; then
    warn "Last commit is already pushed to $upstream"
    warn "You will need to run:"
    warn "  git push --force-with-lease"
    warn "If this is a shared branch, consider making a new commit instead."
    log
  fi

  local messages=()
  local coauthors=()

  messages+=("$1")
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -c|--coauthor)
        [[ -z "${2:-}" ]] && { err "Missing co-author value"; return 1; }
        coauthors+=("$2")
        shift 2
        ;;
      *)
        messages+=("$1")
        shift
        ;;
    esac
  done

  local args=()
  for msg in "${messages[@]}"; do
    args+=("-m" "$msg")
  done

  for ca in "${coauthors[@]}"; do
    args+=("-m" "Co-authored-by: $ca")
  done

  git commit --amend "${args[@]}" && ok "Last commit amended"
}

## Edit a commit message and/or date
gce() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gce [<commit>] [-m <message>...] [-c <co-author>...] [-d <date>]
  gce [<commit>] [--author-date <date>] [--committer-date <date>]

OPTIONS:
  -m, --message <message>       Set commit message paragraph (can be used multiple times)
  -c, --coauthor <co-author>    Add a co-author (can be used multiple times)
  -d, --date <date>             Set both author and committer date
  --author-date <date>          Set only author date
  --committer-date <date>       Set only committer date
  -h, --help                    Show this help message

EXAMPLES:
  gce -m 'New message'
  gce -m 'Title' -m 'Body paragraph'
  gce -m 'Title' -c 'Alice <alice@example.com>'
  gce -d '2000-01-01T13:00:00+00:00'
  gce -d '2000-01-01 13:00:00'
  gce -d '13:00'
  gce -d '1PM'
  gce -d 'yesterday 13:00'
  gce HEAD -m 'New message' -d '2000-01-01 13:00'
  gce HEAD~2 -m 'Rewrite older commit'
  gce HEAD~2 -m 'Rewrite older commit' -c 'Alice <alice@example.com>'
  gce abc123 -d '2 days ago'

NOTES:
  - Defaults to HEAD when no commit is provided
  - Editing older commits rewrites history
  - The working tree must be clean before editing older commits

DATE INPUT:
  - Parsed using: date -d '<date>'
  - If your system does not support this, you may need GNU date or a compatible implementation
  - Supports formats such as:
      '2000-01-01T13:00:00+00:00'
      '2000-01-01 13:00:00'
      '13:00'
      '1PM'
      'tomorrow'
      'yesterday 13:00'
      '2 days ago'
      '2 weeks ago monday'
      '13:00 2 weeks ago tuesday'
  - If only a time is provided, the date defaults to today
  - If no time is provided, the time may default to the current time or 00:00:00
  - For consistent results, it is recommended to always include a time
EOF
    return 0
  fi

  local commit="HEAD"
  local author_date=""
  local committer_date=""
  local messages=()
  local coauthors=()
  local confirm=""

  _gce_normalize_date() {
    local input="$1"
    date -d "$input" +"%Y-%m-%dT%H:%M:%S%:z" 2>/dev/null
  }

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m|--message)
        [[ -z "${2:-}" ]] && { err "Missing message value"; return 1; }
        messages+=("-m" "$2")
        shift 2
        ;;
      -c|--coauthor)
        [[ -z "${2:-}" ]] && { err "Missing co-author value"; return 1; }
        coauthors+=("$2")
        shift 2
        ;;
      -d|--date)
        [[ -z "${2:-}" ]] && { err "Missing date value"; return 1; }
        author_date="$2"
        committer_date="$2"
        shift 2
        ;;
      --author-date)
        [[ -z "${2:-}" ]] && { err "Missing author date value"; return 1; }
        author_date="$2"
        shift 2
        ;;
      --committer-date)
        [[ -z "${2:-}" ]] && { err "Missing committer date value"; return 1; }
        committer_date="$2"
        shift 2
        ;;
      -*)
        err "Unknown option: $1"
        return 1
        ;;
      *)
        commit="$1"
        shift
        ;;
    esac
  done

  if [[ ${#messages[@]} -eq 0 && ${#coauthors[@]} -eq 0 && -z "$author_date" && -z "$committer_date" ]]; then
    err "Nothing to amend"
    err "Usage:"
    err "  gce -m 'New message'"
    err "  gce -m 'New message' -c 'Co-author <email>'"
    err "  gce -d '2000-01-01 13:00'"
    err "  gce HEAD~2 -m 'New message' -d '2000-01-01 13:00'"
    return 1
  fi

  if [[ -n "$author_date" ]]; then
    local original_author_date="$author_date"
    author_date="$(_gce_normalize_date "$author_date")" || {
      err "Invalid author date: $original_author_date"
      warn "Your system date command may not support this format"
      warn "Required support: date -d '<date>'"
      warn "If your system does not support this, you may need GNU date or a compatible implementation"
      return 1
    }
  fi

  if [[ -n "$committer_date" ]]; then
    local original_committer_date="$committer_date"
    committer_date="$(_gce_normalize_date "$committer_date")" || {
      err "Invalid committer date: $original_committer_date"
      warn "Your system date command may not support this format"
      warn "Required support: date -d '<date>'"
      warn "If your system does not support this, you may need GNU date or a compatible implementation"
      return 1
    }
  fi

  commit="$(git rev-parse "$commit")" || return 1

  local head
  head="$(git rev-parse HEAD)" || return 1

  local upstream
  upstream=$(git rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>/dev/null || true)

  if [[ -n "$upstream" ]] && git merge-base --is-ancestor "$commit" "$upstream"; then
    warn "Commit is already pushed to $upstream"
    warn "You will need to run:"
    warn "  git push --force-with-lease"
    warn "If this is a shared branch, consider making a new commit instead."
    log
  fi

  local amend_args=()

  if [[ ${#messages[@]} -gt 0 ]]; then
    amend_args=("${messages[@]}")

    for ca in "${coauthors[@]}"; do
      amend_args+=("-m" "Co-authored-by: $ca")
    done

  elif [[ ${#coauthors[@]} -gt 0 ]]; then
    local existing_message
    existing_message="$(git log -1 --format=%B "$commit")"

    amend_args+=("-m" "$existing_message")

    for ca in "${coauthors[@]}"; do
      amend_args+=("-m" "Co-authored-by: $ca")
    done

  else
    amend_args=("--no-edit")
  fi

  _gce_amend() {
    if [[ -n "$author_date" && -n "$committer_date" ]]; then
      GIT_COMMITTER_DATE="$committer_date" git commit --amend --date="$author_date" "${amend_args[@]}"
    elif [[ -n "$author_date" ]]; then
      git commit --amend --date="$author_date" "${amend_args[@]}"
    elif [[ -n "$committer_date" ]]; then
      GIT_COMMITTER_DATE="$committer_date" git commit --amend "${amend_args[@]}"
    else
      git commit --amend "${amend_args[@]}"
    fi
  }

  if [[ "$commit" == "$head" ]]; then
    _gce_amend && ok "Last commit edited"
    return $?
  fi

  if ! git diff --quiet || ! git diff --cached --quiet; then
    err "Working tree must be clean before rewriting older commits"
    return 1
  fi

  warn "Editing an older commit rewrites history"
  info "Target: $(git log -1 --oneline "$commit")"
  read -r "confirm?Continue? [y/n]: "

  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    info "Aborted"
    return 1
  fi

  local short_commit parent editor_script
  short_commit="$(git rev-parse --short "$commit")"
  parent="$(git rev-parse "$commit^" 2>/dev/null)"

  editor_script="$(mktemp)"

  cat > "$editor_script" <<EOF
#!/usr/bin/env bash
sed -i.bak "0,/^pick $short_commit /s//edit $short_commit /" "\$1"
EOF

  chmod +x "$editor_script"

  if [[ -n "$parent" ]]; then
    GIT_SEQUENCE_EDITOR="$editor_script" git rebase -i "$parent" || {
      rm -f "$editor_script" "$editor_script.bak"
      return 1
    }
  else
    GIT_SEQUENCE_EDITOR="$editor_script" git rebase -i --root || {
      rm -f "$editor_script" "$editor_script.bak"
      return 1
    }
  fi

  rm -f "$editor_script" "$editor_script.bak"

  _gce_amend || return 1

  git rebase --continue && ok "Commit edited"
}

## Squash last N commits (soft reset)
gsquashlast() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gsquashlast <number>

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  gsquashlast 3     # Soft-reset the last 3 commits, leaving changes staged

NOTES:
  - After squashing, run gc to create the final single commit
EOF
    return 0
  fi

  if [[ -z "$1" ]]; then
    err "Usage: gsquashlast <number>"
    return 0
  fi

  local n="$1"
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    err "Usage: gsquashlast <number>"
    return 0
  fi

  warn "Squashing last $n commits"
  git reset --soft "HEAD~$n" &&
  info "Commits squashed (soft)"
  info "Run gc to create the final commit"
}

# ==================================================
# Git working tree control
# ==================================================

## Restore unstaged changes
gr() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gr [<path>...]

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  gr                                 # Discard all unstaged changes
  gr path/to/file.txt                # Discard unstaged changes in one file
  gr path/file1.txt path/file2.txt   # Discard unstaged changes in multiple files
  gr src/ docs/                      # Discard unstaged changes in multiple paths
  gr path/*.txt                      # Discard unstaged changes for wildcard matches
  gr */path                          # Discard unstaged changes in matching paths
  gr path/*/something                # Discard unstaged changes in nested matches
EOF
    return 0
  fi

  if [[ $# -eq 0 ]]; then
    if git diff --quiet; then
      info "No unstaged changes to restore"
      return 0
    fi

    warn "This will discard ALL unstaged changes"
    confirm "Continue?" || return 0

    git restore .
    ok "Changes restored"
    return 0
  fi

  if git diff --quiet -- "$@"; then
    info "No unstaged changes to restore for selected path(s)"
    return 0
  fi

  warn "This will discard unstaged changes in selected path(s)"
  confirm "Continue?" || return 0

  git restore -- "$@"
  ok "Selected path(s) restored"
}

## Restore staged changes
grs() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  grs [<path>...]

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  grs                                 # Unstage all staged changes
  grs path/to/file.txt                # Unstage one file
  grs path/file1.txt path/file2.txt   # Unstage multiple files
  grs src/ docs/                      # Unstage multiple paths
  grs path/*.txt                      # Unstage wildcard-matched files
  grs */path                          # Unstage matching paths
  grs path/*/something                # Unstage nested matches
EOF
    return 0
  fi

  if [[ $# -eq 0 ]]; then
    if git diff --cached --quiet; then
      info "No staged changes to restore"
      return 0
    fi

    warn "This will unstage ALL staged changes"
    confirm "Continue?" || return 0

    git restore --staged .
    ok "Staged changes restored"
    return 0
  fi

  if git diff --cached --quiet -- "$@"; then
    info "No staged changes to restore for selected path(s)"
    return 0
  fi

  warn "This will unstage selected path(s)"
  confirm "Continue?" || return 0

  git restore --staged -- "$@"
  ok "Selected path(s) unstaged"
}

## Clean working tree (discard all uncommitted changes)
gcleanworktree() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gcleanworktree

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  gcleanworktree    # Hard reset and remove all untracked files (prompts for confirmation)

NOTES:
  - Discards ALL uncommitted changes, including untracked files
EOF
    return 0
  fi

  warn "This will discard ALL uncommitted changes"
  confirm "Continue?" || return 0
  git reset --hard &&
  git clean -fd &&
  ok "Working tree cleaned"
}

## Stash all changes (including untracked)
gstash() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gstash [message]

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  gstash                  # Stash with default message 'wip'
  gstash 'wip: auth fix'  # Stash with a custom message

NOTES:
  - Includes untracked files (-u)
  - Use gpop to restore the latest stash
EOF
    return 0
  fi

  if [[ -z "$1" ]]; then
    warn "No stash message provided, using 'wip'"
  fi

  git stash push -u -m "${1:-wip}" &&
  ok "Changes stashed"
}

## Pop latest stash
gpop() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gpop

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  gpop          # Apply and remove the latest stash entry
EOF
    return 0
  fi

  git stash pop &&
  ok "Stash applied"
}

## List stashes
gstashlist() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gstashlist

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  gstashlist    # List all stash entries
EOF
    return 0
  fi

  git stash list
}

# ==================================================
# Git sync & fetch
# ==================================================

## Pull with rebase
gpr() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gpr

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  gpr           # Pull from upstream with rebase
EOF
    return 0
  fi

  git pull --rebase
}

## Prune deleted remote branches
gfp() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gfp

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  gfp           # Fetch and prune stale remote-tracking branches
EOF
    return 0
  fi

  git fetch -p
}

## Abort current merge
gabort() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gabort

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  gabort        # Abort an in-progress merge and restore the pre-merge state
EOF
    return 0
  fi

  git merge --abort
}

# ==================================================
# Git recovery & repair - local
# ==================================================

## Undo last commit (soft)
gus() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gus [--abort]

OPTIONS:
  --abort       Restore HEAD to state before gus was run
  -h, --help    Show this help message

EXAMPLES:
  gus           # Undo last commit, keeping changes staged
  gus --abort   # Restore previous HEAD if you changed your mind

NOTES:
  - Soft reset: changes remain staged after undo
EOF
    return 0
  fi

  [[ "${1:-}" == "--abort" ]] && { _abort_reset; return $?; }

  git rev-parse HEAD >/dev/null 2>&1 || {
    err "Repository has no commits"
    return 1
  }

  (( $(git rev-list --count HEAD) < 2 )) && {
    info "Nothing to undo"
    return 0
  }

  git reset --soft HEAD~1 &&
  ok "Last commit undone (soft)"
  info "Use 'gus --abort' to restore previous HEAD if needed"
}

## Undo last N commits (soft)
gusn() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gusn <number>

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  gusn 3        # Undo the last 3 commits, keeping all changes staged

NOTES:
  - Soft reset: all changes remain staged after undo
  - Use gc to squash into one commit, or grs to unstage selectively
EOF
    return 0
  fi

  local n="$1"

  [[ "$n" =~ ^[0-9]+$ ]] || {
    err "Usage: gusn <number>"
    return 0
  }

  (( n < 1 )) && {
    err "Number must be >= 1"
    return 0
  }

  git rev-parse HEAD >/dev/null 2>&1 || {
    err "Repository has no commits"
    return 0
  }

  local count
  count=$(git rev-list --count HEAD)

  (( count <= n )) && {
    err "Cannot undo $n commits (repository has $count)"
    return 0
  }

  git reset --soft "HEAD~$n" || true

  ok "Last $n commit(s) undone (soft)"
  info "Current state: all changes are staged"
  info "Next steps:"
  info "  - Run 'gc' to squash everything into one commit"
  info "  - Run 'grs' to unstage everything and re-commit selectively"
  info "Recovery:"
  info "  - Run 'ghead' to inspect previous HEAD positions"
  info "  - Run 'grestorehead HEAD@{N}' to restore a previous state"
}

## Undo last commit (hard)
guh() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  guh [--abort]

OPTIONS:
  --abort       Restore HEAD to state before guh was run
  -h, --help    Show this help message

EXAMPLES:
  guh           # Permanently discard the last commit (prompts for confirmation)
  guh --abort   # Restore previous HEAD immediately after running guh

NOTES:
  - Hard reset: changes are permanently discarded
  - Use gus for a soft undo that keeps changes staged
EOF
    return 0
  fi

  [[ "${1:-}" == "--abort" ]] && {
    warn "guh --abort only works immediately after guh"
    _abort_reset
    return $?
  }

  git rev-parse HEAD >/dev/null 2>&1 || {
    err "Repository has no commits"
    return 0
  }

  (( $(git rev-list --count HEAD) < 2 )) && {
    info "Nothing to discard"
    return 0
  }

  warn "This will permanently discard the last commit"
  confirm "Continue?" || return 0

  git reset --hard HEAD~1 || true
  ok "Last commit discarded (hard)"
  info "Use 'guh --abort' immediately to restore previous HEAD if needed"
}

## Undo last N commits (hard)
guhn() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  guhn <number>

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  guhn 3        # Permanently discard the last 3 commits (prompts for confirmation)

NOTES:
  - Hard reset: changes are permanently discarded
  - Recovery is only possible via reflog (use ghead + grestorehead)
EOF
    return 0
  fi

  local n="$1"

  [[ "$n" =~ ^[0-9]+$ ]] || {
    err "Usage: guhn <number>"
    return 0
  }

  (( n < 1 )) && {
    err "Number must be >= 1"
    return 0
  }

  git rev-parse HEAD >/dev/null 2>&1 || {
    err "Repository has no commits"
    return 0
  }

  local count
  count=$(git rev-list --count HEAD)

  (( count <= n )) && {
    err "Cannot discard $n commits (repository has $count)"
    return 0
  }

  warn "This will permanently discard the last $n commit(s)"
  confirm "Continue?" || return 0

  git reset --hard "HEAD~$n" || true

  ok "Last $n commit(s) discarded (hard)"
  warn "Recovery is only possible via reflog"
  info "Recovery:"
  info "  - Run 'ghead' to inspect previous HEAD positions"
  info "  - Run 'grestorehead HEAD@{N}' to restore a previous state"
}

## Move latest local commit to another branch
gmove() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gmove <target-branch>

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  gmove dev     # Move the latest unpushed commit from current branch to 'dev'

NOTES:
  - The commit must not have been pushed to upstream yet
  - Working tree must be clean
EOF
    return 0
  fi

  local target="$1"
  local current orig ahead

  current="$(git branch --show-current 2>/dev/null)" || {
    err "Not inside a git repository"
    return 0
  }

  if [[ -z "$target" ]]; then
    err "Usage: gmove <target-branch>"
    return 0
  fi

  if [[ "$current" == "$target" ]]; then
    err "Target branch is the current branch"
    return 0
  fi

  if ! git diff --quiet || ! git diff --cached --quiet; then
    err "Working tree is dirty"
    err "Commit or stash your changes before moving commits"
    return 0
  fi

  if ! git rev-parse HEAD~1 >/dev/null 2>&1; then
    err "No commit to move"
    return 0
  fi

  if git rev-parse "@{u}" >/dev/null 2>&1; then
    ahead=$(git rev-list --count "@{u}..HEAD")
    if [[ "$ahead" -eq 0 ]]; then
      err "Latest commit is already pushed to upstream"
      return 0
    fi
  fi

  local is_protected=0
  for protected in $GHELPER_PROTECTED_BRANCHES; do
    [[ "$current" == "$protected" ]] && { is_protected=1; break; }
  done

  if (( is_protected )); then
    warn "You are moving a commit off '${current}'"
    warn "This is usually correct, but double-check intent"
    confirm "Continue?" || return 0
  fi

  info "Moving latest commit from '$current' -> '$target'"

  orig="$current"

  git switch "$target" || return 1

  if ! git cherry-pick "$orig@{0}"; then
    err "Cherry-pick failed — aborting"
    git cherry-pick --abort >/dev/null 2>&1 || true
    git switch "$orig" >/dev/null 2>&1 || true
    return 1
  fi

  git switch "$orig" || return 1
  git reset --hard HEAD~1 || return 1

  ok "Commit successfully moved to '$target'"
}

## Restore HEAD to a previous position
grestorehead() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  grestorehead <reflog-id>

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  grestorehead HEAD@{1}     # Restore HEAD to one position ago
  grestorehead HEAD@{3}     # Restore HEAD to three positions ago

NOTES:
  - Use ghead to inspect available reflog positions
EOF
    return 0
  fi

  [[ -z "$1" ]] && {
    err "Usage: grestorehead <reflog-id>"
    return 0
  }

  warn "Resetting HEAD to $1"
  confirm "Continue?" || return 0

  git reset --hard "$1" || true
  ok "HEAD restored"
}

# ==================================================
# Git recovery & repair - remote
# ==================================================

## Undo last remote commit (soft)
## Undo last remote commit (soft)
gurs() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gurs

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  gurs          # Remove latest commit from remote (soft), keeping changes staged

NOTES:
  - Requires a confirmed prompt when on main
  - Uses force-with-lease for safety
EOF
    return 0
  fi

  local branch commit_count
  branch=$(git branch --show-current)

  [[ -z "$(git rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>/dev/null)" ]] && {
    err "No upstream branch set"
    return 0
  }

  commit_count=$(git rev-list --count HEAD)
  (( commit_count < 2 )) && {
    err "Cannot remove the initial (root) commit"
    return 0
  }

  _guard_main_rewrite || return 0

  info "Removing latest commit on '$branch' (soft)"
  git reset --soft HEAD~1 || true
  git push --force-with-lease || true
  ok "Latest commit removed (soft)"
}

## Undo last remote commit (hard)
gurh() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gurh

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  gurh          # Permanently remove the latest commit from remote (hard)

NOTES:
  - Requires a confirmed prompt when on main (via _guard_main_rewrite)
  - Uses force-with-lease for safety
  - Hard reset: changes are permanently discarded
EOF
    return 0
  fi

  local branch commit_count
  branch=$(git branch --show-current)

  [[ -z "$(git rev-parse --abbrev-ref --symbolic-full-name "@{u}" 2>/dev/null)" ]] && {
    err "No upstream branch set"
    return 0
  }

  commit_count=$(git rev-list --count HEAD)
  (( commit_count < 2 )) && {
    err "Cannot remove the initial (root) commit"
    return 0
  }

  _guard_main_rewrite || return 0

  local is_protected=0
  local protected
  for protected in $GHELPER_PROTECTED_BRANCHES; do
    [[ "$branch" == "$protected" ]] && { is_protected=1; break; }
  done

  if (( ! is_protected )); then
    warn "This will permanently remove the latest commit on '$branch'"
    confirm "Continue?" || return 0
  fi

  git reset --hard HEAD~1 || true
  git push --force-with-lease || true
  ok "Latest commit permanently removed"
}

# ==================================================
# Git branch workflows
# ==================================================

## Merge source into current branch (or specified target)
gmerge() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gmerge <source> [<target>] [-p|--push]

OPTIONS:
  -p, --push    Push the target branch after a successful merge
  -h, --help    Show this help message

EXAMPLES:
  gmerge dev           # Merge dev into the current branch
  gmerge dev main      # Merge dev into main
  gmerge dev -p        # Merge dev into the current branch and push it
  gmerge dev main -p   # Merge dev into main and push main

NOTES:
  - With one branch, merges source -> current branch
  - With two branches, merges source -> target
  - Source and target branches must exist locally
  - Local-only branches are supported
  - Remote-backed branches are updated using fast-forward only
  - Working tree must be clean
  - Protected target branches require typing the branch name
  - Uses --no-ff merge strategy
  - Does not push by default
  - Use -p or --push to push the target branch after merging
  - Returns to the original branch after a completed merge
  - If merge conflicts occur, stays on the target branch for resolution
EOF
    return 0
  fi

  local src_branch=""
  local target_branch=""
  local original=""
  local push_after=0

  local confirm_reply=""
  local lockdir=""
  local has_origin=0
  local src_has_origin=0
  local target_has_origin=0

  local result=0
  local keep_target=0
  local ahead=0

  local branches=()

  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    err "Not inside a Git repository"
    return 1
  }

  original="$(git branch --show-current 2>/dev/null)"

  [[ -n "$original" ]] || {
    err "Detached HEAD — switch to a branch before merging"
    return 1
  }

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -p|--push)
        push_after=1
        shift
        ;;

      -h|--help)
        err "Place -h or --help as the first argument"
        return 1
        ;;

      -*)
        err "Unknown option: $1"
        return 1
        ;;

      *)
        branches+=("$1")
        shift
        ;;
    esac
  done

  case "${#branches[@]}" in
    1)
      src_branch="${branches[0]}"
      target_branch="$original"
      ;;

    2)
      src_branch="${branches[0]}"
      target_branch="${branches[1]}"
      ;;

    *)
      err "Usage:"
      err "  gmerge <source> [<target>] [-p|--push]"
      return 1
      ;;
  esac

  if [[ "$src_branch" == "$target_branch" ]]; then
    err "Source and target branches must be different"
    return 1
  fi

  if [[ -n "$(git status --porcelain)" ]]; then
    err "Working tree is dirty — commit or stash first"
    return 1
  fi

  if git remote get-url origin >/dev/null 2>&1; then
    has_origin=1
  fi

  if (( push_after )) && (( ! has_origin )); then
    err "Cannot push — remote 'origin' does not exist"
    return 1
  fi

  lockdir="$(_tmp_dir)/git-merge.lock"

  if ! mkdir "$lockdir" 2>/dev/null; then
    err "Another merge is already running"
    return 1
  fi

  while :; do

    if (( has_origin )); then
      info "Fetching latest refs"

      if ! git fetch origin; then
        err "Failed to fetch origin"
        result=1
        break
      fi
    else
      info "No origin remote found — using local branches only"
    fi

    if ! git show-ref --verify --quiet "refs/heads/$src_branch"; then
      if (( has_origin )) &&
         git show-ref --verify --quiet "refs/remotes/origin/$src_branch"; then

        err "Source branch exists on origin but not locally: '$src_branch'"
        info "Create the local branch first:"
        info "  git switch --track origin/$src_branch"
      else
        err "Source branch does not exist: '$src_branch'"
      fi

      result=1
      break
    fi

    if ! git show-ref --verify --quiet "refs/heads/$target_branch"; then
      if (( has_origin )) &&
         git show-ref --verify --quiet "refs/remotes/origin/$target_branch"; then

        err "Target branch exists on origin but not locally: '$target_branch'"
        info "Create the local branch first:"
        info "  git switch --track origin/$target_branch"
      else
        err "Target branch does not exist: '$target_branch'"
      fi

      result=1
      break
    fi

    if (( has_origin )) &&
       git show-ref --verify --quiet "refs/remotes/origin/$src_branch"; then
      src_has_origin=1
    fi

    if (( has_origin )) &&
       git show-ref --verify --quiet "refs/remotes/origin/$target_branch"; then
      target_has_origin=1
    fi

    info "Preparing merge ($src_branch -> $target_branch)"

    local is_protected=0
    local protected

    for protected in $GHELPER_PROTECTED_BRANCHES; do
      if [[ "$target_branch" == "$protected" ]]; then
        is_protected=1
        break
      fi
    done

    if (( is_protected )); then
      local branch_upper="${target_branch^^}"

      warn "You are about to merge into ${branch_upper}"
      read -rp "Type '${target_branch}' to confirm: " confirm_reply

      if [[ "$confirm_reply" != "$target_branch" ]]; then
        info "Merge aborted"
        result=0
        break
      fi
    else
      read -rp "Continue? [y/n]: " confirm_reply

      if [[ ! "$confirm_reply" =~ ^[Yy]$ ]]; then
        info "Merge aborted"
        result=0
        break
      fi
    fi

    if [[ "$(git branch --show-current)" != "$src_branch" ]]; then
      info "Switching to $src_branch"

      if ! git switch "$src_branch"; then
        err "Failed to switch to $src_branch"
        result=1
        break
      fi
    fi

    if (( src_has_origin )); then
      info "Updating $src_branch from origin/$src_branch"

      if ! git merge --ff-only "origin/$src_branch"; then
        err "Could not fast-forward $src_branch"
        warn "Local and remote history may have diverged"
        warn "Resolve the branch manually before merging"
        result=1
        break
      fi
    else
      info "$src_branch has no origin branch — using local state"
    fi

    if [[ "$(git branch --show-current)" != "$target_branch" ]]; then
      info "Switching to $target_branch"

      if ! git switch "$target_branch"; then
        err "Failed to switch to $target_branch"
        result=1
        break
      fi
    fi

    if (( target_has_origin )); then
      info "Updating $target_branch from origin/$target_branch"

      if ! git merge --ff-only "origin/$target_branch"; then
        err "Could not fast-forward $target_branch"
        warn "Local and remote history may have diverged"
        warn "Resolve the branch manually before merging"
        result=1
        break
      fi
    else
      info "$target_branch has no origin branch — using local state"
    fi

    if git merge-base --is-ancestor "$src_branch" "$target_branch"; then
      info "$src_branch is already merged into $target_branch"
      result=0
      break
    fi

    info "Merging $src_branch into $target_branch"

    if ! git merge --no-ff "$src_branch" \
        -m "Merge $src_branch into $target_branch"; then

      # A real merge conflict leaves MERGE_HEAD behind.
      if git rev-parse --verify MERGE_HEAD >/dev/null 2>&1; then
        keep_target=1

        err "Merge conflicts detected on $target_branch"
        warn "The merge has been left in progress"
        info "Resolve the conflicts, then run:"
        info "  git add <files>"
        info "  git commit"
        log
        info "Or abort the merge with:"
        info "  git merge --abort"
      else
        err "Merge failed"
      fi

      result=1
      break
    fi

    if (( push_after )); then
      info "Pushing $target_branch"

      if ! git push origin "$target_branch"; then
        err "Push failed"
        warn "The local merge was kept on $target_branch"
        info "Push it manually when ready:"
        info "  git push origin $target_branch"

        result=1
        break
      fi

      ok "Merge successful ($src_branch -> $target_branch)"
      ok "$target_branch pushed to origin"

      result=0
      break
    fi

    ok "Merge successful ($src_branch -> $target_branch)"
    info "Merge is local only — $target_branch was not pushed"

    if (( target_has_origin )); then
      ahead="$(
        git rev-list --count "origin/$target_branch..$target_branch" \
          2>/dev/null || echo 0
      )"

      if (( ahead > 0 )); then
        info "$target_branch is ahead of origin/$target_branch by $ahead commit(s)"
      fi

      info "Push when ready with:"
      info "  git push origin $target_branch"
    else
      info "$target_branch does not currently exist on origin"

      if (( has_origin )); then
        info "Create and push it when ready with:"
        info "  git push -u origin $target_branch"
      fi
    fi

    info "Or use -p/--push with gmerge next time"

    result=0
    break
  done

  if (( ! keep_target )); then
    if [[ "$(git branch --show-current 2>/dev/null)" != "$original" ]]; then
      info "Returning to $original"

      if ! git switch "$original"; then
        err "Failed to return to original branch: $original"
        err "Switch back manually with:"
        err "  git switch $original"
        result=1
      fi
    fi
  fi

  rmdir "$lockdir" >/dev/null 2>&1 || true

  return "$result"
}

## Switch to a branch, pull from origin if available, then show status
gsw() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gsw <branch>

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  gsw main          # Switch to main and pull latest if behind
  gsw feature/foo   # Switch to local or remote branch

NOTES:
  - Creates a local tracking branch if only found on origin
  - Automatically pulls if the local branch is behind origin
  - Working tree must be clean before switching
EOF
    return 0
  fi

  local branch="$1"

  [[ -z "$branch" ]] && {
    err "Usage: gsw <branch>"
    return 0
  }

  groot "$@" || return 0

  if ! git diff --quiet || ! git diff --cached --quiet; then
    err "Working tree is dirty"
    err "Commit or stash your changes before switching branches"
    return 0
  fi

  git fetch --prune origin >/dev/null 2>&1 || {
    err "Failed to fetch origin"
    return 0
  }

  if git show-ref --verify --quiet "refs/heads/$branch"; then
    info "Switching to local branch '$branch'"
    git switch --quiet "$branch" || return 0
  elif git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    info "Creating local branch '$branch' from origin/$branch"
    git switch --quiet --track -c "$branch" "origin/$branch" || return 0
  else
    err "Branch does not exist locally or on origin: '$branch'"
    return 0
  fi

  if [[ -n "$(git status --porcelain)" ]]; then
    git status --short
  fi

  if git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    local ahead behind
    behind=$(git rev-list --count "HEAD..origin/$branch" 2>/dev/null || echo 0)
    ahead=$(git rev-list --count "origin/$branch..HEAD" 2>/dev/null || echo 0)

    if (( behind > 0 )); then
      info "Pulling latest changes from origin/$branch ($behind commit(s))"
      if ! git pull --ff-only --quiet origin "$branch"; then
        warn "Pull failed — resolve any conflicts or rebase manually"
        return 0
      fi
      ok "Switched to '$branch' and pulled latest changes"
    else
      ok "Switched to '$branch' (already up to date)"
    fi

    if (( ahead > 0 )); then
      warn "Local branch is ahead of origin/$branch by $ahead commit(s)"
    fi
  else
    ok "Switched to '$branch' (no origin branch)"
  fi
}

## Cherry-pick one or more commits to target branch
gcp() {
  local target current original commits=()
  local count=0

  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gcp <commit> [<commit>...] [--to <target-branch>]

OPTIONS:
  --to <branch>    Specify target branch (default: current branch)
  -h, --help       Show this help message

EXAMPLES:
  gcp abc123                    # Cherry-pick to current branch
  gcp abc123 def456             # Cherry-pick multiple commits
  gcp abc123 --to main          # Cherry-pick to specific branch
  gcp abc123 def456 --to main   # Multiple commits to specific branch

NOTES:
  - Cherry-pick copies commits, original commits remain on source branch
  - Working tree must be clean before cherry-picking
  - If conflicts occur, resolve and run: git cherry-pick --continue
EOF
    return 0
  fi

  [[ $# -lt 1 ]] && {
    err "Usage: gcp <commit> [<commit>...] [--to <target-branch>]"
    err "Run 'gcp --help' for more information"
    return 1
  }

  groot || return 1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --to)
        [[ -z "${2:-}" ]] && { err "Missing target branch for --to"; return 1; }
        target="$2"
        shift 2
        ;;
      *)
        commits+=("$1")
        shift
        ;;
    esac
  done

  [[ ${#commits[@]} -eq 0 ]] && {
    err "No commits specified"
    return 1
  }

  current=$(git branch --show-current 2>/dev/null) || {
    err "Detached HEAD — specify target with --to"
    return 1
  }

  target="${target:-$current}"

  for commit in "${commits[@]}"; do
    git rev-parse "$commit" >/dev/null 2>&1 || {
      err "Commit not found: $commit"
      return 1
    }
  done

  if ! git diff --quiet || ! git diff --cached --quiet; then
    err "Working tree is dirty"
    err "Commit or stash your changes before cherry-picking"
    return 1
  fi

  if [[ "$current" != "$target" ]]; then
    if ! git rev-parse --verify "$target" >/dev/null 2>&1; then
      err "Target branch does not exist: $target"
      return 1
    fi
    info "Switching to '$target'"
    git switch --quiet "$target" || {
      err "Failed to switch to $target"
      return 1
    }
    original="$current"
  fi

  for commit in "${commits[@]}"; do
    local hash msg
    hash=$(git rev-parse --short "$commit")
    msg=$(git log -1 --format=%s "$commit")

    info "Cherry-picking $hash: $msg"
    if ! git cherry-pick "$commit"; then
      warn "Cherry-pick failed — conflicts detected"
      warn "After resolving:"
      warn "  git cherry-pick --continue"
      warn "  or: git cherry-pick --abort"
      [[ -n "$original" ]] && warn "  or: git switch $original"
      return 1
    fi
    ((count++))
  done

  ok "Cherry-picked $count commit(s) to '$target'"
  [[ -n "$original" ]] && info "Note: switched from '$original' to '$target'"
}

## Delete local branches that no longer exist on origin
gcleanbranches() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gcleanbranches

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  gcleanbranches    # Delete local branches that no longer exist on origin

NOTES:
  - Skips current branch and branches listed in GHELPER_PROTECTED_BRANCHES
  - Prompts for confirmation before deleting
  - Fetches and prunes origin before scanning
EOF
    return 0
  fi

  local current reply branch
  local deleted=0 failed=0
  local -a local_branches=()
  local -a remote_branches=()
  local -a delete_candidates=()
  declare -A remote_lookup=()

  groot || return 0

  current=$(git branch --show-current 2>/dev/null) || {
    err "Not inside a git repository"
    return 0
  }

  [[ -n "$current" ]] || {
    err "Detached HEAD — switch to a branch first"
    return 0
  }

  if ! git remote get-url origin >/dev/null 2>&1; then
    err "Remote 'origin' does not exist"
    return 0
  fi

  info "Fetching latest remote refs"
  git fetch --prune origin >/dev/null 2>&1 || {
    err "Failed to fetch origin"
    return 0
  }

  while IFS= read -r branch; do
    [[ -z "$branch" || "$branch" == HEAD ]] && continue
    remote_branches+=("$branch")
    remote_lookup["$branch"]=1
  done < <(git for-each-ref --format='%(refname:strip=3)' refs/remotes/origin)

  while IFS= read -r branch; do
    [[ -n "$branch" ]] && local_branches+=("$branch")
  done < <(git branch --format='%(refname:short)')

  for branch in "${local_branches[@]}"; do
    [[ "$branch" == "$current" ]] && continue

    local skip=0
    for protected in $GHELPER_PROTECTED_BRANCHES; do
      [[ "$branch" == "$protected" ]] && { skip=1; break; }
    done
    (( skip )) && continue

    [[ -n "${remote_lookup[$branch]:-}" ]] && continue

    delete_candidates+=("$branch")
  done

  if [[ ${#delete_candidates[@]} -eq 0 ]]; then
    info "No local branches are missing from origin"
    return 0
  fi

  info "Local branches not found on origin:"
  for branch in "${delete_candidates[@]}"; do
    info "  - $branch"
  done

  warn "These local branches will be deleted"
  warn "Any unpushed commits on them will be lost"
  log

  confirm "Delete ${#delete_candidates[@]} local branch(es)?" || {
    err "Aborted"
    return 0
  }

  for branch in "${delete_candidates[@]}"; do
    info "Deleting local branch '$branch'"
    if git branch -D "$branch"; then
      deleted=$((deleted + 1))
    else
      failed=$((failed + 1))
    fi
  done

  (( failed > 0 )) && {
    err "Failed to delete $failed branch(es)"
    return 0
  }

  ok "Branch cleanup complete ($deleted deleted)"
}

# ==================================================
# Git release / promotion
# ==================================================

## Create annotated git tag for release
gtag() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gtag <version> [message]

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  gtag v1.2.0                      # Create an annotated tag with default message
  gtag v1.2.0 "Release v1.2.0"    # Create a tag with a custom message
EOF
    return 0
  fi

  if ! groot "$@"; then
    return 0
  fi

  if [ $# -lt 1 ]; then
    err "Usage: gtag <version> [message]"
    return 0
  fi

  local tag="$1"
  shift
  local msg="${*:-Release $tag}"

  git tag -a "$tag" -m "$msg" || true
  ok "Created tag $tag"
}

## Delete local git tag
gdtag() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gdtag <tag>

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  gdtag v1.2.0      # Delete the local tag v1.2.0
EOF
    return 0
  fi

  if ! groot "$@"; then
    return 0
  fi

  if [ $# -lt 1 ]; then
    err "Usage: gdtag <tag>"
    return 0
  fi

  local tag="$1"

  if ! git rev-parse "$tag" >/dev/null 2>&1; then
    err "Tag '$tag' does not exist"
    return 0
  fi

  git tag -d "$tag" || true
  ok "Deleted local tag $tag"
}

## Delete remote git tag
gdrtag() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gdrtag <tag> [remote]

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  gdrtag v1.2.0             # Delete tag v1.2.0 from origin
  gdrtag v1.2.0 upstream    # Delete tag v1.2.0 from a specific remote
EOF
    return 0
  fi

  if ! groot "$@"; then
    return 0
  fi

  if [ $# -lt 1 ]; then
    err "Usage: gdrtag <tag> [remote]"
    return 0
  fi

  local tag="$1"
  local remote="${2:-origin}"

  if ! git rev-parse "$tag" >/dev/null 2>&1; then
    err "Tag '$tag' does not exist"
    return 0
  fi

  git push "$remote" --delete "$tag" || true
  ok "Deleted remote tag $remote/$tag"
}

## Delete selected local git tags
gdtags() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gdtags

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  gdtags        # Interactively select local tags to delete (requires fzf)
EOF
    return 0
  fi

  if ! groot "$@"; then
    return 0
  fi

  command -v fzf >/dev/null || {
    err "fzf not installed"
    return 0
  }

  local tags
  tags="$(git tag | _fzf_multi --prompt="Select local tags to delete > ")" || return 0

  [[ -z "$tags" ]] && {
    info "No tags selected."
    return 0
  }

  warn "Deleting selected local tags:"
  log "$tags"
  log
  confirm "Continue?" || {
    info "Aborted."
    return 0
  }

  echo "$tags" | xargs -r -n 1 git tag -d || true

  ok "Selected local tags deleted."
}

## Delete selected remote git tags
gdrtags() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gdrtags [remote]

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  gdrtags             # Interactively select remote tags to delete from origin
  gdrtags upstream    # Interactively select remote tags to delete from a specific remote

NOTES:
  - Requires fzf
  - Also removes matching local tags
EOF
    return 0
  fi

  if ! groot "$@"; then
    return 0
  fi

  command -v fzf >/dev/null || {
    err "fzf not installed"
    return 0
  }

  local remote="${1:-origin}"

  if ! git remote get-url "$remote" >/dev/null 2>&1; then
    err "Remote '$remote' does not exist"
    return 0
  fi

  mapfile -t tags < <(
    git ls-remote --tags "$remote" \
      | awk -F/ '{print $3}' \
      | sed 's/\^{}//' \
      | sort -u \
      | _fzf_multi --prompt="Select remote tags to delete ($remote) > "
  ) || return 0

  [[ ${#tags[@]} -eq 0 ]] && {
    info "No tags selected."
    return 0
  }

  warn "Deleting selected remote tags from $remote:"
  printf '  %s\n' "${tags[@]}"
  log
  confirm "Continue?" || {
    info "Aborted."
    return 0
  }

  for tag in "${tags[@]}"; do
    if git rev-parse "$tag" >/dev/null 2>&1; then
      git tag -d "$tag" || warn "Failed local delete: $tag"
    fi
  done

  for tag in "${tags[@]}"; do
    git push "$remote" --delete "$tag" || warn "Failed remote delete: $tag"
  done

  ok "Selected remote tags deleted."
}

## Delete all git tags (local + remote)
gdatags() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gdatags [remote]

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  gdatags             # Delete ALL local and remote tags from origin
  gdatags upstream    # Delete ALL local and remote tags from a specific remote

NOTES:
  - This is destructive and difficult to undo
  - Prompts for confirmation before proceeding
EOF
    return 0
  fi

  local remote="${1:-origin}"

  if ! groot "$@"; then
    return 0
  fi

  mapfile -t tags < <(git tag)

  [[ ${#tags[@]} -eq 0 ]] && {
    info "No tags found."
    return 0
  }

  warn "This will DELETE ALL TAGS (local and remote: $remote)"
  warn "This action cannot be undone easily."
  log
  read -rp "Continue? [y/n]: " confirm
  [[ "$confirm" != "y" ]] && {
    info "Aborted."
    return 0
  }

  info "Deleting local tags..."
  for tag in "${tags[@]}"; do
    git tag -d "$tag" || warn "Failed local delete: $tag"
  done

  info "Deleting remote tags..."
  for tag in "${tags[@]}"; do
    git push "$remote" --delete "$tag" || warn "Failed remote delete: $tag"
  done

  ok "All tags processed."
}

## Promote source -> target and create a release tag
gpromote() {
  if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    cat <<'EOF'
USAGE:
  gpromote
  gpromote <source> <target>

OPTIONS:
  -h, --help    Show this help message

EXAMPLES:
  gpromote                  # Promote dev -> main (default)
  gpromote staging main     # Promote staging -> main

NOTES:
  - Must be run from the source branch
  - Rebases source onto origin/source before promoting
  - Creates an annotated timestamp tag after successful promote
  - Working tree must be clean
EOF
    return 0
  fi

  set -uo pipefail

  local SRC_BRANCH="dev"
  local TARGET_BRANCH="main"

  if [[ $# -eq 1 ]]; then
    err "Usage:"
    err "  gpromote                    # promote dev -> main"
    err "  gpromote <source> <target>  # promote source -> target"
    return 0
  elif [[ $# -eq 2 ]]; then
    SRC_BRANCH="$1"
    TARGET_BRANCH="$2"
  elif [[ $# -gt 2 ]]; then
    err "Too many arguments"
    err "Usage: gpromote <source> <target>"
    return 0
  fi

  if [[ "$SRC_BRANCH" == "$TARGET_BRANCH" ]]; then
    err "Source and target branches must be different"
    return 0
  fi

  if ! _branch_exists "$SRC_BRANCH"; then
    err "Source branch does not exist: '$SRC_BRANCH'"
    warn "Available branches:"
    git branch -a
    return 0
  fi

  if ! _branch_exists "$TARGET_BRANCH"; then
    err "Target branch does not exist: '$TARGET_BRANCH'"
    warn "Available branches:"
    git branch -a
    return 0
  fi

  LOCKDIR="$(_tmp_dir)/git-promote.lock"
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    err "Another promote is already running"
    return 0
  fi

  original=$(git branch --show-current)

  # shellcheck disable=SC2317,SC2329
  cleanup() {
    git rebase --abort >/dev/null 2>&1 || true
    git merge --abort >/dev/null 2>&1 || true
    git switch "$original" >/dev/null 2>&1 || \
      err "Manual switch to $original required"
    rmdir "$LOCKDIR" >/dev/null 2>&1 || true
  }

  trap cleanup RETURN
  trap 'err "Promote interrupted"; return 1' INT TERM

  if [[ "$original" != "$SRC_BRANCH" ]]; then
    err "Promote must be run from '$SRC_BRANCH' (current: $original)"
    return 0
  fi

  if ! git diff --quiet || ! git diff --cached --quiet; then
    err "Working tree is dirty — commit or stash first"
    return 0
  fi

  info "Fetching latest refs"
  git fetch origin || return 1

  if [[ -z "$(git log origin/"$TARGET_BRANCH".."$SRC_BRANCH" --oneline)" ]]; then
    info "Nothing to promote ($SRC_BRANCH == $TARGET_BRANCH)"
    return 0
  fi

  info "Rebasing $SRC_BRANCH onto origin/$SRC_BRANCH"
  if ! git rebase "origin/$SRC_BRANCH"; then
    err "Rebase failed — resolve conflicts on $SRC_BRANCH"
    warn "After resolving:"
    warn "  git rebase --continue"
    warn "  git push origin $SRC_BRANCH or promote"
    return 1
  fi

  info "Pushing $SRC_BRANCH"
  git push origin "$SRC_BRANCH" || return 1

  info "Switching to $TARGET_BRANCH"
  git switch "$TARGET_BRANCH" || return 1

  info "Pulling latest $TARGET_BRANCH"
  git pull origin "$TARGET_BRANCH" || return 1

  info "Fast-forwarding $TARGET_BRANCH -> $SRC_BRANCH"
  git merge --ff-only "$SRC_BRANCH" || return 1

  info "Pushing $TARGET_BRANCH"
  if ! git push origin "$TARGET_BRANCH"; then
    err "Push failed, rolling back local $TARGET_BRANCH"
    git reset --hard "origin/$TARGET_BRANCH"
    return 1
  fi

  info "Tagging promote"
  tag="promote-$SRC_BRANCH-to-$TARGET_BRANCH-$(date +%Y%m%d-%H%M%S)"
  git tag -a "$tag" -m "Promote $SRC_BRANCH -> $TARGET_BRANCH" || return 1
  git push origin "$tag" || return 1

  ok "Promote successful ($SRC_BRANCH -> $TARGET_BRANCH, tag: $tag)"
}
