#!/bin/bash
set -euo pipefail

# Container entrypoint: clone, setup, loop opencode sessions.

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    cat <<HELP
Usage: $0

Container entrypoint for swarm agents. Not intended to be run
directly -- launched automatically inside Docker by launch.sh.

Clones the bare repo, runs optional setup, then loops opencode
sessions until the agent is idle for MAX_IDLE cycles.

Required environment:
  SWARM_PROMPT   Path to prompt file (relative to repo root).
  OPENCODE_MODEL Model to use for opencode sessions.

Optional environment:
  AGENT_ID       Agent identifier (default: unnamed).
  SWARM_SETUP    Setup script to run before first session.
  MAX_IDLE       Idle sessions before exit (default: 3).
  INJECT_GIT_RULES  Inject git coordination rules (default: true).
  SWARM_CONTEXT  Context mode: full (default), slim, or none.
  OPENCODE_EFFORT  Reasoning effort: low, medium, high.
HELP
    exit 0
fi

AGENT_ID="${AGENT_ID:-unnamed}"
OPENCODE_MODEL="${OPENCODE_MODEL:-anthropic/claude-opus-4-6}"
SWARM_PROMPT="${SWARM_PROMPT:?SWARM_PROMPT is required.}"
SWARM_SETUP="${SWARM_SETUP:-}"
MAX_IDLE="${MAX_IDLE:-3}"
INJECT_GIT_RULES="${INJECT_GIT_RULES:-true}"
SWARM_CONTEXT="${SWARM_CONTEXT:-full}"
OPENCODE_EFFORT="${OPENCODE_EFFORT:-}"
STATS_FILE="agent_logs/stats_agent_${AGENT_ID}.tsv"

GREEN=$'\033[32m'
RED=$'\033[31m'
RST=$'\033[0m'

hlog() {
    printf '%s%s harness[%s] %s%s\n' \
        "$GREEN" "$(date +%H:%M:%S)" "$AGENT_ID" "$*" "$RST"
}

hlog_err() {
    printf '%s%s harness[%s] %s%s\n' \
        "$RED" "$(date +%H:%M:%S)" "$AGENT_ID" "$*" "$RST"
}

hlog_pipe() {
    while IFS= read -r line; do
        printf '%s%s harness[%s] %s%s\n' \
            "$GREEN" "$(date +%H:%M:%S)" "$AGENT_ID" "$line" "$RST"
    done
}

GIT_USER_NAME="${GIT_USER_NAME:-swarm-agent}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-agent@claude-swarm.local}"
git config --global user.name "$GIT_USER_NAME"
git config --global user.email "$GIT_USER_EMAIL"

# Capture CLI version once for the prepare-commit-msg hook.
OPENCODE_VERSION=$(opencode --version 2>/dev/null || echo "unknown")
OPENCODE_VERSION="${OPENCODE_VERSION%% *}"
export OPENCODE_VERSION
export SWARM_RUN_CONTEXT="${SWARM_RUN_CONTEXT:-unknown}"
export SWARM_CFG_PROMPT="${SWARM_CFG_PROMPT:-${SWARM_PROMPT}}"
export SWARM_CFG_SETUP="${SWARM_CFG_SETUP:-${SWARM_SETUP}}"

# Map effort levels to opencode --variant values.
# Known aliases are translated; unknown values pass through
# as-is so provider-specific variants work directly.
VARIANT_ARG=""
case "${OPENCODE_EFFORT}" in
    "")     ;;
    low)    VARIANT_ARG="--variant minimal" ;;
    medium) VARIANT_ARG="--variant high" ;;
    high)   VARIANT_ARG="--variant max" ;;
    *)      VARIANT_ARG="--variant ${OPENCODE_EFFORT}" ;;
esac

hlog "starting model=${OPENCODE_MODEL} prompt=${SWARM_PROMPT} context=${SWARM_CONTEXT}"

if [ ! -d "/workspace/.git" ]; then
    hlog "cloning upstream"
    git clone -q /upstream /workspace
    cd /workspace

    # Init only submodules whose mirrors were mounted into the
    # container. Client submodules without mirrors keep their
    # upstream URLs and are left for the agent to init on demand.
    if [ -f .gitmodules ]; then
        git config --file .gitmodules --get-regexp 'submodule\..*\.path' | \
        while read -r key path; do
            name="${key#submodule.}"
            name="${name%.path}"
            if [ -d "/mirrors/${name}" ]; then
                git config "submodule.${name}.url" "/mirrors/${name}"
                git submodule update --init -q -- "$path"
            fi
        done
    fi

    git checkout -q agent-work

    # Strip context directories per the context mode setting.
    # See: "Evaluating AGENTS.md" (arXiv:2602.11988) for motivation.
    for ctx_dir in .claude .opencode; do
        if [ -d "$ctx_dir" ]; then
            case "$SWARM_CONTEXT" in
                none)
                    hlog "context=none: removing ${ctx_dir}/"
                    rm -rf "$ctx_dir"
                    ;;
                slim)
                    hlog "context=slim: keeping only ${ctx_dir}/CLAUDE.md"
                    find "$ctx_dir" -mindepth 1 -maxdepth 1 \
                        ! -name CLAUDE.md \
                        -exec rm -rf {} +
                    ;;
            esac
        fi
    done

    # Run project-specific setup if provided.
    if [ -n "$SWARM_SETUP" ] && [ -f "$SWARM_SETUP" ]; then
        hlog "running setup ${SWARM_SETUP}"
        sudo bash "$SWARM_SETUP"
        # Setup runs as root; reclaim ownership so the agent user
        # (and git reset on restart) can modify all workspace files.
        sudo chown -R "$(id -u):$(id -g)" /workspace
    fi

    # Install swarm agent definition for opencode.
    mkdir -p .opencode/agents
    cp /swarm-agent.md .opencode/agents/swarm.md

    # Install prepare-commit-msg hook to append provenance trailers.
    # Fires on every commit including git commit -m.
    SWARM_VERSION=$(cat /swarm-version 2>/dev/null || echo "unknown")
    export SWARM_VERSION
    mkdir -p .git/hooks
    cat > .git/hooks/prepare-commit-msg <<'HOOK'
#!/bin/bash
if ! grep -q '^Model:' "$1"; then
    printf '\nModel: %s\nTools: swarm %s, OpenCode %s\n' \
        "$OPENCODE_MODEL" "$SWARM_VERSION" "$OPENCODE_VERSION" >> "$1"
    printf '> Run: %s\n' "$SWARM_RUN_CONTEXT" >> "$1"
    cfg="$SWARM_CFG_PROMPT"
    [ -n "$SWARM_CFG_SETUP" ] && cfg="${cfg}, ${SWARM_CFG_SETUP}"
    printf '> Cfg: %s\n' "$cfg" >> "$1"
    ctx_label="$SWARM_CONTEXT"
    [ "$ctx_label" = "none" ] && ctx_label="bare"
    [ "$SWARM_CONTEXT" != "full" ] && \
        printf '> Ctx: %s\n' "$ctx_label" >> "$1" || true
fi
HOOK
    chmod +x .git/hooks/prepare-commit-msg

    # post-rewrite hook: re-inject trailers lost during rebase/amend.
    # Not affected by --no-verify, so acts as a safety net.
    cat > .git/hooks/post-rewrite <<'HOOK'
#!/bin/bash
# Amend HEAD if provenance trailers were lost during rebase/amend.
msg=$(git log -1 --format='%B' HEAD 2>/dev/null) || exit 0
if printf '%s' "$msg" | grep -q '^Model:'; then
    exit 0
fi
trailer=$(printf '\nModel: %s\nTools: swarm %s, OpenCode %s\n' \
    "$OPENCODE_MODEL" "$SWARM_VERSION" "$OPENCODE_VERSION")
trailer+=$(printf '> Run: %s\n' "$SWARM_RUN_CONTEXT")
cfg="$SWARM_CFG_PROMPT"
[ -n "$SWARM_CFG_SETUP" ] && cfg="${cfg}, ${SWARM_CFG_SETUP}"
trailer+=$(printf '> Cfg: %s\n' "$cfg")
ctx_label="$SWARM_CONTEXT"
[ "$ctx_label" = "none" ] && ctx_label="bare"
[ "$SWARM_CONTEXT" != "full" ] && \
    trailer+=$(printf '> Ctx: %s\n' "$ctx_label") || true
git commit --amend --no-verify --no-edit -m "${msg}${trailer}" \
    --allow-empty >/dev/null 2>&1 || true
HOOK
    chmod +x .git/hooks/post-rewrite

    # pre-commit hook: prevent accidental submodule pointer changes.
    cat > .git/hooks/pre-commit <<'HOOK'
#!/bin/bash
# Silently unstage submodule pointer changes so agents can't
# accidentally commit a submodule bump via broad `git add`.
changed_subs=$(git diff --cached --diff-filter=M --name-only | while read -r path; do
    if git ls-tree HEAD -- "$path" 2>/dev/null | grep -q '^160000 '; then
        echo "$path"
    fi
done)
if [ -n "$changed_subs" ]; then
    echo "$changed_subs" | while read -r sub; do
        git reset -q HEAD -- "$sub" 2>/dev/null || true
    done
fi
HOOK
    chmod +x .git/hooks/pre-commit

    mkdir -p agent_logs
    hlog "setup complete"
fi

cd /workspace
STATS_FILE="/workspace/${STATS_FILE}"

IDLE_COUNT=0

while true; do
    # Reset to latest. Do not re-init submodules; setup changes would be lost.
    git fetch --no-recurse-submodules origin 2>&1 | hlog_pipe
    git reset --hard origin/agent-work 2>&1 | hlog_pipe

    BEFORE=$(git rev-parse origin/agent-work)
    COMMIT=$(git rev-parse --short=6 HEAD)
    LOGFILE="agent_logs/agent_${AGENT_ID}_${COMMIT}_$(date +%s).log"
    mkdir -p agent_logs

    hlog "session start at=${COMMIT}"

    if [ ! -f "$SWARM_PROMPT" ]; then
        hlog_err "prompt file not found: ${SWARM_PROMPT}, skipping"
        sleep 2
        continue
    fi

    # Build prompt text: task prompt + optional git rules.
    PROMPT_TEXT=$(cat "$SWARM_PROMPT")
    if [ "$INJECT_GIT_RULES" = "true" ] && [ -f /agent-system-prompt.md ]; then
        PROMPT_TEXT="${PROMPT_TEXT}

$(cat /agent-system-prompt.md)"
    fi

    # shellcheck disable=SC2086
    opencode run "$PROMPT_TEXT" \
        --model "$OPENCODE_MODEL" \
        --agent swarm \
        ${VARIANT_ARG:+$VARIANT_ARG} \
        --format json \
        --dir /workspace 2>"${LOGFILE}.err" \
        | stdbuf -oL tee "$LOGFILE" \
        | /activity-filter.sh || true

    # Extract usage stats from step_finish events in the NDJSON stream.
    # Sum across all step_finish events (multiple per session possible).
    cost=$(jq -s '[.[] | select(.type=="step_finish")
        | .part.cost // 0] | add // 0' "$LOGFILE" 2>/dev/null || echo 0)
    cost="${cost:-0}"
    tok_in=$(jq -s '[.[] | select(.type=="step_finish")
        | .part.tokens.input // 0] | add // 0' "$LOGFILE" 2>/dev/null || echo 0)
    tok_in="${tok_in:-0}"
    tok_out=$(jq -s '[.[] | select(.type=="step_finish")
        | .part.tokens.output // 0] | add // 0' "$LOGFILE" 2>/dev/null || echo 0)
    tok_out="${tok_out:-0}"
    cache_rd=$(jq -s '[.[] | select(.type=="step_finish")
        | .part.tokens.cache.read // 0] | add // 0' "$LOGFILE" 2>/dev/null || echo 0)
    cache_rd="${cache_rd:-0}"
    cache_cr=$(jq -s '[.[] | select(.type=="step_finish")
        | .part.tokens.cache.write // 0] | add // 0' "$LOGFILE" 2>/dev/null || echo 0)
    cache_cr="${cache_cr:-0}"

    # Duration: first step_start to last step_finish timestamp.
    ts_start=$(jq -s '[.[] | select(.type=="step_start")
        | .timestamp // 0] | min // 0' "$LOGFILE" 2>/dev/null || echo 0)
    ts_end=$(jq -s '[.[] | select(.type=="step_finish")
        | .timestamp // 0] | max // 0' "$LOGFILE" 2>/dev/null || echo 0)
    if [ "$ts_start" -gt 0 ] && [ "$ts_end" -gt 0 ]; then
        dur=$(( (ts_end - ts_start) * 1000 ))
    else
        dur=0
    fi

    # API time not separately tracked; use same as wall duration.
    api_ms="$dur"

    # Turns: count step_finish events.
    turns=$(jq -s '[.[] | select(.type=="step_finish")] | length' \
        "$LOGFILE" 2>/dev/null || echo 0)
    turns="${turns:-0}"

    mkdir -p "$(dirname "$STATS_FILE")"
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$(date +%s)" "$cost" "$tok_in" "$tok_out" \
        "$cache_rd" "$cache_cr" "$dur" "$api_ms" "$turns" \
        >> "$STATS_FILE"
    hlog "session end cost=\$${cost} in=${tok_in} out=${tok_out} turns=${turns} time=${dur}ms"

    git fetch --no-recurse-submodules origin 2>&1 | hlog_pipe
    AFTER=$(git rev-parse origin/agent-work)

    if [ "$BEFORE" = "$AFTER" ]; then
        IDLE_COUNT=$((IDLE_COUNT + 1))
        hlog "no commits (idle ${IDLE_COUNT}/${MAX_IDLE})"
        if [ "$IDLE_COUNT" -ge "$MAX_IDLE" ]; then
            hlog "idle limit reached, exiting"
            exit 0
        fi
    else
        IDLE_COUNT=0
        hlog "session end, restarting"
    fi
done
