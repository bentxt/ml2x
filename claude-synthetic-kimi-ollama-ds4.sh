#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROUTER_SCRIPT="$SCRIPT_DIR/claude-provider-router.py"

if [ -z "${SYNTHETIC_API_KEY:-}" ]; then
  printf "Synthetic API key: " >&2
  trap 'stty echo' EXIT HUP INT TERM
  stty -echo
  IFS= read -r SYNTHETIC_API_KEY
  stty echo
  trap - EXIT HUP INT TERM
  printf "\n" >&2
fi

if [ -z "${OLLAMA_API_KEY:-}" ]; then
  printf "Ollama API key: " >&2
  trap 'stty echo' EXIT HUP INT TERM
  stty -echo
  IFS= read -r OLLAMA_API_KEY
  stty echo
  trap - EXIT HUP INT TERM
  printf "\n" >&2
fi

ROUTER_RUNTIME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/claude-provider-router.XXXXXX")
ROUTER_PORT_FILE="$ROUTER_RUNTIME_DIR/port"
ROUTER_TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(24))')

cleanup() {
  if [ -n "${ROUTER_PID:-}" ]; then
    kill "$ROUTER_PID" 2>/dev/null || true
    wait "$ROUTER_PID" 2>/dev/null || true
  fi
  rm -f "$ROUTER_PORT_FILE"
  rmdir "$ROUTER_RUNTIME_DIR" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

SYNTHETIC_API_KEY="$SYNTHETIC_API_KEY" \
OLLAMA_API_KEY="$OLLAMA_API_KEY" \
CLAUDE_ROUTER_TOKEN="$ROUTER_TOKEN" \
python3 "$ROUTER_SCRIPT" --port-file "$ROUTER_PORT_FILE" &
ROUTER_PID=$!

attempt=0
while [ ! -s "$ROUTER_PORT_FILE" ]; do
  if ! kill -0 "$ROUTER_PID" 2>/dev/null; then
    printf "Provider router failed to start.\n" >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  if [ "$attempt" -ge 100 ]; then
    printf "Timed out waiting for provider router.\n" >&2
    exit 1
  fi
  sleep 0.05
done

ROUTER_PORT=$(sed -n '1p' "$ROUTER_PORT_FILE")
unset SYNTHETIC_API_KEY OLLAMA_API_KEY

MAIN_MODEL="hf:moonshotai/Kimi-K3"
SUBAGENT_MODEL="deepseek-v4-flash:0731-cloud"

export ANTHROPIC_BASE_URL="http://127.0.0.1:$ROUTER_PORT"
export ANTHROPIC_AUTH_TOKEN="$ROUTER_TOKEN"
export ANTHROPIC_MODEL="$MAIN_MODEL"
export ANTHROPIC_DEFAULT_OPUS_MODEL="$MAIN_MODEL"
export ANTHROPIC_DEFAULT_SONNET_MODEL="$MAIN_MODEL"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$MAIN_MODEL"
export CLAUDE_CODE_SUBAGENT_MODEL="$SUBAGENT_MODEL"
export CLAUDE_CODE_MAX_CONTEXT_TOKENS=524288
export CLAUDE_CODE_AUTO_COMPACT_WINDOW=500000
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
export CLAUDE_CODE_ATTRIBUTION_HEADER=0

set +e
claude "$@"
CLAUDE_STATUS=$?
set -e
exit "$CLAUDE_STATUS"
