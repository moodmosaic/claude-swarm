FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    clang \
    make \
    jq \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# OpenCode requires a non-root user for agent permissions.
RUN useradd -m -s /bin/bash agent \
    && echo "agent ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/agent
USER agent

# Language toolchains are installed by SWARM_SETUP, not here.

RUN curl -fsSL https://opencode.ai/install -o /tmp/oc-install.sh \
    && bash /tmp/oc-install.sh \
    && rm /tmp/oc-install.sh
ENV PATH="/home/agent/.opencode/bin:${PATH}"

# Pre-create the opencode data directory so Docker file-level bind
# mounts (auth.json) don't create parent dirs as root.
RUN mkdir -p /home/agent/.local/share/opencode

# Trust mounted bare repos and allow file:// transport for submodules.
RUN git config --global --add safe.directory '*' \
    && git config --global protocol.file.allow always

COPY --chmod=755 lib/harness.sh /harness.sh
COPY --chmod=755 lib/activity-filter.sh /activity-filter.sh
COPY --chmod=644 lib/agent-system-prompt.md /agent-system-prompt.md
COPY --chmod=644 lib/swarm-agent.md /swarm-agent.md
COPY --chmod=644 VERSION /swarm-version

WORKDIR /workspace

ENTRYPOINT ["/harness.sh"]
