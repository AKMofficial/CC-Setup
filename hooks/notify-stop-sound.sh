#!/usr/bin/env bash
# Play a sound when Claude finishes a turn — but ONLY in the main chat session,
# not when a background subagent / Agent-tool task completes.
#
# Fires as a Stop hook. Hooks that fire inside a subagent get `agent_id` /
# `agent_type` in their JSON stdin payload; the main session does not. So we
# read stdin and stay silent whenever agent_id is present.

input=$(cat)

# agent_id is null/absent in the main session, a string inside a subagent.
agent_id=$(printf '%s' "$input" | jq -r '.agent_id // empty')

if [ -z "$agent_id" ]; then
  afplay /System/Library/Sounds/Glass.aiff
fi
