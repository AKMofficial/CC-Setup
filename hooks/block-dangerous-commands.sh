#!/usr/bin/env bash
# PreToolUse hook: block commands that can wreck the machine, your data, or
# your git history. Fires on the Bash tool and the Windows PowerShell tool.
#
# Goal: protect, not police. Normal work is left alone: deleting temp files,
# editing or writing files outside the project, `rm "$TMPFILE"`, cleanup in
# build dirs, and so on. Only catastrophic targets are blocked:
#   - deleting /, your home dir, a whole folder right under home (~/Desktop,
#     ~/Documents...), a system dir, a whole disk, or "everything here"
#     (rm -rf . / * / ..), and `rm -rf "$DIR"/*` (wipes / if DIR is empty)
#   - sudo / doas / eval, piping a download into a shell
#   - git that destroys work or history for good (reset --hard, clean -f,
#     discarding edits, stash, force push, history rewrites, overwriting a
#     branch). Staging, unstaging, commits, pushes, PRs, merges and branch
#     deletes (-D) are allowed.
#   - disk wipes, destructive SQL, infra destroys, package publishing
#
# Exit 2 = block (stderr shown to Claude). Exit 0 = allow.

block() { echo "BLOCKED: $1" >&2; exit 2; }

command -v jq >/dev/null 2>&1 || block "jq is required by the safety hook but was not found."

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')
case "$TOOL_NAME" in
  Bash|PowerShell) : ;;
  *) exit 0 ;;
esac

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
[ -z "$CMD" ] && exit 0
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')

# Normalize blanks to single spaces. Collapse >| and >! so the splitter below
# does not mistake their `|` for a pipe.
NORM=$(printf '%s' "$CMD" | tr '\t\r\v\f' '    ' | tr -s ' ')
NORM=${NORM//'>|'/'> '}
NORM=${NORM//'>!'/'> '}
LOW=$(printf '%s' "$NORM" | tr 'A-Z' 'a-z')

# Here-strings, not pipes, so grep -q exiting early never breaks the match.
m()  { grep -qE -e "$1" <<< "$NORM"; }
mi() { grep -qiE -e "$1" <<< "$LOW"; }

# ===========================================================================
# 0. PRIVILEGE / HIDDEN COMMANDS
# ===========================================================================
m '(^|[;&|(]\s*)su\s+-c\b'            && block "su -c should not be used."
m '(^|[;&|(]\s*)eval\s'               && block "eval can hide a destructive command from this check."
mi 'with administrator privileges'    && block "osascript 'with administrator privileges' runs as admin."
m '(curl|wget|fetch)\b[^|]*\|\s*(bash|sh|zsh|dash|ksh|pwsh|powershell)\b' \
  && block "piping a download straight into a shell."
m '\b(base64|xxd|openssl\s+enc|basenc)\b[^|]*\|\s*(bash|sh|zsh|dash|ksh)\b' \
  && block "decoding a blob straight into a shell."
m '(curl|wget|fetch)\b[^;&|]*-o\s+\S+.*(&&|;).*\b(bash|sh|zsh|source|\.)\s' \
  && block "download-then-execute pattern."

# ===========================================================================
# 1. CATASTROPHIC DELETE TARGETS
# ===========================================================================
UNIX_DEL='rm|rmdir|unlink|shred|srm|grm|grmdir|gshred|zf_rm|zf_rmdir'
SHELLS='bash|sh|zsh|dash|ksh|fish'
KEYWORDS='then|do|else|elif|if|while|until|!|\{|\}'
WRAPPERS='command|builtin|exec|env|nice|nohup|time|stdbuf|timeout|gtimeout|caffeinate|ionice|chrt|taskset|watch|nocorrect|noglob'
WRAP_TARGETS="$UNIX_DEL|$SHELLS|find|cd|pushd|popd|sudo|doas|rsync|openrsync|git|gh"
HOME_DIR="${HOME%/}"

# unquote: strip one leading and one trailing quote (sets UQ).
unquote() { UQ="${1#[\"\']}"; UQ="${UQ%[\"\']}"; }

# is_dangerous_target PATH RECURSIVE: 0 when deleting PATH would be a disaster.
# RECURSIVE=1 for rm -r / -f, find -delete, rsync --delete.
is_dangerous_target() {
  local p rec="$2" q home_rel
  # Drop all quotes (so "$DIR"/* is seen) and turn C:\x into C:/x.
  unquote "$1"; p="${UQ//[\"\']/}"; p="${p//\\//}"
  # Home spellings.
  case "$p" in
    "~"|"~/"*)                p="$HOME_DIR${p#\~}" ;;
    '$HOME'|'$HOME/'*)        p="$HOME_DIR${p#\$HOME}" ;;
    '${HOME}'|'${HOME}/'*)    p="$HOME_DIR${p#\$\{HOME\}}" ;;
    '%userprofile%'*|'%USERPROFILE%'*) return 0 ;;
  esac
  # `rm -rf "$DIR/"` or `"$DIR"/*`: if DIR is empty this is rm -rf /.
  [[ "$p" =~ ^\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/+\*?$ ]] && return 0
  # Windows drive letters: C:/x -> /c/x (Git Bash form).
  if [[ "$p" =~ ^([A-Za-z]):(/.*)?$ ]]; then
    q=$(printf '%s' "${BASH_REMATCH[1]}" | tr 'A-Z' 'a-z'); p="/$q${BASH_REMATCH[2]}"
  fi
  # Drop trailing /, /., /* so `/usr/`, `~/*` and `/usr` compare equal.
  q="$p"
  while :; do
    case "$q" in
      */\*|*/.) q="${q%/*}" ;;
      ?*/)      q="${q%/}" ;;
      *) break ;;
    esac
  done
  case "$q" in ""|/) return 0 ;; esac
  case "$q" in
    /*) : ;;
    *)
      # Only dots, slashes and globs (., *, .., ../*) = "everything here".
      [ "$rec" = 1 ] && case "$q" in *[!./*?]*) ;; *) return 0 ;; esac
      # Resolve a plain relative name against the cwd (so `rm -rf Desktop`
      # from home is caught). Unknown after a cd in the same command.
      [ -n "$CWD" ] && [ "$CD_SEEN" = 0 ] || return 1
      case "/$q/" in */../*|*[\$\`]*) return 1 ;; esac
      q="${CWD%/}/${q#./}" ;;
  esac
  # Temp dirs are always fine.
  case "$q" in /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*|/var/tmp/*) return 1 ;; esac
  [ -n "$TMPDIR" ] && case "$q" in "${TMPDIR%/}"/*) return 1 ;; esac
  # Home itself, and (recursive) any folder directly under it.
  [ "$q" = "$HOME_DIR" ] && return 0
  if [ "$rec" = 1 ]; then
    case "$q" in "$HOME_DIR"/*) home_rel="${q#"$HOME_DIR"/}"; [[ "$home_rel" != */* ]] && return 0 ;; esac
  fi
  # Any user's home, the users dir, mounted disks.
  [[ "$q" =~ ^/(Users|home|Volumes|mnt|media|[a-z]/[Uu]sers)(/[^/]+)?$ ]] && return 0
  # Windows drive roots and system dirs (Git Bash /c/...).
  [[ "$q" =~ ^/[a-z](/([Ww]indows|[Pp]rogram\ [Ff]iles.*|[Pp]rogram[Dd]ata)(/.*)?)?$ ]] && return 0
  # /usr/local and /opt: the dir and its top level only (deeper is your stuff).
  [[ "$q" =~ ^/(usr/local|opt|opt/homebrew)(/[^/]+)?$ ]] && return 0
  case "$q" in /usr/local/*|/opt/*) return 1 ;; esac
  # System dirs and everything inside them.
  [[ "$q" =~ ^/(System|Library|usr|bin|sbin|etc|var|private|Applications|cores|dev|boot|lib|lib64|root|proc|sys|snap)(/.*)?$ ]] && return 0
  return 1
}

# verb_name: bare command name, so \rm, "rm", =rm and /bin/rm all equal rm.
verb_name() {
  VN="${1//\\/}"; VN="${VN//\"/}"; VN="${VN//\'/}"; VN="${VN#=}"; VN="${VN##*/}"
}

# tokenize: split on blanks, keeping quoted runs and escapes in one token.
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

# find_head: set HEAD (bare lowercase command) and HEAD_I, skipping VAR=value,
# shell keywords and wrappers like `timeout 5 rm ...`.
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
    if [[ "$t" == *=* && "$t" == [A-Za-z_]* ]]; then i=$((i+1)); continue; fi
    if [[ "$t" =~ $kw_re ]]; then i=$((i+1)); continue; fi
    if [[ "$VN" =~ $wr_re ]]; then wrapped=1; i=$((i+1)); continue; fi
    HEAD="$VN"; HEAD_I=$i; break
  done
  shopt -u nocasematch
  case "$HEAD" in *[A-Z]*) HEAD=$(printf '%s' "$HEAD" | tr 'A-Z' 'a-z') ;; esac
  return 0
}

# Check one command segment (already split on separators).
check_segment() {
  local seg="$1" IFS=' ' t k j n i r rec endopts
  find_head "$seg"
  [ -z "$HEAD" ] && return 0
  i=$HEAD_I; n=${#TOKS[@]}

  # ---- Deletes: block only catastrophic targets. ----
  local del_re="^($UNIX_DEL)$"
  if [[ "$HEAD" =~ $del_re ]]; then
    rec=0; endopts=0
    for t in "${TOKS[@]:$((i+1))}"; do
      [ $endopts = 1 ] && break
      [ "$t" = "--" ] && endopts=1
      [[ "$t" =~ ^(--recursive|--force|-[[:alpha:]]*[rRf][[:alpha:]]*)$ ]] && rec=1
    done
    endopts=0
    for t in "${TOKS[@]:$((i+1))}"; do
      if [ $endopts = 0 ]; then
        [ "$t" = "--" ] && { endopts=1; continue; }
        case "$t" in -*) continue ;; esac
      fi
      is_dangerous_target "$t" "$rec" \
        && block "$HEAD on '$t' would delete your home, a whole folder in it, a system dir, a disk, or everything here. Run it yourself if intended."
    done
    return 0
  fi

  case "$HEAD" in
    sudo|doas) block "sudo/doas should not be used." ;;
    cd|pushd|popd|set-location|sl|chdir|push-location|pop-location)
      CD_SEEN=1 ;;
    bash|sh|zsh|dash|ksh|fish)
      # `bash -c '<cmd>'`: check the inner command like any other segment.
      k=$((i+1))
      while [ $k -lt "$n" ]; do
        case "${TOKS[$k]}" in -*c) [ $((k+1)) -lt "$n" ] && { unquote "${TOKS[$((k+1))]}"; check_segment "$UQ"; }; break ;; esac
        k=$((k+1))
      done ;;
    find)
      # find -delete / -exec rm: check the search roots.
      grep -qiE -e "-delete\b|-exec(dir)? (\S*/)?\\\\?($UNIX_DEL)\b" <<< "${TOKS[*]:$((i+1))}" || return 0
      k=$((i+1))
      while [ $k -lt "$n" ]; do
        r="${TOKS[$k]}"; k=$((k+1))
        case "$r" in -* | \( | \\\( | !) break ;; esac
        case "$r" in .|./) continue ;; esac   # find . -name x -delete is normal
        is_dangerous_target "$r" 1 && block "find-delete rooted at '$r' (home, system dir or disk). Run it yourself if intended."
      done ;;
    rsync|openrsync)
      # --delete removes everything in the destination not in the source.
      [[ " ${TOKS[*]:$((i+1))} " =~ \ --(del|delete[a-z-]*|remove-source-files)\  ]] || return 0
      local ops=()
      for t in "${TOKS[@]:$((i+1))}"; do case "$t" in -*) continue ;; esac; ops+=("$t"); done
      [ ${#ops[@]} -gt 0 ] && is_dangerous_target "${ops[${#ops[@]}-1]}" 1 \
        && block "rsync --delete into '${ops[${#ops[@]}-1]}' (home, system dir or disk)." ;;
  esac
  return 0
}

# Split on every command separator and check each piece in order, so a `cd`
# earlier in the command is seen before a later delete or git write.
CD_SEEN=0
set -f
OLDIFS="$IFS"; IFS=$'\n'
for SEG in $(printf '%s' "$NORM" | sed -E 's/(&&|\|\||;|&|\||\(|\)|`)/\n/g'); do
  check_segment "$SEG"
done
IFS="$OLDIFS"
set +f

# ===========================================================================
# 2. WINDOWS (when this runs under Git Bash)
# ===========================================================================
# The Oct 2026 C: wipe was `cmd /c "rmdir /s /q \"...\""`: cmd mangles the \"
# and the path collapses to the drive root. Never trust a delete inside cmd /c.
mi 'cmd(\.exe)?\s+/{1,2}[ck]\b.*\b(rmdir|rd|del|erase)\b' \
  && block "delete inside cmd /c (quote mangling can turn the path into the drive root). Run it yourself or use Remove-Item."
# Deletes aimed at a drive root, the Users dir, a user profile or Windows.
mi '(remove-item|\bri\b|\brm\b|\brd\b|\brmdir\b|\bdel\b|\berase\b)[^|;&]*((^|[ "'\''])[a-z]:[\\/]*(\*)?(["'\'' ]|$)|[a-z]:[\\/]+(users([\\/]+[^\\/ "'\'']+)?|windows|program files[^\\/"'\'']*)[\\/]*(\*)?(["'\'' ]|$)|\$env:(userprofile|systemdrive|systemroot|homepath)[\\/]*(\*)?(["'\'' ]|$)|\$home[\\/]*(\*)?(["'\'' ]|$)|\\\\\?\\|\\\\\.\\)' \
  && block "Windows delete targeting a drive root, the Users dir, a user profile or Windows itself."
mi '\bdiskpart\b'                                        && block "diskpart (clean/format wipes partitions)."
mi '\bformat\s+[a-z]:'                                   && block "format of a drive."
mi '\b(clear-disk|remove-partition|format-volume|initialize-disk)\b' && block "PowerShell disk/partition wipe."
mi '\bvssadmin\b[^|;&]*\bdelete\b|\bwmic\b[^|;&]*shadowcopy[^|;&]*delete|\bwbadmin\b[^|;&]*\bdelete\b' \
  && block "deleting shadow copies / backups."
mi '\bcipher\b[^|;&]*/w'                                 && block "cipher /w wipes free space."
mi '\bwsl\b[^|;&]*--unregister\b'                        && block "wsl --unregister permanently deletes a distro."
mi '\b(powershell|pwsh)(\.exe)?\b[^|;&]*\s-(e|en|enc|enco|encod|encode|encoded|encodedcommand)\b' \
  && block "powershell -EncodedCommand hides the real command."
mi '\bclear-recyclebin\b'                                && block "Clear-RecycleBin empties the Recycle Bin."

# ===========================================================================
# 3. DISKS / SYSTEM
# ===========================================================================
m '\bdd\b[^|;&]*of=/dev/'                                && block "dd writing to a device."
m '(>[[:space:]]*)/dev/r?disk[0-9]'                      && block "writing straight to a disk device."
m '\bmkfs(\.[a-z0-9]+)?\b|\bnewfs_[a-z0-9]+\b'          && block "formatting a filesystem."
m '\b(wipefs|blkdiscard|fdisk|sfdisk|gdisk|sgdisk|parted)\b' && block "partition/disk wipe tool."
mi '\bdiskutil\b[^|;&]*(erase\w*|reformat|zerodisk|randomdisk|partitiondisk|secureerase|\b(apfs|ap)\s+(delete\w*|erase\w*))' \
  && block "diskutil erase/partition/apfs delete."
mi '\btmutil\b[^|;&]*\b(delete\w*|disable)\b'          && block "tmutil deleting Time Machine backups."
mi '\bsecurity\b[^|;&]*\bdelete-keychain\b'             && block "security delete-keychain."
mi '\bosascript\b[^|;&]*empty( the)? trash'             && block "emptying the Trash."
m '\b(chmod|chown|chgrp)\b[^|;&]*-[a-zA-Z]*R\b[^|;&]*(\s/(\s|$)|\s~/?(\s|$)|\$HOME/?(\s|$)|\s/Users(/[^/[:space:]]+)?/?(\s|$)|/System|\s/Library|\s/usr|\s/etc)' \
  && block "recursive permission change on home or a system dir."
m '\bkillall\b\s*$|\bkill\s+-9\s+-1\b|\bpkill\s+-9\s+-1\b' && block "mass process kill."
m ':\(\)\s*\{\s*:\s*\|\s*:'                              && block "fork bomb."
mi '\bcrontab\b[^|;&]*\s-r\b'                           && block "crontab -r wipes all cron jobs."
m '\b(brew\s+uninstall|apt(-get)?\s+(remove|purge)|dnf\s+remove|yum\s+remove|pacman\s+-R)\b' \
  && block "system package removal."

# ===========================================================================
# 4. GIT / GITHUB  (only what destroys work or history for good)
# ===========================================================================
# Staging, unstaging, committing, pushing, branches, PRs and merges are allowed.
# Blocked: anything that throws away uncommitted work or rewrites/deletes
# history that may not exist anywhere else.
m 'git\s+push\b[^|;&]*--force\b' && ! m 'force-with-lease' && block "git push --force (use --force-with-lease)."
m 'git\s+push\b[^|;&]*\s-f\b'                            && block "git push -f (use --force-with-lease)."
m 'git\s+push\b[^|;&]*\s\+\S+'                           && block "git push with a + refspec rewrites remote history."
m 'git\s+push\b[^|;&]*(--mirror|--prune)\b'             && block "git push --mirror/--prune can delete every remote branch."
m 'git\s+reset\b[^|;&]*--hard\b'                        && block "git reset --hard discards uncommitted work."
m 'git\s+clean\b[^|;&]*(-[a-zA-Z]*f|--force)'           && block "git clean -f deletes untracked files."
m 'git\s+checkout\b[^|;&]*(--\s+\S|\s\.(\s|$)|\s[^- ]\S*\.[a-z]+(\s|$))' && block "git checkout of files discards uncommitted changes."
# git restore --staged only unstages (allowed); plain restore / --worktree discards edits.
m 'git\s+restore\b' && { ! m 'git\s+restore\b[^|;&]*(--staged|\s-S\b)' || m 'git\s+restore\b[^|;&]*(--worktree|\s-W\b)'; } \
  && block "git restore discards uncommitted changes (git restore --staged to unstage is fine)."
m 'git\s+stash\b'                                       && block "git stash is disabled (never move/lose working-tree changes)."
# Deleting a branch (-d, -D, --delete --force) is allowed: it stays in the reflog.
# Blocked: -f / -M / -C, which overwrite an existing branch with another commit.
m 'git\s+branch\b[^|;&]*\s(-[a-zA-Z]*[fMC][a-zA-Z]*|--force)\b' \
  && ! m 'git\s+branch\b[^|;&]*\s(-[a-zA-Z]*[dD][a-zA-Z]*|--delete)\b' \
  && block "git branch -f/-M/-C overwrites an existing branch."
m 'git\s+checkout\b[^|;&]*\s(-[a-zA-Z]*[Bf][a-zA-Z]*|--force)\b' \
  && block "git checkout -B/-f overwrites a branch or discards changes."
m 'git\s+switch\b[^|;&]*\s(-[a-zA-Z]*C[a-zA-Z]*|--force-create|--force|--discard-changes)\b' \
  && block "git switch -C/--force overwrites a branch or discards changes."
m 'git\s+worktree\s+remove\b[^|;&]*(--force|-f)\b'      && block "git worktree remove --force."
m 'git\s+reflog\b[^|;&]*expire\b'                       && block "git reflog expire destroys recovery history."
m 'git\s+(gc\b[^|;&]*--prune=now|prune\b)'              && block "git gc --prune/prune drops unreachable objects."
m 'git\s+(filter-branch|filter-repo)\b'                 && block "git filter-branch/filter-repo rewrites all history."
m 'git\s+update-ref\b[^|;&]*-d\b'                       && block "git update-ref -d deletes a ref."
m 'git\s+rebase\s+(.*\s)?(origin/|refs/heads/)?(main|master|production)(\s|$|[;&|])' \
  && block "git rebase onto a shared branch."
m '\bgh\s+repo\s+(delete|archive)\b|\bgh\s+release\s+delete\b' && block "gh repo/release delete."

# ===========================================================================
# 5. DATABASES / INFRA / PUBLISHING
# ===========================================================================
mi 'drop\s+(table|database|schema)\b|truncate\s+table\b'  && block "destructive SQL (DROP/TRUNCATE)."
mi 'delete\s+from\s+\w+\s*(;|$|")|delete\s+from\s+\w+\s+where\s+(1\s*=\s*1|true)\b' \
  && block "DELETE without a meaningful WHERE clause."
mi '\bdropdb\b|redis-cli\b[^|;&]*\b(flushall|flushdb)\b|\bdb\.dropdatabase\s*\(' && block "dropping a database."
mi 'prisma\b[^|;&]*(migrate\s+reset|db\s+push[^|;&]*(--accept-data-loss|--force-reset))' \
  && block "prisma migrate reset / db push --accept-data-loss."
mi 'drizzle-kit\b[^|;&]*(drop\b|push[^|;&]*--force)'    && block "drizzle-kit drop / push --force."
mi '\b(rails|rake)\b[^|;&]*db:(drop|reset|purge)\b|supabase\b[^|;&]*db\s+reset\b|\bartisan\b[^|;&]*(migrate:fresh|db:wipe)\b|manage\.py\b[^|;&]*(flush|reset_db)\b' \
  && block "database reset/drop."
mi '\b(terraform|tofu)\b[^|;&]*(destroy\b|apply[^|;&]*-destroy)|\bpulumi\b[^|;&]*destroy\b|\bcdk\b[^|;&]*destroy\b' \
  && block "infrastructure destroy."
mi '\bkubectl\b[^|;&]*delete\b[^|;&]*(--all\b|namespace|\bns\b|\bpvc?\b|persistentvolume)' \
  && block "kubectl delete of namespaces/volumes/--all."
mi '\b(docker|podman)\b[^|;&]*(system\s+prune[^|;&]*--volumes|volume\s+(rm|prune)|system\s+reset)|\b(docker-compose|docker\s+compose)\b[^|;&]*down\b[^|;&]*(\s-v\b|--volumes)' \
  && block "deleting docker volumes."
mi '\baws\b[^|;&]*s3\b[^|;&]*(rm\b[^|;&]*--recursive|rb\b[^|;&]*--force)' && block "aws s3 recursive delete."
mi 'npm\b[^|;&]*unpublish\b'                            && block "npm unpublish."
m '(npm|yarn|pnpm)\s+publish\b' && ! m '[-]-dry-run'   && block "package publishing."

exit 0
