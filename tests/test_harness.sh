#!/bin/bash
# shellcheck disable=SC2034
set -euo pipefail

# Unit tests for harness.sh stat extraction and logic.
# No Docker or API key required.

PASS=0
FAIL=0
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: ${label}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${label}"
        echo "        expected: ${expected}"
        echo "        actual:   ${actual}"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        echo "  PASS: ${label}"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${label}"
        echo "        expected to contain: ${needle}"
        echo "        actual:              ${haystack}"
        FAIL=$((FAIL + 1))
    fi
}

strip_ansi() { sed 's/\x1b\[[0-9;]*m//g'; }

# --- Helpers: same extraction logic used in harness.sh ---
# The harness uses opencode NDJSON output. Stats come from
# step_finish events, summed across all events.

extract_stats() {
    local logfile="$1"
    local cost tok_in tok_out cache_rd cache_cr dur api_ms turns

    cost=$(jq -s '[.[] | select(.type=="step_finish")
        | .part.cost // 0] | add // 0' "$logfile" 2>/dev/null || echo 0)
    cost="${cost:-0}"
    tok_in=$(jq -s '[.[] | select(.type=="step_finish")
        | .part.tokens.input // 0] | add // 0' "$logfile" 2>/dev/null || echo 0)
    tok_in="${tok_in:-0}"
    tok_out=$(jq -s '[.[] | select(.type=="step_finish")
        | .part.tokens.output // 0] | add // 0' "$logfile" 2>/dev/null || echo 0)
    tok_out="${tok_out:-0}"
    cache_rd=$(jq -s '[.[] | select(.type=="step_finish")
        | .part.tokens.cache.read // 0] | add // 0' "$logfile" 2>/dev/null || echo 0)
    cache_rd="${cache_rd:-0}"
    cache_cr=$(jq -s '[.[] | select(.type=="step_finish")
        | .part.tokens.cache.write // 0] | add // 0' "$logfile" 2>/dev/null || echo 0)
    cache_cr="${cache_cr:-0}"

    local ts_start ts_end
    ts_start=$(jq -s '[.[] | select(.type=="step_start")
        | .timestamp // 0] | min // 0' "$logfile" 2>/dev/null || echo 0)
    ts_end=$(jq -s '[.[] | select(.type=="step_finish")
        | .timestamp // 0] | max // 0' "$logfile" 2>/dev/null || echo 0)
    if [ "${ts_start:-0}" -gt 0 ] && [ "${ts_end:-0}" -gt 0 ]; then
        dur=$(( (ts_end - ts_start) * 1000 ))
    else
        dur=0
    fi
    api_ms="$dur"

    turns=$(jq -s '[.[] | select(.type=="step_finish")] | length' \
        "$logfile" 2>/dev/null || echo 0)
    turns="${turns:-0}"

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s" \
        "$(date +%s)" "$cost" "$tok_in" "$tok_out" \
        "$cache_rd" "$cache_cr" "$dur" "$api_ms" "$turns"
}

# ============================================================
echo "=== 1. OpenCode NDJSON output parsing ==="

cat > "$TMPDIR/stream.jsonl" <<'EOF'
{"type":"step_start","timestamp":1000,"sessionID":"s01","part":{"type":"step-start"}}
{"type":"tool_use","timestamp":1001,"part":{"type":"tool","callID":"c1","tool":"bash","state":{"status":"success","input":{"command":"ls -la"}}}}
{"type":"step_finish","timestamp":1020,"part":{"type":"step-finish","reason":"stop","cost":0.0823,"tokens":{"total":800,"input":500,"output":300,"reasoning":0,"cache":{"read":80000,"write":2000}}}}
EOF

LINE=$(extract_stats "$TMPDIR/stream.jsonl")
IFS=$'\t' read -r ts cost tok_in tok_out cache_rd cache_cr dur api_ms turns <<< "$LINE"

assert_eq "cost"     "0.0823"  "$cost"
assert_eq "tok_in"   "500"     "$tok_in"
assert_eq "tok_out"  "300"     "$tok_out"
assert_eq "cache_rd" "80000"   "$cache_rd"
assert_eq "cache_cr" "2000"    "$cache_cr"
assert_eq "dur"      "20000"   "$dur"
assert_eq "turns"    "1"       "$turns"

# ============================================================
echo ""
echo "=== 2. Multiple step_finish events (summed) ==="

cat > "$TMPDIR/multi.jsonl" <<'EOF'
{"type":"step_start","timestamp":1000,"sessionID":"s01","part":{"type":"step-start"}}
{"type":"step_finish","timestamp":1010,"part":{"type":"step-finish","reason":"stop","cost":0.05,"tokens":{"total":400,"input":200,"output":200,"cache":{"read":10000,"write":1000}}}}
{"type":"step_start","timestamp":1010,"sessionID":"s01","part":{"type":"step-start"}}
{"type":"step_finish","timestamp":1025,"part":{"type":"step-finish","reason":"stop","cost":0.08,"tokens":{"total":600,"input":300,"output":300,"cache":{"read":20000,"write":500}}}}
EOF

LINE=$(extract_stats "$TMPDIR/multi.jsonl")
IFS=$'\t' read -r ts cost tok_in tok_out cache_rd cache_cr dur api_ms turns <<< "$LINE"

assert_eq "multi cost"     "0.13"   "$cost"
assert_eq "multi tok_in"   "500"    "$tok_in"
assert_eq "multi tok_out"  "500"    "$tok_out"
assert_eq "multi cache_rd" "30000"  "$cache_rd"
assert_eq "multi cache_cr" "1500"   "$cache_cr"
assert_eq "multi dur"      "25000"  "$dur"
assert_eq "multi turns"    "2"      "$turns"

# ============================================================
echo ""
echo "=== 3. Missing fields default to 0 ==="

cat > "$TMPDIR/minimal.jsonl" <<'EOF'
{"type":"step_finish","timestamp":1000,"part":{"type":"step-finish","reason":"stop","cost":0.01}}
EOF

LINE=$(extract_stats "$TMPDIR/minimal.jsonl")
IFS=$'\t' read -r ts cost tok_in tok_out cache_rd cache_cr dur api_ms turns <<< "$LINE"

assert_eq "cost"     "0.01" "$cost"
assert_eq "tok_in"   "0"    "$tok_in"
assert_eq "tok_out"  "0"    "$tok_out"
assert_eq "cache_rd" "0"    "$cache_rd"
assert_eq "turns"    "1"    "$turns"

# ============================================================
echo ""
echo "=== 4. Empty file fallback ==="

: > "$TMPDIR/empty.jsonl"

LINE=$(extract_stats "$TMPDIR/empty.jsonl")
IFS=$'\t' read -r ts cost tok_in tok_out cache_rd cache_cr dur api_ms turns <<< "$LINE"

assert_eq "cost empty"  "0" "$cost"
assert_eq "turns empty" "0" "$turns"

# ============================================================
echo ""
echo "=== 5. TSV line format ==="

LINE=$(extract_stats "$TMPDIR/stream.jsonl")
FIELD_COUNT=$(echo "$LINE" | awk -F'\t' '{print NF}')
assert_eq "9 tab-separated fields" "9" "$FIELD_COUNT"

# ============================================================
echo ""
echo "=== 6. INJECT_GIT_RULES prompt concatenation ==="

build_prompt() {
    local inject="$1" file_exists="$2" task_text="base prompt"
    local prompt_text="$task_text"
    if [ "$inject" = "true" ] && [ "$file_exists" = "true" ]; then
        prompt_text="${prompt_text}

git rules appended"
    fi
    echo "$prompt_text"
}

assert_contains "inject=true, file=true" "git rules appended" \
    "$(build_prompt true true)"
result=$(build_prompt false true)
if echo "$result" | grep -q "git rules"; then
    echo "  FAIL: inject=false should not append"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: inject=false, file=true"
    PASS=$((PASS + 1))
fi
result=$(build_prompt true false)
if echo "$result" | grep -q "git rules"; then
    echo "  FAIL: file=false should not append"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: inject=true, file=false"
    PASS=$((PASS + 1))
fi

# ============================================================
echo ""
echo "=== 7. Idle counter logic ==="

simulate_idle() {
    local before="$1" after="$2" idle_count="$3" max_idle="$4"
    if [ "$before" = "$after" ]; then
        idle_count=$((idle_count + 1))
        if [ "$idle_count" -ge "$max_idle" ]; then
            echo "exit"
        else
            echo "idle:${idle_count}"
        fi
    else
        echo "reset"
    fi
}

assert_eq "same SHA increments"    "idle:1"  "$(simulate_idle abc123 abc123 0 3)"
assert_eq "same SHA at limit"      "exit"    "$(simulate_idle abc123 abc123 2 3)"
assert_eq "different SHA resets"   "reset"   "$(simulate_idle abc123 def456 2 3)"
assert_eq "max_idle=1 immediate"   "exit"    "$(simulate_idle abc123 abc123 0 1)"

# ============================================================
echo ""
echo "=== 7b. Prompt file guard ==="

# Mirrors the guard in harness.sh: skip session if prompt missing.
check_prompt() {
    local prompt_file="$1"
    if [ ! -f "$prompt_file" ]; then
        echo "skip"
    else
        echo "run"
    fi
}

assert_eq "missing prompt skips" "skip" \
    "$(check_prompt "$TMPDIR/nonexistent.md")"

touch "$TMPDIR/exists.md"
assert_eq "present prompt runs" "run" \
    "$(check_prompt "$TMPDIR/exists.md")"

# ============================================================
echo ""
echo "=== 8. prepare-commit-msg hook appends trailers ==="

# Mirrors the hook installed by harness.sh. Exercises it against
# a real git repo so we test actual commit behaviour.
HOOK_REPO="$TMPDIR/hook-repo"
mkdir -p "$HOOK_REPO"
git init -q "$HOOK_REPO"
git -C "$HOOK_REPO" config user.name "test"
git -C "$HOOK_REPO" config user.email "test@test"

mkdir -p "$HOOK_REPO/.git/hooks"
cat > "$HOOK_REPO/.git/hooks/prepare-commit-msg" <<'HOOK'
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
chmod +x "$HOOK_REPO/.git/hooks/prepare-commit-msg"

# Commit with prompt + setup (full context = no context trailer).
touch "$HOOK_REPO/file.txt"
git -C "$HOOK_REPO" add file.txt
OPENCODE_MODEL="anthropic/claude-opus-4-6" OPENCODE_VERSION="0.1.0" SWARM_VERSION="0.7.0" \
    SWARM_RUN_CONTEXT="netherfuzz@a3f8c21 (main)" \
    SWARM_CFG_PROMPT="prompts/task.md" SWARM_CFG_SETUP="scripts/setup.sh" \
    SWARM_CONTEXT="full" \
    git -C "$HOOK_REPO" commit -m "test commit" --quiet

MSG=$(git -C "$HOOK_REPO" log -1 --format='%B')
assert_eq "hook model trailer" \
    "Model: anthropic/claude-opus-4-6" \
    "$(echo "$MSG" | grep '^Model:')"
assert_eq "hook tools trailer" \
    "Tools: swarm 0.7.0, OpenCode 0.1.0" \
    "$(echo "$MSG" | grep '^Tools:')"
assert_eq "hook run trailer" \
    "> Run: netherfuzz@a3f8c21 (main)" \
    "$(echo "$MSG" | grep '^> Run:')"
assert_eq "hook cfg trailer" \
    "> Cfg: prompts/task.md, scripts/setup.sh" \
    "$(echo "$MSG" | grep '^> Cfg:')"
assert_eq "hook no ctx trailer (full)" \
    "0" \
    "$(echo "$MSG" | grep -c '> Ctx:' || true)"
assert_eq "hook subject preserved" \
    "test commit" \
    "$(echo "$MSG" | head -1)"

# Second commit with bare context (context=none trailer should appear).
echo "x" > "$HOOK_REPO/file2.txt"
git -C "$HOOK_REPO" add file2.txt
OPENCODE_MODEL="anthropic/MiniMax-M2.5" OPENCODE_VERSION="0.1.0" SWARM_VERSION="0.7.0" \
    SWARM_RUN_CONTEXT="gethfuzz@b4e9d12 (develop)" \
    SWARM_CFG_PROMPT="prompts/fuzz.md" SWARM_CFG_SETUP="" \
    SWARM_CONTEXT="none" \
    git -C "$HOOK_REPO" commit -m "second commit" --quiet

MSG2=$(git -C "$HOOK_REPO" log -1 --format='%B')
assert_eq "hook model trailer 2" \
    "Model: anthropic/MiniMax-M2.5" \
    "$(echo "$MSG2" | grep '^Model:')"
assert_eq "hook tools trailer 2" \
    "Tools: swarm 0.7.0, OpenCode 0.1.0" \
    "$(echo "$MSG2" | grep '^Tools:')"
assert_eq "hook run trailer 2" \
    "> Run: gethfuzz@b4e9d12 (develop)" \
    "$(echo "$MSG2" | grep '^> Run:')"
assert_eq "hook cfg no setup" \
    "> Cfg: prompts/fuzz.md" \
    "$(echo "$MSG2" | grep '^> Cfg:')"
assert_eq "hook ctx trailer (none)" \
    "> Ctx: bare" \
    "$(echo "$MSG2" | grep '^> Ctx:')"

# Idempotent: if trailers already present, hook does not duplicate.
echo "y" > "$HOOK_REPO/file3.txt"
git -C "$HOOK_REPO" add file3.txt
OPENCODE_MODEL="anthropic/claude-opus-4-6" OPENCODE_VERSION="0.1.0" SWARM_VERSION="0.7.0" \
    SWARM_RUN_CONTEXT="test@abc1234 (main)" \
    SWARM_CFG_PROMPT="p.md" SWARM_CFG_SETUP="" \
    SWARM_CONTEXT="full" \
    git -C "$HOOK_REPO" commit -m "$(printf 'manual trailers\n\nModel: already-set')" --quiet

MSG3=$(git -C "$HOOK_REPO" log -1 --format='%B')
MODEL_COUNT=$(echo "$MSG3" | grep -c '^Model:' || true)
assert_eq "hook no duplicate" "1" "$MODEL_COUNT"

# ============================================================
echo ""
echo "=== 9. Version string stripping ==="

# Mirrors the OPENCODE_VERSION="${OPENCODE_VERSION%% *}" in harness.sh.
strip_version() { local v="$1"; echo "${v%% *}"; }

assert_eq "strip suffix"   "0.1.52"  "$(strip_version '0.1.52 (OpenCode)')"
assert_eq "no suffix"      "0.1.52"  "$(strip_version '0.1.52')"
assert_eq "unknown"         "unknown" "$(strip_version 'unknown')"

# ============================================================
echo ""
echo "=== 10. hlog output format ==="

# Mirrors the log functions from harness.sh.
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

AGENT_ID=3
OUT=$(hlog "test message")
PLAIN=$(echo "$OUT" | strip_ansi)

assert_contains "hlog timestamp" \
    "$(date +%H:%M:%S)" "$PLAIN"
assert_contains "hlog prefix" "harness[3]" "$PLAIN"
assert_contains "hlog body" "test message" "$PLAIN"

# Green wrapping.
assert_contains "hlog green" $'\033[32m' "$OUT"
assert_contains "hlog reset" $'\033[0m' "$OUT"

# key=value style preserved.
AGENT_ID=1
OUT2=$(hlog "session end cost=\$0.18 in=777 out=691 turns=5 time=21s")
PLAIN2=$(echo "$OUT2" | strip_ansi)
assert_contains "hlog kv cost" "cost=\$0.18" "$PLAIN2"
assert_contains "hlog kv in" "in=777" "$PLAIN2"
assert_contains "hlog kv turns" "turns=5" "$PLAIN2"

# Idle message preserves dashboard-parseable pattern.
AGENT_ID=2
OUT3=$(hlog "no commits (idle 1/3)")
IDLE_MATCH=$(echo "$OUT3" | grep -o 'idle [0-9]*/[0-9]*' || true)
assert_eq "hlog idle pattern" "idle 1/3" "$IDLE_MATCH"

# hlog_err uses red.
OUT_ERR=$(hlog_err "prompt file not found")
assert_contains "hlog_err red" $'\033[31m' "$OUT_ERR"
assert_contains "hlog_err reset" $'\033[0m' "$OUT_ERR"
PLAIN_ERR=$(echo "$OUT_ERR" | strip_ansi)
assert_contains "hlog_err body" "prompt file not found" "$PLAIN_ERR"

# hlog_pipe timestamps and colors each line.
PIPE_OUT=$(printf 'line one\nline two\n' | AGENT_ID=7 hlog_pipe)
PIPE_PLAIN=$(echo "$PIPE_OUT" | strip_ansi)
PIPE_LINES=$(echo "$PIPE_PLAIN" | wc -l | tr -d ' ')
assert_eq "hlog_pipe two lines" "2" "$PIPE_LINES"
assert_contains "hlog_pipe line1" "harness[7] line one" "$PIPE_PLAIN"
assert_contains "hlog_pipe line2" "harness[7] line two" "$PIPE_PLAIN"
assert_contains "hlog_pipe green" $'\033[32m' "$PIPE_OUT"

# ============================================================
echo ""
echo "=== 11. Effort-to-variant mapping ==="

# Mirrors the case statement in harness.sh.
map_effort() {
    local OPENCODE_EFFORT="$1" VARIANT_ARG=""
    case "${OPENCODE_EFFORT}" in
        "")     ;;
        low)    VARIANT_ARG="--variant minimal" ;;
        medium) VARIANT_ARG="--variant high" ;;
        high)   VARIANT_ARG="--variant max" ;;
        *)      VARIANT_ARG="--variant ${OPENCODE_EFFORT}" ;;
    esac
    echo "$VARIANT_ARG"
}

assert_eq "effort low"        "--variant minimal" "$(map_effort low)"
assert_eq "effort medium"     "--variant high"    "$(map_effort medium)"
assert_eq "effort high"       "--variant max"     "$(map_effort high)"
assert_eq "effort empty"      ""                  "$(map_effort "")"
assert_eq "effort passthrough" "--variant extra_high" \
    "$(map_effort extra_high)"

# ============================================================
echo ""
echo "==============================="
echo "  ${PASS} passed, ${FAIL} failed"
echo "==============================="

[ "$FAIL" -eq 0 ]
