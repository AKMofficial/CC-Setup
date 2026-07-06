#!/usr/bin/env bash
# Hard-block ALL git worktree creation, everywhere.
# Fires as a PreToolUse hook on Agent | EnterWorktree | Bash.
# Blocks: EnterWorktree tool, Agent with isolation:"worktree",
#         and any Bash "git worktree add".
# Allows: git worktree list/remove/prune (cleanup must still work).
#
# Note: the harness's *automatic* background-isolation worktree is
# governed separately by settings.json -> worktree.bgIsolation:"none",
# not by this hook (a PreToolUse hook can only see explicit tool calls).

jq -c '
if (.tool_name == "EnterWorktree")
   or (.tool_name == "Agent" and .tool_input.isolation == "worktree")
   or (.tool_name == "Bash" and ((.tool_input.command // "") | test("worktree\\s+add")))
then {hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:"BLOCKED: git worktrees are permanently forbidden here by an explicit, standing user rule. This is NOT a transient error and NOT a permission you can request - it will never be granted. Do NOT retry, do NOT try --force, a different path, or the EnterWorktree tool / Agent worktree isolation as a workaround. Do ALL work in the main checkout only."}}
else empty end
'
