#!/bin/sh

set -eu

if [ -z "${SYNTHETIC_API_KEY:-}" ]; then
  printf "Synthetic API key: " >&2
  trap 'stty echo' EXIT HUP INT TERM
  stty -echo
  IFS= read -r SYNTHETIC_API_KEY
  stty echo
  trap - EXIT HUP INT TERM
  printf "\n" >&2
fi

SYNTHETIC_MODEL="${SYNTHETIC_MODEL:-hf:moonshotai/Kimi-K3}"

export ANTHROPIC_BASE_URL="https://api.synthetic.new/anthropic"
export ANTHROPIC_AUTH_TOKEN="$SYNTHETIC_API_KEY"
export ANTHROPIC_DEFAULT_OPUS_MODEL="$SYNTHETIC_MODEL"
export ANTHROPIC_DEFAULT_SONNET_MODEL="$SYNTHETIC_MODEL"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$SYNTHETIC_MODEL"
export CLAUDE_CODE_SUBAGENT_MODEL="$SYNTHETIC_MODEL"
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export CLAUDE_CODE_ATTRIBUTION_HEADER=0

exec claude "$@"
