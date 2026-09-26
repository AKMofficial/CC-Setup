#!/usr/bin/env bash
# Block writing em dashes, en dashes, and their lookalikes into any file.
# Fires as a PreToolUse hook on Write | Edit | MultiEdit | NotebookEdit | Bash | PowerShell.
#
# Blocked characters: U+2014 em dash, U+2013 en dash, U+2012 figure dash,
# U+2015 horizontal bar, U+2E3A/U+2E3B two/three-em dash, U+FE58 small em dash,
# U+FE31/U+FE32 vertical dashes, plus the HTML entities that render as them
# (named mdash/ndash entities and numeric ones: decimal 8212/8211, hex x2014/x2013).
#
# File tools: checks only the NEW text (Write content, Edit new_string,
# MultiEdit edits, NotebookEdit new_source), so files that already contain
# dashes can still be edited as long as the new text has none.
#
# Shell tools (allowlist): a command containing a dash is allowed only when every
# part of it is a read-only command (grep, rg, find, git log, ...) and nothing in
# it writes a file (>, tee, heredoc, sed -i, sort -o, --output, find -exec, Set-Content, ...). Anything else with
# a dash is blocked, so no scripting language or write trick slips through.
# Quoted strings are ignored when splitting the command, so grep -E "a|b" works.
#
# The characters are written as \u escapes so this script never contains them itself.

jq -c '
def dash: "[\u2014\u2013\u2012\u2015\u2E3A\u2E3B\uFE58\uFE31\uFE32]|&(mdash|ndash);|&#(8212|8211|x0*2014|x0*2013);";
def dashi: test(dash; "i");

def unquoted: gsub("\"(\\\\.|[^\"\\\\])*\""; "Q") | gsub("\u0027[^\u0027]*\u0027"; "Q");
def writes: unquoted
  | gsub("[0-9&]*>+\\s*/dev/null|[0-9]*>&[0-9]"; "")
  | test(">|<<|\\btee\\b|\\b(sed|perl|ruby)\\b[^|;&]*\\s-[a-zA-Z]*i|--in-place|\\binplace\\b|\\b(set-content|add-content|out-file|new-item)\\b|writealltext|--output\\b|\\bsort\\b[^|;&]*\\s-[a-zA-Z]*o"; "i");
def all_readonly($cmds; $git):
  unquoted
  | [splits("&&|\\|\\||;|\\||\\n|\\$\\(|`|\\(|\\)")]
  | map(sub("^\\s+"; "") | sub("^([A-Za-z_][A-Za-z0-9_]*=\\S*\\s+)+"; "") | select(length > 0) | ascii_downcase | [splits("\\s+")])
  | all(.[0] as $c | (.[1] // "") as $sub
      | (($cmds | index([$c])) != null or ($c == "git" and ($git | index([$sub])) != null))
      and ($c != "find" or (join(" ") | test("\\s-(exec|execdir|ok|okdir)\\s+(?!(grep|egrep|fgrep|rg)\\b)|\\s-(fprint|fprint0|fprintf|fls|delete)\\b") | not)));

["grep","egrep","fgrep","rg","ag","ack","find","fd","ls","cd","pwd","cat","head","tail","wc","sort","uniq","cut","tr","diff","cmp","file","echo","printf","test","[","true","false","jq","od","hexdump",
 "select-string","sls","get-childitem","gci","dir","set-location","get-content","gc","measure-object","write-output"] as $readonly_cmds
| ["grep","log","show","diff","status","blame"] as $readonly_git
| .tool_name as $tool
| ($tool == "Bash" or $tool == "PowerShell") as $shell
| ((
    if $tool == "Write" then .tool_input.content
    elif $tool == "Edit" then .tool_input.new_string
    elif $tool == "MultiEdit" then ([.tool_input.edits[]?.new_string] | join("\n"))
    elif $tool == "NotebookEdit" then .tool_input.new_source
    elif $shell then .tool_input.command
    else "" end
  ) // "") as $text
| if ($text | dashi | not) then empty
  elif $shell and ($text | (writes | not) and all_readonly($readonly_cmds; $readonly_git)) then empty
  else
    ($text | split("\n") | map(select(dashi)) | .[0] | .[0:160]) as $line
    | (if $shell
       then "BLOCKED: this shell command contains an em dash, en dash, or lookalike (\u2014 \u2013 or an HTML entity for one), and it is not a pure read-only search. Standing user rule: never write them into any file. If you are writing text, rewrite it with proper punctuation: a comma, colon, semicolon, parentheses, a period to split the sentence, or a plain hyphen (-) for ranges and compound words. If you only need to SEARCH for a dash, use grep/rg on its own (no redirect, no pipe into a writer). Offending line: "
       else "BLOCKED: em dash, en dash, or lookalike (\u2014 \u2013 or an HTML entity for one) in text written to a file. Standing user rule: never write them in any file. Rewrite with proper punctuation instead: a comma, colon, semicolon, parentheses, a period to split the sentence, or a plain hyphen (-) for ranges and compound words. Then retry. Offending line: "
       end) as $msg
    | {hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:($msg + $line)}}
  end
'
