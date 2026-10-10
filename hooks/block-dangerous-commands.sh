#!/usr/bin/env bash
# PreToolUse hook: block destructive shell commands before they run.
# Fires on the Bash tool and the Windows PowerShell tool (same `command` field).
#
# Design (chosen deliberately, see README):
#   1. FAIL CLOSED. Any internal error, missing dependency, or command this
#      script cannot confidently parse results in exit 2 (blocked), never a
#      silent pass. A regex filter is defense in depth, not a guarantee.
#   2. DELETES USE A PATH ALLOWLIST. A file-deletion command is allowed only
#      when every target is plainly local: a relative path with no `..`, or an
#      absolute path under the project dir or a temp dir. Any indirection in a
#      delete ($VAR, $(...), backtick, ~, quotes, eval, interpreters) is blocked
#      because the real target cannot be known from the text. Run those yourself.
#   3. DENYLIST FOR THE REST. git / database / cloud / infra / disk / system
#      operations that are irreversible but not path-shaped are matched by name.
#
# Exit 2 = block (stderr shown to Claude). Exit 0 = allow.
# NOTE: on native Windows without Git Bash, Claude Code runs hooks under
# PowerShell and this bash script will not execute; see README for that gap.

set -o pipefail
trap 'echo "BLOCKED: dangerous-command hook hit an internal error (failing closed)." >&2; exit 2' ERR

block() { echo "BLOCKED: $1" >&2; exit 2; }

# --- Dependencies: missing jq must fail closed, not disable the gate ---
command -v jq >/dev/null 2>&1 || block "jq is required by the safety hook but was not found."

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')

# Only inspect shell tools. Everything else passes.
case "$TOOL_NAME" in
  Bash|PowerShell) : ;;
  *) exit 0 ;;
esac

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
[ -z "$CMD" ] && exit 0

# Project root where the session started (used for the delete allowlist).
# Empty when unset: the allowlist then accepts only temp dirs and relative paths.
PROJ="${CLAUDE_PROJECT_DIR:-}"
TMP="${TMPDIR:-/tmp}"

# Normalize tabs and other blank runs to single spaces for keyword matching,
# while keeping a copy of the raw command for path/quote inspection.
NORM=$(printf '%s' "$CMD" | tr '\t\r\v\f' '    ' | tr -s ' ')
# Collapse the clobber-override redirects >| (noclobber override) and zsh >! to a
# plain `> ` so the pipe-splitter below does not mistake their `|` for a pipe and
# tear the redirect target off. All three clobber stdout the same way.
NORM=${NORM//'>|'/'> '}
NORM=${NORM//'>!'/'> '}
# Lowercased view for case-insensitive keyword families (Windows verbs, SQL).
LOW=$(printf '%s' "$NORM" | tr 'A-Z' 'a-z')

# Here-strings, not pipes: with pipefail, grep -q exiting early on a large
# command would SIGPIPE printf and turn a match into a silent pass.
m()  { grep -qE -e "$1" <<< "$NORM"; }   # match (case sensitive)
mi() { grep -qiE -e "$1" <<< "$LOW"; }   # match (case insensitive)

# ===========================================================================
# 0. UNIVERSAL PREFIXES / PRIVILEGE / OBFUSCATION-TO-SHELL
# ===========================================================================
# sudo/doas are caught per-segment below as the command head (check_segment),
# so a path form (/usr/bin/sudo), a wrapper (nice -n 5 sudo), a keyword (then
# sudo), bash -c 'sudo ...' or \sudo is caught without a loose regex that would
# also fire on the word "sudo" inside a string.
m '(^|[;&|(]\s*)su\s+-c\b'            && block "su -c should not be used."
m '(^|[;&|(]\s*)eval\s'               && block "eval can hide a destructive command from this check."
# macOS privilege escalation / arbitrary action via AppleScript, which hides the
# real command from this text check (and can pop a GUI admin-password prompt).
mi 'with administrator privileges|do shell script' && block "osascript 'do shell script' / 'with administrator privileges' hides the real command."

# Pipe-to-shell and decode-then-execute: the real command does not exist as text.
m '(curl|wget|fetch)\b[^|]*\|\s*(bash|sh|zsh|dash|ksh|pwsh|powershell)\b' \
  && block "piping a download straight into a shell."
m '\b(base64|xxd|openssl\s+enc|basenc)\b[^|]*\|\s*(bash|sh|zsh|dash|ksh)\b' \
  && block "decoding a blob straight into a shell."
m '(curl|wget|fetch)\b[^;&|]*-o\s+\S+.*(&&|;).*\b(bash|sh|zsh|source|\.)\s' \
  && block "download-then-execute pattern."

# ===========================================================================
# 1. INTERPRETER ONE-LINERS THAT DELETE  (target is unparseable -> always block)
# ===========================================================================
mi 'python[0-9.]*\s+(-[a-z]*\s+)*-c\b.*\b(shutil\.rmtree|os\.remove|os\.unlink|os\.rmdir|path\.unlink|pathlib)' \
  && block "python one-liner performing a delete. Run it yourself if intended."
mi 'node\b.*-e\b.*(rmsync|rmdirsync|unlinksync|\.rm\s*\(|\.rmdir\s*\(|\.unlink\s*\(|fs\.(rm|unlink|rmdir)|require\(.{0,3}fs)' \
  && block "node one-liner performing a delete. Run it yourself if intended."
mi 'perl\b.*(unlink|file::path|rmtree|remove_tree)' \
  && block "perl one-liner performing a delete. Run it yourself if intended."
mi 'ruby\b.*(fileutils\.rm|\.unlink|\.delete|rmtree)' \
  && block "ruby one-liner performing a delete. Run it yourself if intended."
mi 'php\b.*(unlink|rmdir|array_map\s*\(\s*["'\'']unlink)' \
  && block "php one-liner performing a delete. Run it yourself if intended."

# ===========================================================================
# 2. FILESYSTEM DELETION  (allowlist: local targets only)
# ===========================================================================
UNIX_DEL='rm|rmdir|unlink|shred|srm|grm|grmdir|gshred|zf_rm|zf_rmdir'
SHELLS='bash|sh|zsh|dash|ksh|fish'
# Shell keywords that can sit in front of the real command.
KEYWORDS='then|do|else|elif|if|while|until|!|\{|\}'
# Wrappers that run their arguments as a command. Their own flags/args vary, so
# after one of these the head is the first later token that names a command we
# care about (e.g. `timeout -s KILL 5 rm ...`, `nice -n 10 rm ...`).
WRAPPERS='command|builtin|exec|env|nice|nohup|time|stdbuf|timeout|gtimeout|caffeinate|ionice|chrt|taskset|watch|nocorrect|noglob'

# is_abs_local: absolute path inside the project or a temp dir.
is_abs_local() {
  local p="$1"
  if [ -n "$PROJ" ]; then
    [ "$p" = "$PROJ" ] && return 0
    case "$p" in "$PROJ"/*) return 0 ;; esac
  fi
  case "$p" in /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*|/var/tmp/*) return 0 ;; esac
  [ -n "$TMP" ] && case "$p" in "${TMP%/}"/*) return 0 ;; esac
  return 1
}

# Relative delete targets only count as local while the shell is known to be in
# the project or a temp dir. Start from the hook's cwd (the Bash tool's cwd
# persists between calls); a later `cd` somewhere unverifiable clears it.
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
REL_OK=1
[ -n "$PROJ" ] && [ -n "$CWD" ] && ! is_abs_local "$CWD" && REL_OK=0

# is_local_path: 0 = allowed local target, 1 = not clearly local -> block.
is_local_path() {
  local p="$1"
  case "$p" in
    "" | "~"* ) return 1 ;;
    /* ) is_abs_local "$p" && return 0; return 1 ;;
  esac
  [ "$REL_OK" = 1 ] || return 1
  case "/$p/" in */../*) return 1 ;; esac
  # Only dots, slashes and globs (., ./, ./*, .*, */, **) means "everything
  # here", not a specific target.
  case "$p" in *[!./*?]*) return 0 ;; esac
  return 1
}

# verb_name: normalize to the bare command name so \rm, "rm", r\m, =rm (zsh
# equiv of `which rm`), /bin/rm and /opt/homebrew/bin/grm all compare equal.
# Sets VN instead of printing: it runs for every token, so no subshell.
verb_name() {
  VN="${1//\\/}"                   # drop every backslash (r\m -> rm)
  VN="${VN//\"/}"; VN="${VN//\'/}" # drop quotes
  VN="${VN#=}"                     # zsh =rm -> rm
  VN="${VN##*/}"                   # drop directory part
}

# unquote: strip a leading and a trailing quote (sets UQ). Also cleans up the
# stray half-quote left when the separator split cut through a quoted string.
unquote() {
  UQ="${1#[\"\']}"; UQ="${UQ%[\"\']}"
}

# tokenize: split $1 on blanks into TOKS, keeping "..." / '...' runs and
# backslash escapes inside one token (quotes kept), so `cp x "/a b/c"` has the
# destination as a single token instead of `"/a` + `b/c"`.
tokenize() {
  TOKS=()
  local s="$1" cur="" q="" c i=0 len=${#1} have=0
  while [ $i -lt "$len" ]; do
    c="${s:$i:1}"; i=$((i+1))
    if [ "$c" = "\\" ] && [ "$q" != "'" ]; then cur+="$c${s:$i:1}"; i=$((i+1)); have=1; continue; fi
    if [ -n "$q" ]; then cur+="$c"; [ "$c" = "$q" ] && q=""; continue; fi
    case "$c" in
      \"|\') q="$c"; cur+="$c"; have=1 ;;
      ' ') [ $have = 1 ] && TOKS+=("$cur"); cur=""; have=0 ;;
      *) cur+="$c"; have=1 ;;
    esac
  done
  [ $have = 1 ] && TOKS+=("$cur")
  return 0
}

# Commands a wrapper may run that this hook cares about. After a wrapper, its
# own flags/args vary, so the head is the first later token naming one of these
# (`timeout -s KILL 5 rm ...`, `nice -n 10 sudo ...`).
WRAP_TARGETS="$UNIX_DEL|$SHELLS|find|xargs|cd|pushd|popd|sudo|doas|cp|mv|ditto|install|rsync|openrsync|tee|truncate|mkfile|dd|sed|gsed|tar|unzip|git|gh"

# find_head: tokenize $1 into TOKS and set HEAD (bare lowercase command name)
# and HEAD_I (its index), skipping VAR=value, shell keywords and wrappers.
# HEAD is empty when the segment runs nothing this hook cares about.
# Matching is case-insensitive: macOS's filesystem resolves RM to /bin/rm.
find_head() {
  tokenize "$1"
  HEAD=""; HEAD_I=0
  local n=${#TOKS[@]} i=0 t wrapped=0
  local kw_re="^($KEYWORDS)$" wr_re="^($WRAPPERS)$" tg_re="^($WRAP_TARGETS)$"
  shopt -s nocasematch
  while [ $i -lt "$n" ]; do
    t="${TOKS[$i]}"; verb_name "$t"
    if [ $wrapped = 1 ]; then
      [[ "$VN" =~ $tg_re ]] && { HEAD="$VN"; HEAD_I=$i; break; }
      i=$((i+1)); continue
    fi
    # Real VAR=value assignment (must start with an identifier char). This must
    # NOT swallow zsh `=rm` (starts with `=`), which verb_name turns into `rm`.
    if [[ "$t" == *=* && "$t" == [A-Za-z_]* ]]; then i=$((i+1)); continue; fi
    if [[ "$t" =~ $kw_re ]]; then i=$((i+1)); continue; fi
    if [[ "$VN" =~ $wr_re ]]; then wrapped=1; i=$((i+1)); continue; fi
    HEAD="$VN"; HEAD_I=$i; break
  done
  shopt -u nocasematch
  case "$HEAD" in *[A-Z]*) HEAD=$(printf '%s' "$HEAD" | tr 'A-Z' 'a-z') ;; esac
  return 0
}

# A write target is fine when it is a local path (same rule as deletes) or a
# throwaway device like /dev/null. Everything else (abs path outside proj/temp,
# ~, .., $VAR, backtick) is an overwrite we cannot vouch for. Quotes are
# stripped first, so `> "/etc/hosts"` is judged as /etc/hosts.
is_write_target_ok() {
  case "$1" in *[\`\$~]*) return 1 ;; esac
  unquote "$1"
  case "$UQ" in /dev/null|/dev/stdout|/dev/stderr|/dev/tty|/dev/zero|/dev/fd/*) return 0 ;; esac
  is_local_path "$UQ" && return 0
  return 1
}

# Output redirects: > >| >! and fd forms 1> 2> (not >>, not >&N). Targets may
# be quoted with spaces.
check_redirects() {
  local tgt
  while IFS= read -r tgt; do
    [ -z "$tgt" ] && continue
    is_write_target_ok "$tgt" || block "overwrites a file outside the project/temp dirs via redirect ('$tgt'). Run it yourself if intended."
  done < <(grep -oE '(^|[^>&])[0-9]*>[|!]?[[:space:]]*("[^"]*"|'\''[^'\'']*'\''|[^>|!&;[:space:]]+)' <<< "$1" | sed -E 's/^[^>]*>[|!]?[[:space:]]*//')
  return 0
}

# ---------------------------------------------------------------------------
# Git writes and GitHub PR actions.
# git add / commit / push are allowed only while a non-protected branch is
# checked out, read from the real repo (not the command text). Pushes may only
# land on non-protected branches. gh may open and read PRs, never merge,
# approve, review, close, reopen, edit or comment on them.
# ---------------------------------------------------------------------------
# Branches Claude may never stage on, commit to or push to. The remote default
# branch (origin/HEAD) is always added as well.
PROTECTED_BRANCHES='main|master|production|prod|release|staging|develop'

GIT_CWD="${CWD:-$PWD}"
GIT_CTX_CHANGED=0   # a cd / checkout / switch ran earlier in this command
PROTECTED_RE=""

git_q() { git -C "$GIT_CWD" "$@" 2>/dev/null; }

is_protected() {
  if [ -z "$PROTECTED_RE" ]; then
    local def
    def=$(git_q symbolic-ref --quiet --short refs/remotes/origin/HEAD) || def=""
    def="${def#origin/}"
    PROTECTED_RE="^($PROTECTED_BRANCHES${def:+|$def})$"
  fi
  [[ "$1" =~ $PROTECTED_RE ]]
}

# Subcommands that move HEAD or the repo, so a later write would land on a
# branch this hook did not check.
GIT_MOVES='checkout|switch|symbolic-ref|worktree|branch|update-ref|rebase|init'

# check_git: TOKS / HEAD_I point at a `git` command.
check_git() {
  local n=${#TOKS[@]} j=$((HEAD_I+1)) t sub cur
  unquote "${TOKS[$j]:-}"; sub="$UQ"
  case "$sub" in
    -*)
      # Global options (-C, -c, --git-dir, --work-tree...) can point git at
      # another repo or alias a verb, so writes behind them are not allowed.
      while [ $j -lt "$n" ]; do
        unquote "${TOKS[$j]}"; j=$((j+1))
        [[ "$UQ" =~ ^(add|commit|push)$ ]] && block "git global options before $UQ (-C, -c, --git-dir...). Run plain git $UQ from the repo dir."
        [[ "$UQ" =~ ^($GIT_MOVES)$ ]] && GIT_CTX_CHANGED=1
      done
      return 0 ;;
    add|commit|push) ;;
    *) [[ "$sub" =~ ^($GIT_MOVES)$ ]] && GIT_CTX_CHANGED=1; return 0 ;;
  esac

  [ "$GIT_CTX_CHANGED" = 1 ] && block "git $sub after a cd/checkout/switch in the same command: the branch it lands on cannot be checked. Run git $sub as its own command."
  case "$NORM" in *GIT_DIR*|*GIT_WORK_TREE*|*GIT_INDEX_FILE*|*GIT_NAMESPACE*|*GIT_CONFIG*)
    block "git $sub with a GIT_* environment override." ;;
  esac
  cur=$(git_q symbolic-ref --quiet --short HEAD) || cur=""
  [ -z "$cur" ] && block "git $sub: could not read the current branch (detached HEAD or not a repo)."
  # Pushes are judged by where they land (check_git_push), not by HEAD.
  [ "$sub" != push ] && is_protected "$cur" \
    && block "git $sub on protected branch '$cur'. Create a feature branch first (git checkout -b <name>)."

  j=$((j+1))
  case "$sub" in
    commit)
      while [ $j -lt "$n" ]; do
        t="${TOKS[$j]}"; j=$((j+1))
        case "$t" in
          --amend|--amend=*) block "git commit --amend rewrites an existing commit." ;;
          --no-verify) block "git commit --no-verify skips the repo hooks." ;;
        esac
        [[ "$t" =~ ^-[a-zA-Z]*n[a-zA-Z]*$ ]] && block "git commit -n skips the repo hooks."
      done ;;
    push)
      check_git_push "$cur" ;;
  esac
  return 0
}

# check_git_push: TOKS from index j are the push arguments. $1 = current branch.
check_git_push() {
  local cur="$1" t pos=() remote spec src dst
  while [ $j -lt "$n" ]; do
    unquote "${TOKS[$j]}"; t="$UQ"; j=$((j+1))
    case "$t" in
      -u|--set-upstream|-v|--verbose|-q|--quiet|--progress|--no-progress|-n|--dry-run|--porcelain|--atomic) ;;
      --force-with-lease|--force-with-lease=*|--force-if-includes) ;;
      -*) block "git push option '$t' is not allowed (allowed: -u, -v, -q, -n, --dry-run, --force-with-lease)." ;;
      *[\`\$\"\'\*\?\\]*) block "git push argument '$t' has a quote, variable or glob. Name the remote and branch plainly." ;;
      *) pos+=("$t") ;;
    esac
  done

  remote="${pos[0]:-}"
  if [ -n "$remote" ]; then
    grep -qxF -- "$remote" <<< "$(git_q remote)" \
      || block "git push to '$remote', which is not a configured remote."
  fi

  if [ ${#pos[@]} -le 1 ]; then
    # No refspec: git pushes the current branch to its push target.
    [ "$(git_q config push.default)" = matching ] \
      && block "git push with push.default=matching pushes every branch. Use git push origin <branch>."
    dst=$(git_q for-each-ref --format='%(push:remoteref)' "refs/heads/$cur") || dst=""
    dst="${dst#refs/heads/}"
    is_protected "${dst:-$cur}" && block "git push from '$cur' goes to protected branch '${dst:-$cur}'."
    return 0
  fi

  for spec in "${pos[@]:1}"; do
    case "$spec" in
      *:*) src="${spec%%:*}"; dst="${spec#*:}" ;;
      *)   src="$spec"; dst="$spec"
           [ "$src" = HEAD ] && dst="$cur"
           [ "$src" = HEAD ] || git_q show-ref --verify --quiet "refs/heads/$src" \
             || block "git push '$src' is not a local branch (tags and other refs are not allowed)." ;;
    esac
    [ -z "$src" ] && block "git push :$dst deletes a remote branch."
    case "$dst" in
      refs/heads/*) dst="${dst#refs/heads/}" ;;
      refs/*|HEAD|"") block "git push to '$dst' (only named branches are allowed)." ;;
    esac
    is_protected "$dst" && block "git push to protected branch '$dst'. Push a feature branch and open a PR instead."
  done
  return 0
}

GH_BUILTINS='agent-task|alias|api|attestation|auth|browse|cache|codespace|completion|config|copilot|extension|gist|gpg-key|help|issue|label|org|pr|preview|project|release|repo|ruleset|run|search|secret|ssh-key|status|variable|version|workflow'

# check_gh: TOKS / HEAD_I point at a `gh` command.
check_gh() {
  local n=${#TOKS[@]} j=$((HEAD_I+1)) args=() top sub="" k a
  while [ $j -lt "$n" ]; do unquote "${TOKS[$j]}"; args+=("$UQ"); j=$((j+1)); done
  top="${args[0]:-}"
  case "$top" in ""|-*) return 0 ;; esac
  [[ "$top" =~ ^($GH_BUILTINS)$ ]] \
    || block "gh $top is not a built-in gh command (an alias or extension can run anything, including a merge)."
  # Subcommand: first non-flag after the command; only -R/--repo may come first.
  k=1
  while [ $k -lt ${#args[@]} ]; do
    case "${args[$k]}" in
      -R|--repo) k=$((k+2)) ;;
      --repo=*) k=$((k+1)) ;;
      -*) [ "$top" = api ] && break
          block "gh $top with a flag before the subcommand ('${args[$k]}')." ;;
      *) sub="${args[$k]}"; break ;;
    esac
  done

  case "$top" in
    pr)
      case "$sub" in
        ""|create|view|list|status|diff|checks) ;;
        checkout) GIT_CTX_CHANGED=1 ;;
        edit)
          # Title, body, labels, reviewers are fine; the target branch is not.
          for a in "${args[@]}"; do
            case "$a" in -B|--base|--base=*|-B?*)
              block "gh pr edit --base changes which branch the PR merges into. Do that yourself." ;;
            esac
          done ;;
        *) block "gh pr $sub is for you to do. Claude may open, read and edit PRs, not merge, approve, review, close, reopen or comment." ;;
      esac ;;
    api) check_gh_api ;;
    extension) [[ "$sub" =~ ^(install|upgrade|exec|create)$ ]] && block "gh extension $sub runs third-party code." ;;
    repo) [[ "$sub" =~ ^(delete|edit|rename|archive|unarchive|sync)$ ]] && block "gh repo $sub changes or deletes the repo." ;;
    release) [[ "$sub" =~ ^(create|delete|delete-asset|edit|upload)$ ]] && block "gh release $sub publishes or deletes a release." ;;
    workflow) [[ "$sub" =~ ^(run|enable|disable)$ ]] && block "gh workflow $sub." ;;
    run) [[ "$sub" =~ ^(cancel|rerun|delete)$ ]] && block "gh run $sub." ;;
    secret|variable) [[ "$sub" =~ ^(set|delete|remove)$ ]] && block "gh $top $sub." ;;
    issue) [[ "$sub" =~ ^(close|delete|transfer|lock)$ ]] && block "gh issue $sub." ;;
    auth) [[ "$sub" =~ ^(logout|token|refresh|switch|setup-git)$ ]] && block "gh auth $sub touches your GitHub login." ;;
  esac
  return 0
}

# gh api is allowed read-only: GET without fields, or a GraphQL query with no
# mutation. Anything else can merge, approve or close through the raw API.
check_gh_api() {
  local k=1 a method="" fields=0 graphql=0
  while [ $k -lt ${#args[@]} ]; do
    a="${args[$k]}"; k=$((k+1))
    case "$a" in
      -X|--method) method="${args[$k]:-}"; k=$((k+1)) ;;
      -X*) method="${a#-X}" ;;
      --method=*) method="${a#--method=}" ;;
      -f|-F|--field|--raw-field|-f?*|-F?*|--field=*|--raw-field=*) fields=1 ;;
      --input|--input=*) block "gh api --input sends a request body from a file." ;;
      graphql) graphql=1 ;;
    esac
  done
  method=$(printf '%s' "$method" | tr 'a-z' 'A-Z')
  if [ $graphql = 1 ]; then
    grep -qi 'mutation' <<< "$NORM" && block "gh api graphql mutation."
    case "$NORM" in *=@*) block "gh api graphql with a query read from a file." ;; esac
    return 0
  fi
  [ -n "$method" ] && [ "$method" != GET ] && block "gh api $method is a write. Only GET is allowed."
  [ $fields = 1 ] && [ "$method" != GET ] && block "gh api with fields sends a POST. Only reads are allowed."
  return 0
}

# Check one command segment (already split on separators). $1 = segment.
check_segment() {
  local seg="$1" IFS=' ' t k j n i r
  case "$seg" in *'>'*) check_redirects "$seg" ;; esac   # skip grep+sed on lines with no redirect
  find_head "$seg"
  # A git/gh write behind a runner that takes a command as arguments cannot be
  # checked against the current branch.
  case "$HEAD" in ""|xargs|find|fd|parallel)
    [[ "$seg" =~ (^|[^[:alnum:]_.-])(git[[:space:]]+(add|commit|push)|gh[[:space:]]+(pr|api))([^[:alnum:]_-]|$) ]] \
      && block "git/gh write run through ${HEAD:-a wrapper}. Run it as a plain git or gh command." ;;
  esac
  [ -z "$HEAD" ] && return 0
  i=$HEAD_I; n=${#TOKS[@]}
  local rest="${TOKS[*]:$((i+1))}"

  # ---- Deletes: every operand must be a plainly-local path. ----
  local del_re="^($UNIX_DEL)$"
  if [[ "$HEAD" =~ $del_re ]]; then
    case "${TOKS[*]:$i}" in
      *[\`\$~\"\']* | *..* )
        block "delete with a variable, substitution, quote, ~, or .. in the target. Run it yourself if intended." ;;
    esac
    local endopts=0
    j=$((i+1))
    while [ $j -lt "$n" ]; do
      t="${TOKS[$j]}"; j=$((j+1))
      if [ $endopts = 0 ]; then
        [ "$t" = "--" ] && { endopts=1; continue; }
        case "$t" in -*) continue ;; esac
      fi
      is_local_path "$t" || block "delete targets a path outside the project/temp dirs, or everything in the current dir ('$t'). Run it yourself if intended."
    done
    return 0
  fi

  case "$HEAD" in
    sudo|doas)
      block "sudo/doas should not be used." ;;

    git) check_git ;;
    gh)  check_gh ;;

    set-location|sl|chdir|push-location|pop-location)
      GIT_CTX_CHANGED=1 ;;

    cd|pushd)
      GIT_CTX_CHANGED=1
      # Track where relative paths now point. Unverifiable destinations (bare
      # cd = home, cd -, ~, $VAR, .., outside project/temp) make them unsafe.
      local dest="$rest"
      case "$dest" in \"*\"|\'*\') unquote "$dest"; dest="$UQ" ;; esac
      case "$dest" in
        "" | - | *[\`\$~\"\']* ) REL_OK=0 ;;
        /* ) if is_abs_local "$dest"; then REL_OK=1; else REL_OK=0; fi ;;
        * ) case "/$dest/" in */../*) REL_OK=0 ;; esac ;;
      esac ;;

    popd)
      GIT_CTX_CHANGED=1; REL_OK=0 ;;

    bash|sh|zsh|dash|ksh|fish)
      # `bash -c '<cmd>'`: check the inner command like any other segment.
      k=$((i+1))
      while [ $k -lt "$n" ]; do
        case "${TOKS[$k]}" in -*c) [ $((k+1)) -lt "$n" ] && { unquote "${TOKS[$((k+1))]}"; check_segment "$UQ"; }; break ;; esac
        k=$((k+1))
      done ;;

    xargs)
      # Targets come from stdin and cannot be verified.
      local x_re="(^|[^[:alnum:]_])($UNIX_DEL|sudo|doas)([^[:alnum:]_]|$)"
      [[ "$rest" =~ $x_re ]] \
        && block "xargs running a delete or sudo (targets come from stdin and cannot be verified). Run it yourself if intended." ;;

    find)
      grep -qiE -e "-delete\b|-exec(dir)? (\S*/)?\\\\?($UNIX_DEL)\b" <<< "$rest" || return 0
      case "$rest" in *[\`\$~]*|*..*) block "find-delete with a variable/substitution/~/.. target. Run it yourself if intended." ;; esac
      # Search roots are the tokens before the first option/expression.
      local roots=0
      k=$((i+1))
      while [ $k -lt "$n" ]; do
        r="${TOKS[$k]}"; k=$((k+1))
        case "$r" in -* | \( | \\\( | !) break ;; esac
        unquote "$r"; r="$UQ"
        roots=1
        case "$r" in .|./) [ "$REL_OK" = 1 ] && continue ;; esac   # find . <filter> -delete
        is_local_path "$r" || block "find-delete rooted outside the project/temp dirs ('$r'). Run it yourself if intended."
      done
      [ $roots = 0 ] && [ "$REL_OK" != 1 ] && block "find-delete in a directory outside the project/temp dirs. Run it yourself if intended." ;;

    # ---- Overwrites: only the operand that IS the write target is checked, so
    # reading an outside file (`cp /etc/hosts ./`) stays allowed. ----
    truncate|mkfile|tee)
      # tee -a / --append only appends, so it is not a clobber.
      local a_re=' (-[A-Za-z]*a[A-Za-z]*|--append) '
      [ "$HEAD" = tee ] && [[ " $rest " =~ $a_re ]] && return 0
      for t in "${TOKS[@]:$((i+1))}"; do
        case "$t" in -*) continue ;; esac
        is_write_target_ok "$t" || block "$HEAD overwrites a file outside the project/temp dirs ('$t'). Run it yourself if intended."
      done ;;

    dd)
      for t in "${TOKS[@]:$((i+1))}"; do
        case "$t" in of=*) is_write_target_ok "${t#of=}" || block "dd writes to a target outside the project/temp dirs ('${t#of=}'). Run it yourself if intended." ;; esac
      done ;;

    sed|gsed)
      # Only -i edits files. The first operand is the script unless -e/-f gave
      # it; BSD `-i ''` / `-i .bak` takes the backup suffix as its own arg.
      local inplace=0 script_given=0 skip=0 files=()
      j=$((i+1))
      while [ $j -lt "$n" ]; do
        t="${TOKS[$j]}"; j=$((j+1))
        if [ $skip = 1 ]; then skip=0; continue; fi
        case "$t" in
          --in-place*) inplace=1 ;;
          --expression|--file) script_given=1; skip=1 ;;
          --expression=*|--file=*) script_given=1 ;;
          --*) : ;;
          -i|-I)
            inplace=1
            case "${TOKS[$j]}" in "''"|'""'|.*) j=$((j+1)) ;; esac ;;
          -*)
            case "$t" in -*[iI]*) inplace=1 ;; esac
            case "$t" in -*[ef]) script_given=1; skip=1 ;; esac ;;
          *) files+=("$t") ;;
        esac
      done
      [ $inplace = 1 ] || return 0
      [ $script_given = 0 ] && [ ${#files[@]} -gt 0 ] && files=("${files[@]:1}")
      for t in ${files[@]+"${files[@]}"}; do
        is_write_target_ok "$t" || block "sed -i edits a file outside the project/temp dirs ('$t'). Run it yourself if intended."
      done ;;

    cp|mv|ditto|install|rsync|openrsync)
      local ops=()
      for t in "${TOKS[@]:$((i+1))}"; do case "$t" in -*) continue ;; esac; ops+=("$t"); done
      [ ${#ops[@]} -eq 0 ] && return 0
      local last="${ops[${#ops[@]}-1]}"
      unquote "$last"
      case "$UQ" in
        /dev/stdout|/dev/stderr|/dev/tty|/dev/fd/*) : ;;   # printing to a stream is harmless
        /dev/*) block "$HEAD writes onto a device node or discards data to '$UQ'. Run it yourself if intended." ;;
        *) is_write_target_ok "$last" || block "$HEAD writes into a path outside the project/temp dirs ('$last'). Run it yourself if intended." ;;
      esac
      # mv removes its sources, so they must be local too (otherwise
      # `mv ~/Documents /tmp/x` then a "local" delete of /tmp/x gets through).
      if [ "$HEAD" = mv ]; then
        for t in "${ops[@]:0:${#ops[@]}-1}"; do
          is_write_target_ok "$t" || block "mv removes its source, and '$t' is outside the project/temp dirs. Run it yourself if intended."
        done
      fi ;;

    tar)
      local extract=0 dir="" first=1
      j=$((i+1))
      while [ $j -lt "$n" ]; do
        t="${TOKS[$j]}"; j=$((j+1))
        case "$t" in
          --extract|--get) extract=1 ;;
          --directory=*) dir="${t#--directory=}" ;;
          --directory|-C) dir="${TOKS[$j]}"; j=$((j+1)) ;;
          -C?*) dir="${t#-C}" ;;
          --*) : ;;
          -*x*) extract=1 ;;
          *) [ $first = 1 ] && case "$t" in *[!A-Za-z]*) : ;; *x*) extract=1 ;; esac ;;   # old-style `tar xf`
        esac
        first=0
      done
      [ $extract = 1 ] || return 0
      if [ -n "$dir" ]; then
        is_write_target_ok "$dir" || block "tar extracts into a path outside the project/temp dirs ('$dir'). Run it yourself if intended."
      else
        [ "$REL_OK" = 1 ] || block "tar extracts into the current dir, which is outside the project/temp dirs. Run it yourself if intended."
      fi ;;

    unzip)
      local dir="" listonly=0
      j=$((i+1))
      while [ $j -lt "$n" ]; do
        t="${TOKS[$j]}"; j=$((j+1))
        case "$t" in
          -d) dir="${TOKS[$j]}"; j=$((j+1)) ;;
          -l|-t|-v|-Z|-p|-z) listonly=1 ;;
        esac
      done
      [ $listonly = 1 ] && return 0
      if [ -n "$dir" ]; then
        is_write_target_ok "$dir" || block "unzip extracts into a path outside the project/temp dirs ('$dir'). Run it yourself if intended."
      else
        [ "$REL_OK" = 1 ] || block "unzip extracts into the current dir, which is outside the project/temp dirs. Run it yourself if intended."
      fi ;;
  esac
  return 0
}

# Split on every command separator (incl. backticks) and check each piece in
# order, so a `cd` earlier in the command is seen before a later delete/write.
# `set -f` stops the unquoted expansion from glob-matching a literal * on disk.
set -f
OLDIFS="$IFS"; IFS=$'\n'
for SEG in $(printf '%s' "$NORM" | sed -E 's/(&&|\|\||;|&|\||\(|\)|`)/\n/g'); do
  check_segment "$SEG"
done
IFS="$OLDIFS"
set +f

# Truncation / clobber of a file.
m '(^|[;&|]\s*):\s*>' && block "file truncation via : > pattern."

# ===========================================================================
# 3. WINDOWS DELETION & QUOTING TRAP  (relevant when this .sh runs in Git Bash)
# ===========================================================================
# The Oct 2026 C: wipe was `cmd /c "rmdir /s /q \"...\""`. PowerShell 5.1 and cmd
# mangle the \" so the path collapses to a bare `\` (drive root). We cannot trust
# any recursive cmd delete wrapped in cmd /c, so block the whole class.
mi 'cmd(\.exe)?\s+/{1,2}[ck]\b.*\b(rmdir|rd|del|erase)\b' \
  && block "cmd /c recursive delete (PowerShell/cmd quote mangling can redirect this to a drive root)."
mi '\b(rmdir|rd)\b[^|;&]*\s/s\b' \
  && block "rmdir /s recursive delete."
mi '\b(del|erase)\b[^|;&]*\s/(s|q|f)\b' \
  && block "del/erase with /s /q /f."
mi '\bforfiles\b[^|;&]*\b(del|erase|rd|rmdir)\b' \
  && block "forfiles invoking a delete."
# Drive-root and home spellings in any delete-ish context.
mi '(remove-item|clear-content|clear-item|\bri\b|\brm\b|\brd\b|\brmdir\b|\bdel\b|\berase\b)[^|;&]*(\\\\\?\\|\\\\\.\\|(^|[ "'\''])[a-z]:([\\/ ]|$)|\$env:(userprofile|systemdrive|systemroot|homepath)|\$home\b|c:\\users)' \
  && block "Windows delete/clear targeting a drive root, device path, or user profile."
mi 'remove-item\b[^|;&]*-(recurse|r)\b[^|;&]*-(force|fo)\b' \
  && block "Remove-Item -Recurse -Force (verify the target manually)."

# Windows disk / recovery / backup destruction.
mi '\bdiskpart\b'                                        && block "diskpart (clean/format wipes partitions)."
mi '\b(format)\s+[a-z]:'                                 && block "format of a drive."
mi '\b(clear-disk|remove-partition|format-volume|clear-volume|initialize-disk)\b' \
  && block "PowerShell disk/partition wipe."
mi '\bvssadmin\b[^|;&]*\bdelete\b'                       && block "vssadmin delete shadows (anti-recovery)."
mi '\bwmic\b[^|;&]*shadowcopy[^|;&]*delete'              && block "wmic shadowcopy delete (anti-recovery)."
mi '\bwbadmin\b[^|;&]*\bdelete\b'                        && block "wbadmin delete (anti-recovery)."
mi '\bbcdedit\b[^|;&]*(recoveryenabled\s+no|bootstatuspolicy\s+ignoreallfailures)' \
  && block "bcdedit disabling recovery (anti-recovery)."
mi '\breagentc\b[^|;&]*/disable'                         && block "reagentc /disable (anti-recovery)."
mi '\bcipher\b[^|;&]*/w'                                 && block "cipher /w wipes free space."
mi '\bwsl\b[^|;&]*--unregister\b'                        && block "wsl --unregister permanently deletes a distro."
mi '\brobocopy\b[^|;&]*\s/(mir|purge|move|mov)\b'        && block "robocopy /MIR /PURGE /MOVE deletes destination/source files."
mi '\breg\b[^|;&]*\bdelete\b[^|;&]*/f'                   && block "reg delete /f."
# PowerShell encoded command hides the real script from this text check.
mi '\b(powershell|pwsh)(\.exe)?\b[^|;&]*\s-(e|en|enc|enco|encod|encode|encoded|encodedcommand)\b' \
  && block "powershell -EncodedCommand hides the real command."
mi '\bclear-recyclebin\b'                                && block "Clear-RecycleBin empties the Recycle Bin."
mi '\b(remove-localuser|disable-computerrestore|remove-computerrestorepoint)\b' && block "removes a local user / disables System Restore."
mi '\bnet\b\s+(user|localgroup)\b[^|;&]*/del'           && block "net user/localgroup /delete removes an account."
mi '(^|[^a-z])sc(\.exe)?\s+delete\b|\bschtasks\b[^|;&]*/delete'  && block "sc delete / schtasks /delete removes a service or task."
mi '\b(takeown|icacls)\b[^|;&]*(\\\\|[a-z]:\\(\s|$)|[a-z]:\\users|/reset[^|;&]*/t\b)' && block "takeown/icacls rewriting ownership or ACLs on a drive/system path."
mi '\bfsutil\b[^|;&]*(setzerodata|deletejournal|\bdelete\b)' && block "fsutil zeroing data / deleting the USN journal."
mi '\bsdelete(64)?\b'                                    && block "sdelete securely wipes files/free space."
mi '\bdism\b[^|;&]*(/disable-feature|/remove-)'         && block "dism disabling/removing a Windows feature or package."

# ===========================================================================
# 4. UNIX DISK / FILESYSTEM / SYSTEM DESTRUCTION
# ===========================================================================
m '\bdd\b[^|;&]*of=/dev/'                                && block "dd writing to a device."
m '\bmkfs(\.[a-z0-9]+)?\b'                               && block "mkfs formats a filesystem."
m '\b(wipefs|blkdiscard|mkswap)\b'                       && block "low-level disk wipe."
m '\b(fdisk|sfdisk|gdisk|sgdisk|parted|cfdisk)\b'       && block "partition-table editor."
m '\b(lvremove|vgremove|pvremove)\b'                     && block "LVM volume removal."
m '\b(zpool\s+destroy|zfs\s+destroy|btrfs\s+subvolume\s+delete)\b' && block "ZFS/btrfs destroy."
m '\bcryptsetup\b[^|;&]*(luksformat|erase)'             && block "cryptsetup format/erase."
mi '\bdiskutil\b[^|;&]*(erase\w*|reformat|zerodisk|randomdisk|partitiondisk|secureerase|mergepartitions|splitpartition|resizevolume|(\b(apfs|ap|appleraid|ar|corestorage|cs)\s+(delete\w*|erase\w*|remove|revert|decryptvolume|resizecontainer|changepassphrase)))' \
  && block "diskutil erase/reformat/partition/apfs-delete."
# Other macOS disk/format/reinstall tools (verified against local man pages).
m '\bnewfs_[a-z0-9]+\b'                                  && block "newfs_* formats a volume."
m '(^|[[:space:];&|(/])gpt\s+(-\S+\s+)*(destroy|remove|create|migrate)\b|\b(pdisk|apfs_hfs_convert)\b' && block "GPT/partition rewrite."
mi '\basr\b[^|;&]*\brestore\b|\bhdiutil\b[^|;&]*\berasekeys\b' && block "asr restore / hdiutil erasekeys destroys the target."
m '\b(startosinstall|eraseinstall)\b'                   && block "startosinstall --eraseinstall wipes the Mac."
m '(of=|>[[:space:]]*)/dev/r?disk[0-9]'                 && block "writing straight to a disk device (/dev/diskN)."
mi '\btmutil\b[^|;&]*\b(delete\w*|thin\w*|disable\w*|removedestination|setdestination|restore|inheritbackup|associatedisk|setquota)\b' \
  && block "tmutil delete/disable/restore/destination change (Time Machine)."
# Keychain / stored credentials (your own login keychain, no root needed).
mi '\bsecurity\b[^|;&]*\b(delete-keychain|delete-(generic|internet)-password|delete-certificate|delete-identity|set-keychain-(password|settings)|add-trusted-cert|remove-trusted-cert|trust-settings-import|authorizationdb\s+(write|remove|merge))\b' \
  && block "security deletes/alters a keychain or trust settings."
mi '\bsecurity\b[^|;&]*\b(list|default|login)-keychains?\b[^|;&]*\s-s\b' && block "security replaces the keychain search list."
m 'git\s+credential(-osxkeychain)?\s+(erase|reject)\b'  && block "git credential erase removes the stored login."
# AppleScript-driven app deletes (spread via iCloud) + empty trash.
mi '\bosascript\b[^|;&]*(empty( the)? trash|\bdelete\b|\berase\b)' && block "osascript emptying trash / deleting app items."
m '\b(shortcuts\s+run|automator)\b'                     && block "shortcuts/automator runs saved actions this check cannot see."
# User accounts / passwords / FileVault / privacy & prefs.
mi '\bsysadminctl\b[^|;&]*-(deleteuser|resetpasswordfor|securetokenoff|autologin|guestaccount|screenlock)\b' && block "sysadminctl account/token/password change."
mi '\bdscl\b[^|;&]*\s-(delete|create|change|passwd|append|merge)\b' && block "dscl modifies the directory/account database."
mi '\bdseditgroup\b[^|;&]*(-o\s+delete|\s-d\s)|\bpwpolicy\b[^|;&]*(disableuser|setpassword|setaccountpolicies)|\b(dsenableroot|dsimport)\b' && block "group/password-policy/root change."
mi '\bfdesetup\b[^|;&]*\b(disable|remove|removerecovery|changerecovery|authrestart)\b' && block "fdesetup disables FileVault or rotates recovery."
mi '\bprofiles\b[^|;&]*(\bremove\b|\s-[dr]\b)'           && block "profiles remove strips MDM/config profiles."
mi '\btccutil\b[^|;&]*\breset\b'                        && block "tccutil reset wipes privacy permissions."
mi '\bdefaults\b[^|;&]*\b(delete|delete-all)\b|/usr/libexec/plistbuddy\b[^|;&]*\b(clear|delete)\b|\bplutil\b[^|;&]*-remove\b' && block "defaults/plist destructive write to a preference domain."
# Boot / secure-boot / system extensions.
m '\bnvram\b[^|;&]*(\s-[cdrfb]\b|\S+=)'                  && block "nvram clear/write (boot settings)."
mi '\bbputil\b|\bkmutil\b[^|;&]*\b(trigger-panic-medic|clear-staging|configure-boot|unload)\b|\bsystemextensionsctl\b[^|;&]*\b(reset|uninstall)\b|\bkextunload\b' && block "secure-boot/system-extension change."
m '\bspctl\b[^|;&]*(--(master|global)-disable)'         && block "spctl disabling Gatekeeper."
mi '\blog\s+erase\b|\bmdutil\b[^|;&]*(-[a-zA-Z]*[EX]\b|-i\s+off|\s-d\b)' && block "log erase / mdutil wipes logs or the Spotlight index."
# Brew removal / destructive maintenance (uninstall aliases + bundle cleanup).
m '\bbrew\s+(uninstall|remove|rm|autoremove|untap|update-reset)\b|\bbrew\s+bundle\s+cleanup\b[^|;&]*--force|\bbrew\b[^|;&]*--zap\b|\bbrew\s+cleanup\b[^|;&]*(--prune=all|\s-s\b|--scrub)' \
  && block "brew uninstall/remove/zap/destructive cleanup."
# killing the GUI session loses unsaved work everywhere.
mi '\bkillall\b[^|;&]*\b(windowserver|loginwindow)\b|\blaunchctl\b[^|;&]*\breboot\b' && block "killing WindowServer/loginwindow or launchctl reboot."
m '\b(launchctl)\b[^|;&]*\b(bootout|remove|unload|disable)\b' && block "launchctl removing a service."
m '\bsystemctl\b[^|;&]*\b(disable|mask|stop)\b'          && block "systemctl disable/mask/stop."
m '\b(userdel|groupdel|deluser|delgroup)\b'             && block "Linux account/group deletion."
m '>\s*/proc/sysrq-trigger'                             && block "writing to /proc/sysrq-trigger (instant reboot/crash)."
# Bulk permission/ownership changes at or above home / system roots.
m '\b(chmod|chown|chgrp|chflags|setfacl|xattr)\b[^|;&]*-[a-zA-Z]*[rR]\b[^|;&]*(\s/(\s|$)|\s~|\$HOME|/Users(/|\s|$)|/home(/|\s|$)|/System|/Library|/usr|/etc)' \
  && block "recursive permission/ownership change on a home or system path."

# Sync/mirror tools run with a delete flag.
m '\b(rsync|openrsync)\b[^|;&]*(--del(ete(-[a-z]+)?)?|--remove-source-files)\b' && block "rsync with --delete/--del."
mi '\brclone\b[^|;&]*\b(sync|purge|delete|deletefile|move)\b'    && block "rclone sync/purge/delete/move."

# ===========================================================================
# 5. GIT  (irreversible history / worktree / staging operations)
# ===========================================================================
m 'git\s+push\b[^|;&]*--force\b' && ! m 'force-with-lease' && block "git push --force (use --force-with-lease)."
m 'git\s+push\b[^|;&]*\s-f\b'                            && block "git push -f (use --force-with-lease)."
m 'git\s+push\b[^|;&]*\s\+\S+'                           && block "git push with a + refspec rewrites remote history."
m 'git\s+push\b[^|;&]*(--mirror|--delete|--prune)\b'    && block "git push --mirror/--delete/--prune."
m 'git\s+reset\s+--hard\b'                              && block "git reset --hard discards uncommitted work."
m 'git\s+reset\b'                                       && block "git reset (unstaging/moving HEAD is disabled; user controls this)."
m 'git\s+clean\b[^|;&]*(-[a-zA-Z]*f|--force)'           && block "git clean -f deletes untracked files."
m 'git\s+checkout\b[^|;&]*(--\s+\S|\s\.|\s[^- ]\S*\.[a-z]+)' && block "git checkout discards uncommitted changes."
m 'git\s+(restore|switch)\b[^|;&]*(--discard-changes|--staged|--\s|-f\b)' && block "git restore/switch discards changes."
m 'git\s+restore\b'                                     && block "git restore discards uncommitted changes."
m 'git\s+stash\b'                                       && block "git stash is disabled (never move/lose working-tree changes)."
# git add / commit / push are checked per segment against the real branch
# (check_git). Backstop on the text in case a push was not parsed. Anchored to
# command position so prose like a PR body saying "git push to main" passes.
m "(^|[;&|(\`\"'])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+|(env|command|exec|nohup|time|nice|caffeinate)[[:space:]]+)*git[[:space:]]+push\\b[^|;&]*[[:space:]:](refs/heads/)?($PROTECTED_BRANCHES)([[:space:]]|\$)" \
  && block "git push naming a protected branch."
m 'git\s+branch\b[^|;&]*-D\b'                           && block "git branch -D force-deletes without a merge check."
# Any force flag on git branch: --delete --force / -df (force delete), -f (reset
# an existing branch to another commit), -M / -C (move/copy over an existing one).
m 'git\s+branch\b[^|;&]*\s(-[a-zA-Z]*[DfMC][a-zA-Z]*|--force)\b' \
  && block "git branch with a force flag deletes or overwrites a branch."
# checkout -B / switch -C silently reset an existing branch; checkout -f / switch
# --force throw away uncommitted changes.
m 'git\s+checkout\b[^|;&]*\s(-[a-zA-Z]*[Bf][a-zA-Z]*|--force)\b' \
  && block "git checkout -B/-f overwrites an existing branch or discards changes."
m 'git\s+switch\b[^|;&]*\s(-[a-zA-Z]*C[a-zA-Z]*|--force-create|--force)\b' \
  && block "git switch -C/--force overwrites an existing branch or discards changes."
m 'git\s+worktree\s+remove\b[^|;&]*(--force|-f)\b'      && block "git worktree remove --force."
m 'git\s+reflog\b[^|;&]*expire\b'                       && block "git reflog expire destroys recovery history."
m 'git\s+(gc\b[^|;&]*--prune=now|prune\b)'              && block "git gc --prune/prune drops unreachable objects."
m 'git\s+(filter-branch|filter-repo)\b'                 && block "git filter-branch/filter-repo rewrites all history."
m 'git\s+update-ref\b[^|;&]*-d\b'                       && block "git update-ref -d deletes a ref."
m 'git\s+rebase\s+(.*\s)?(origin/|refs/heads/)?(main|master|production)(\s|$|[;&|])' \
  && block "git rebase onto a shared branch."

# ===========================================================================
# 6. DATABASES / ORMs
# ===========================================================================
mi 'drop\s+(table|database|schema)\b|truncate\s+(table\s+)?\w'  && block "destructive SQL (DROP/TRUNCATE)."
mi 'delete\s+from\s+\w+\s*(;|$)|delete\s+from\s+\w+\s+where\s+(1\s*=\s*1|true)\b' \
  && block "DELETE without a meaningful WHERE clause."
mi '\bdropdb\b|\bmysqladmin\b[^|;&]*\bdrop\b'            && block "dropdb/mysqladmin drop."
mi 'redis-cli\b[^|;&]*\b(flushall|flushdb)\b'           && block "redis FLUSHALL/FLUSHDB."
mi '\bdb\.dropdatabase\s*\(|\.drop\s*\(\s*\)'           && block "MongoDB dropDatabase/collection drop."
mi 'prisma\b[^|;&]*(migrate\s+reset|db\s+push[^|;&]*(--accept-data-loss|--force-reset))' \
  && block "prisma migrate reset / db push --accept-data-loss."
mi 'drizzle-kit\b[^|;&]*(drop\b|push[^|;&]*--force)'    && block "drizzle-kit drop / push --force."
mi '\b(rails|rake)\b[^|;&]*db:(drop|reset|purge|schema:load)\b' && block "rails db:drop/reset/purge."
mi 'supabase\b[^|;&]*db\s+reset\b'                      && block "supabase db reset."
mi '\b(sequelize|sequelize-cli)\b[^|;&]*db:drop\b'      && block "sequelize db:drop."
mi 'typeorm\b[^|;&]*schema:drop\b'                      && block "typeorm schema:drop."
mi '\bartisan\b[^|;&]*(migrate:fresh|db:wipe)\b'        && block "artisan migrate:fresh / db:wipe."
mi 'manage\.py\b[^|;&]*(flush|reset_db)\b'              && block "django flush/reset_db."

# ===========================================================================
# 7. INFRASTRUCTURE / CONTAINERS / CLOUD
# ===========================================================================
mi '\b(terraform|tofu)\b[^|;&]*(destroy\b|apply[^|;&]*(-destroy|-auto-approve)|state\s+rm\b|workspace\s+delete\b)' \
  && block "terraform/tofu destroy / state rm / auto-approve."
mi '\bpulumi\b[^|;&]*(destroy\b|stack\s+rm\b|up[^|;&]*--yes)' && block "pulumi destroy / stack rm."
mi '\bcdk\b[^|;&]*destroy\b'                             && block "cdk destroy."
mi '\bkubectl\b[^|;&]*delete\b[^|;&]*(--all\b|-A\b|namespace|ns\b|pv\b|pvc\b|persistentvolume)' \
  && block "kubectl delete of namespaces/volumes/--all."
mi '\bhelm\b[^|;&]*(uninstall|delete)\b'                && block "helm uninstall/delete."
mi '\b(docker|podman)\b[^|;&]*(system\s+prune[^|;&]*(-a|--all|--volumes)|volume\s+(rm|prune)|image\s+prune[^|;&]*(-a|--all)|system\s+reset)' \
  && block "docker/podman prune/volume rm/system reset."
mi '\b(docker-compose|docker\s+compose|podman-compose)\b[^|;&]*down\b[^|;&]*(-v|--volumes)' \
  && block "compose down -v removes volumes."
mi '\baws\b[^|;&]*s3\b[^|;&]*(rm\b[^|;&]*--recursive|rb\b[^|;&]*--force)' && block "aws s3 rm --recursive / rb --force."
mi '\bgsutil\b[^|;&]*(rm\b[^|;&]*-r|\brsync\b[^|;&]*-d)'  && block "gsutil rm -r / rsync -d."
mi '\bgcloud\b[^|;&]*(storage\s+rm\b[^|;&]*(-r|--recursive)|\bdelete\b)' && block "gcloud delete / storage rm -r."
mi '\baz\b[^|;&]*(group\s+delete|storage\s+blob\s+delete-batch|\bdelete\b[^|;&]*--yes)' && block "az group/resource delete."
mi '\bgh\b[^|;&]*(repo\s+delete|release\s+delete)\b'     && block "gh repo/release delete."
# Raw GitHub API writes (merge, approve, close...) that skip the gh checks.
m 'curl\b[^|;&]*api\.github\.com' \
  && m 'curl\b[^|;&]*(-X\s*(POST|PUT|PATCH|DELETE)|--request\s*(POST|PUT|PATCH|DELETE)|\s-d\b|--data|--json|\s-F\b|--form)' \
  && block "curl write to the GitHub API."
mi 'npm\b[^|;&]*unpublish\b'                            && block "npm unpublish."
m '(npm|yarn|pnpm)\s+publish\b' && ! m '[-]-dry-run'   && block "package publishing."

# ===========================================================================
# 8. SYSTEM PACKAGE REMOVAL / MASS KILL / FORK BOMB
# ===========================================================================
m '\b(brew\s+uninstall|apt(-get)?\s+remove|apt(-get)?\s+purge|pip[0-9.]*\s+uninstall|dnf\s+remove|yum\s+remove|pacman\s+-R)\b' \
  && block "system package removal."
m '\bkillall\b\s*$|\bkill\s+-9\s+-1\b|\bpkill\s+-9\s+-1\b'   && block "mass process kill."
m ':\(\)\s*\{\s*:\s*\|\s*:' && block "fork bomb."
mi '\bcrontab\b[^|;&]*-r\b'  && block "crontab -r wipes all cron jobs."

exit 0
