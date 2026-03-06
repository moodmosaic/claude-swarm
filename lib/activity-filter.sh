#!/bin/bash
set -euo pipefail

# Reads opencode NDJSON (--format json) from stdin and prints
# human-readable activity summaries to stdout.  Designed to be
# used with:
#
#   opencode run ... --format json | tee "$LOG" | activity-filter.sh
#
# Each tool_use event becomes one line:
#   12:34:56   agent[1] Read src/main.ts
#   12:34:57   agent[1] Write src/main.ts
#   12:34:58   agent[1] Edit src/main.ts
#   12:35:01   agent[1] Shell: npm test
#   12:35:02   agent[1] Glob *.ts
#
# Uses a single jq invocation for efficiency (no per-line fork).

AGENT_ID="${AGENT_ID:-?}"

exec jq --unbuffered --raw-input --arg id "$AGENT_ID" -r '
  def truncate(n):
    if length > n then .[:n-3] + "..." else . end;

  def first_line:
    split("\n")[0] // .;

  def ts:
    now | strftime("%H:%M:%S");

  def prefix:
    "\(ts)   agent[\($id)]";

  fromjson? // empty |
  select(.type == "tool_use") |
  .part as $p |
  if   $p.tool == "bash"  then "\(prefix) Shell: " + (($p.state.input.command // "") | first_line | truncate(80))
  elif $p.tool == "read"  then "\(prefix) Read "  + ($p.state.input.filePath // $p.state.input.file_path // "")
  elif $p.tool == "write" then "\(prefix) Write " + ($p.state.input.filePath // $p.state.input.file_path // "")
  elif $p.tool == "edit"  then "\(prefix) Edit "  + ($p.state.input.filePath // $p.state.input.file_path // "")
  elif $p.tool == "glob"  then "\(prefix) Glob "  + ($p.state.input.pattern // "")
  elif $p.tool == "grep"  then "\(prefix) Grep "  + ($p.state.input.pattern // "")
  elif $p.tool == "task"  then "\(prefix) Task: " + (($p.state.input.description // "") | first_line | truncate(60))
  else "\(prefix) " + ($p.tool // "unknown")
  end
'
