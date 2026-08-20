#!/bin/sh

set -eu

if [ -z "${OLLAMA_API_KEY:-}" ]; then
  printf "Ollama API key: " >&2
  trap 'stty echo' EXIT HUP INT TERM
  stty -echo
  IFS= read -r OLLAMA_API_KEY
  stty echo
  trap - EXIT HUP INT TERM
  printf "\n" >&2
fi

OLLAMA_MODEL="${OLLAMA_MODEL:-deepseek-v4-flash:0731-cloud}"

export ANTHROPIC_BASE_URL="https://ollama.com"
export ANTHROPIC_AUTH_TOKEN="$OLLAMA_API_KEY"
export ANTHROPIC_DEFAULT_OPUS_MODEL="$OLLAMA_MODEL"
export ANTHROPIC_DEFAULT_SONNET_MODEL="$OLLAMA_MODEL"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$OLLAMA_MODEL"
export CLAUDE_CODE_SUBAGENT_MODEL="$OLLAMA_MODEL"
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export CLAUDE_CODE_ATTRIBUTION_HEADER=0

exec claude "$@"
