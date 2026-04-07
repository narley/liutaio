ARG NODE_VERSION=22

FROM node:${NODE_VERSION}-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       git \
       openssh-client \
       jq \
       curl \
       ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN npm install -g @anthropic-ai/claude-code

# Non-root user (Claude Code refuses --dangerously-skip-permissions as root)
RUN useradd -m -s /bin/bash liutaio \
    && mkdir -p /workspace /credentials \
    && chown liutaio:liutaio /workspace /credentials

COPY entrypoint.sh /usr/local/bin/liutaio-entrypoint
RUN chmod +x /usr/local/bin/liutaio-entrypoint

USER liutaio
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/liutaio-entrypoint"]
