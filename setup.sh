#!/bin/bash
set -euo pipefail

# Interactive setup wizard for swarm.
# Produces a swarm.json config file.
# Uses whiptail for dialogs; falls back to read-based prompts.

SWARM_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
OUTPUT="$REPO_ROOT/swarm.json"
USE_WHIPTAIL=false

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<HELP
Usage: $0

Interactive setup wizard for swarm.
Generates a swarm.json config file in the repo root.

Walks through: credentials, prompt file, agent groups (model,
count, custom endpoints), advanced settings (setup script,
idle limit, git user), and post-processing.

Output:
  \$REPO_ROOT/swarm.json   Generated config file.

Auth:
  Checks for ~/.local/share/opencode/auth.json (created by
  'opencode auth'). Per-agent api_key fields can be set for
  custom endpoints.
HELP
    exit 0
fi

if command -v whiptail &>/dev/null; then
    USE_WHIPTAIL=true
fi

# ---- Dialog helpers ----

msg() {
    if $USE_WHIPTAIL; then
        whiptail --title "swarm" --msgbox "$1" 10 60
    else
        echo ""
        echo "$1"
        echo ""
    fi
}

input() {
    local title="$1" default="$2"
    if $USE_WHIPTAIL; then
        whiptail --title "swarm" --inputbox "$title" 10 60 "$default" 3>&1 1>&2 2>&3 || echo "$default"
    else
        local val
        read -rp "$title [$default]: " val
        echo "${val:-$default}"
    fi
}

password() {
    local title="$1"
    if $USE_WHIPTAIL; then
        whiptail --title "swarm" --passwordbox "$title" 10 60 3>&1 1>&2 2>&3 || echo ""
    else
        local val
        read -rsp "$title: " val
        echo ""
        echo "$val"
    fi
}

yesno() {
    local title="$1"
    if $USE_WHIPTAIL; then
        whiptail --title "swarm" --yesno "$title" 10 60 && return 0 || return 1
    else
        local val
        read -rp "$title [Y/n]: " val
        case "$val" in
            [Nn]*) return 1 ;;
            *)     return 0 ;;
        esac
    fi
}

# ---- Gather settings ----

echo "swarm setup wizard"
echo "==================="
echo ""

# 1. Authentication (auth.json).
OPENCODE_AUTH_JSON="${HOME}/.local/share/opencode/auth.json"

if [ -f "$OPENCODE_AUTH_JSON" ]; then
    echo "OpenCode auth.json detected at ${OPENCODE_AUTH_JSON}."
else
    echo "No auth.json found at ${OPENCODE_AUTH_JSON}."
    echo "Run 'opencode auth' to create it, or use per-agent api_key fields."
    echo ""
    if ! yesno "Continue without auth.json?"; then
        exit 1
    fi
fi

# 2. Prompt file.
echo ""
PROMPT_PATH=$(input "Path to prompt file (relative to repo root)" "")
if [ -z "$PROMPT_PATH" ]; then
    echo "ERROR: Prompt file is required." >&2
    exit 1
fi
if [ ! -f "$REPO_ROOT/$PROMPT_PATH" ]; then
    echo "WARNING: ${PROMPT_PATH} not found in repo root."
    if ! yesno "Continue anyway?"; then
        exit 1
    fi
fi

# 3. Agent groups.
AGENTS_JSON="[]"
GROUP_NUM=0

while true; do
    GROUP_NUM=$((GROUP_NUM + 1))
    echo ""
    echo "--- Agent group ${GROUP_NUM} ---"

    MODEL=$(input "Model name (provider/model format)" "anthropic/claude-opus-4-6")
    COUNT=$(input "Number of agents with this model" "1")

    AGENT_OBJ="{\"count\": ${COUNT}, \"model\": \"${MODEL}\""

    echo "  Reasoning effort (low/medium/high, blank to skip):"
    EFFORT=$(input "Effort level" "")
    case "$EFFORT" in
        low|medium|high) AGENT_OBJ+=", \"effort\": \"${EFFORT}\"" ;;
        "") ;;
        *) echo "  WARNING: unknown effort '${EFFORT}', skipping." ;;
    esac

    echo "  Context mode (full/slim/none, blank for full):"
    echo "    full = keep .opencode/ as-is"
    echo "    slim = keep only CLAUDE.md, strip agents/skills"
    echo "    none = remove entire .opencode/ (bare agent)"
    CONTEXT=$(input "Context mode" "")
    case "$CONTEXT" in
        slim|none) AGENT_OBJ+=", \"context\": \"${CONTEXT}\"" ;;
        full|"") ;;
        *) echo "  WARNING: unknown context '${CONTEXT}', skipping." ;;
    esac

    GPROMPT=$(input "Custom prompt for this group (blank for default)" "")
    if [ -n "$GPROMPT" ]; then
        AGENT_OBJ+=", \"prompt\": \"${GPROMPT}\""
    fi

    if yesno "Custom endpoint for this group?"; then
        BASE_URL=$(input "Base URL" "https://openrouter.ai/api/v1")
        GROUP_KEY=$(password "API key for this endpoint")
        AGENT_OBJ+=", \"base_url\": \"${BASE_URL}\""
        if [ -n "$GROUP_KEY" ]; then
            AGENT_OBJ+=", \"api_key\": \"${GROUP_KEY}\""
        fi
    fi

    AGENT_OBJ+="}"
    AGENTS_JSON=$(echo "$AGENTS_JSON" | jq --argjson obj "$AGENT_OBJ" '. + [$obj]')

    TOTAL=$(echo "$AGENTS_JSON" | jq '[.[].count] | add')
    echo ""
    echo "Total agents so far: ${TOTAL}"

    if ! yesno "Add another agent group?"; then
        break
    fi
done

# 4. Advanced settings.
SETUP_PATH=""
MAX_IDLE=3
GIT_NAME="swarm-agent"
GIT_EMAIL="agent@claude-swarm.local"

if yesno "Configure advanced settings (setup script, idle limit, git user)?"; then
    SETUP_PATH=$(input "Setup script path (blank to skip)" "")
    MAX_IDLE=$(input "Max idle sessions before exit" "3")
    GIT_NAME=$(input "Git user name for agent commits" "swarm-agent")
    GIT_EMAIL=$(input "Git user email for agent commits" "agent@claude-swarm.local")
fi

# 5. Post-processing.
POST_PROMPT=""
POST_MODEL=""

POST_EFFORT=""

if yesno "Configure post-processing (runs after all agents finish)?"; then
    POST_PROMPT=$(input "Post-processing prompt file" "")
    POST_MODEL=$(input "Model for post-processing" "anthropic/claude-opus-4-6")
    echo "  Reasoning effort for post-processing (low/medium/high, blank to skip):"
    POST_EFFORT=$(input "Effort level" "")
    case "$POST_EFFORT" in
        low|medium|high|"") ;;
        *) echo "  WARNING: unknown effort '${POST_EFFORT}', skipping."
           POST_EFFORT="" ;;
    esac
fi

# ---- Build config ----

CONFIG=$(jq -n \
    --arg prompt "$PROMPT_PATH" \
    --arg setup "$SETUP_PATH" \
    --argjson max_idle "$MAX_IDLE" \
    --arg git_name "$GIT_NAME" \
    --arg git_email "$GIT_EMAIL" \
    --argjson agents "$AGENTS_JSON" \
    '{
        prompt: $prompt,
        max_idle: $max_idle,
        git_user: { name: $git_name, email: $git_email },
        agents: $agents
    }
    | if $setup != "" then .setup = $setup else . end')

if [ -n "$POST_PROMPT" ]; then
    CONFIG=$(echo "$CONFIG" | jq \
        --arg pp_prompt "$POST_PROMPT" \
        --arg pp_model "$POST_MODEL" \
        --arg pp_effort "$POST_EFFORT" \
        '. + { post_process: { prompt: $pp_prompt, model: $pp_model } }
        | if $pp_effort != "" then .post_process.effort = $pp_effort else . end')
fi

# ---- Review and write ----

echo ""
echo "=== Generated config ==="
echo "$CONFIG" | jq .
echo ""

TOTAL=$(echo "$CONFIG" | jq '[.agents[].count] | add')
echo "Total agents: ${TOTAL}"
echo "Output: ${OUTPUT}"
echo ""

if yesno "Write ${OUTPUT}?"; then
    echo "$CONFIG" | jq . > "$OUTPUT"
    echo "Config written to ${OUTPUT}"
    echo ""
    if yesno "Launch swarm now?"; then
        "$SWARM_DIR/launch.sh" start
    fi
else
    echo "Aborted."
fi
