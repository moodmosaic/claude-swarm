# swarm

N OpenCode instances in Docker, coordinating through git.
No orchestrator, no message passing.

Based on the agent-team pattern from
[Building a C Compiler with Large Language Models](https://www.anthropic.com/engineering/building-c-compiler).

## Prerequisites

- Docker
- bash, git, jq, bc
- [OpenCode CLI](https://opencode.ai) with auth configured

## Setup

Add as a submodule:

    git submodule add <url> tools/swarm

## How it works

```
Host                         /tmp (bare repos)
~/project/ ── git clone ──>  project-upstream.git (rw)
               --bare        project-mirror-*.git (ro)
                                        |
                                        | docker volumes
                                        |
                 .-----------.----------+-----------.
                 |           |          |           |
           Container 1            Container 2       ...
           /upstream  (rw)        /upstream  (rw)
           /mirrors/* (ro)        /mirrors/* (ro)
                 |                      |
                 v                      v
           /workspace/            /workspace/
           (agent-work)           (agent-work)
```

All containers mount the same bare repo. When one agent
pushes, others see the changes on the next fetch.

Each container runs `lib/harness.sh`:

1. Clones `/upstream` to `/workspace`.
2. Points submodule URLs at local read-only mirrors.
3. Runs an optional setup hook (`SWARM_SETUP`).
4. Loops: reset to `origin/agent-work`, run one OpenCode
   session with `--format json`.

Agent activity (tool calls, file edits, shell commands)
streams to Docker logs in real time via `lib/activity-filter.sh`.
Press `[1-9]` in the dashboard to watch what an agent is doing.

Agents stop after `SWARM_MAX_IDLE` consecutive idle sessions.
A session is one `opencode run` invocation. After it exits the
harness checks whether `agent-work` advanced. If not, the
idle counter increments. Any push resets it.

## Configuration

### Config file (recommended)

Place a `swarm.json` in your repo root, or point to one
with `SWARM_CONFIG=/path/to/config.json`:

```json
{
  "prompt": "prompts/task.md",
  "setup": "scripts/setup.sh",
  "max_idle": 3,
  "agents": [
    { "count": 2, "model": "anthropic/claude-opus-4-6", "effort": "high" },
    { "count": 1, "model": "anthropic/claude-opus-4-6", "context": "none" },
    { "count": 1, "model": "anthropic/claude-sonnet-4-6", "effort": "low", "prompt": "prompts/review.md" },
    {
      "count": 3,
      "model": "openrouter/custom",
      "api_key": "sk-or-..."
    }
  ],
  "inject_git_rules": true,
  "post_process": {
    "prompt": "prompts/review.md",
    "model": "anthropic/claude-opus-4-6",
    "effort": "low"
  }
}
```

Auth is handled via `~/.local/share/opencode/auth.json`,
mounted read-only into containers. Per-agent `api_key`
fields generate per-container OpenCode configs. Total
agents = sum of `count` fields. Requires `jq`.

Model names use `provider/model` format. Bare names
(e.g. `claude-opus-4-6`) are auto-prefixed with
`anthropic/`.

**Fields:**

| Field | Values | Notes |
|-------|--------|-------|
| `prompt` | file path | Per-group prompt override (default: top-level `prompt`). |
| `effort` | `low`, `medium`, `high`, or any string | Maps to `--variant`. Unknown values pass through as-is. |
| `context` | `full`, `slim`, `none` | How much of `.opencode/` to keep (default: `full`). |
| `inject_git_rules` | `true`, `false` | Append git coordination rules to prompt. |

Groups with `api_key` use their own key. The dashboard
shows auth per agent.

### Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `SWARM_PROMPT` | (required) | Prompt file path. |
| `SWARM_CONFIG` | | Config file path. |
| `SWARM_SETUP` | | Setup script path. |
| `SWARM_MODEL` | `claude-opus-4-6` | Model (auto-prefixed). |
| `SWARM_NUM_AGENTS` | `3` | Container count. |
| `SWARM_MAX_IDLE` | `3` | Idle sessions before exit. |
| `SWARM_EFFORT` | | Reasoning effort. |
| `SWARM_INJECT_GIT_RULES` | `true` | Inject git rules. |
| `SWARM_GIT_USER_NAME` | `swarm-agent` | Git author name. |
| `SWARM_GIT_USER_EMAIL` | `agent@claude-swarm.local` | Git email. |

Config file takes precedence when present.

### Third-party models

Use `provider/model` format in the config:

```json
{
  "agents": [
    {
      "count": 3,
      "model": "openrouter/custom",
      "api_key": "sk-or-..."
    }
  ]
}
```

Per-agent `api_key` and optional `base_url` generate
per-container OpenCode configuration files.

**Example: OpenAI GPT-5.4 with extra-high reasoning**

```json
{
  "prompt": "prompts/task.md",
  "agents": [
    {
      "count": 2,
      "model": "openai/gpt-5.4",
      "effort": "extra_high",
      "api_key": "$OPENAI_API_KEY"
    }
  ]
}
```

Known effort aliases (`low`→`minimal`, `medium`→`high`,
`high`→`max`) are translated; any other value (like
`extra_high`) passes through to `opencode run --variant`
as-is, so provider-specific reasoning levels work directly.

## Commands and usage

See [USAGE.md](USAGE.md).
