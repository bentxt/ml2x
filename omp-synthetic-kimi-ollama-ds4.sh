#!/bin/sh

set -eu

MAIN_MODEL="synthetic/hf:moonshotai/Kimi-K3:max"
TASK_MODEL="ollama-cloud/deepseek-v4-flash:0731:max"
SMOL_MODEL="ollama-cloud/deepseek-v4-flash:0731:high"

if [ -n "${OMP_BIN:-}" ]; then
  if [ ! -x "$OMP_BIN" ]; then
    printf "OMP_BIN is not executable: %s\n" "$OMP_BIN" >&2
    exit 1
  fi
elif command -v omp >/dev/null 2>&1; then
  OMP_BIN=$(command -v omp)
elif [ -x "$HOME/.local/bin/omp" ]; then
  OMP_BIN="$HOME/.local/bin/omp"
else
  printf "OMP was not found in PATH or at %s/.local/bin/omp.\n" "$HOME" >&2
  exit 1
fi

read_secret() {
  secret_prompt=$1
  if [ ! -t 0 ]; then
    printf "%s must be set when standard input is not a terminal.\n" "$secret_prompt" >&2
    return 1
  fi

  printf "%s: " "$secret_prompt" >&2
  saved_stty=$(stty -g)
  trap 'stty "$saved_stty" 2>/dev/null || true' EXIT HUP INT TERM
  stty -echo
  IFS= read -r secret_value
  stty "$saved_stty"
  trap - EXIT HUP INT TERM
  printf "\n" >&2
  printf "%s" "$secret_value"
}

if [ -z "${SYNTHETIC_API_KEY:-}" ]; then
  SYNTHETIC_API_KEY=$(read_secret "Synthetic API key")
fi

if [ -z "${OLLAMA_CLOUD_API_KEY:-}" ]; then
  if [ -n "${OLLAMA_API_KEY:-}" ]; then
    OLLAMA_CLOUD_API_KEY=$OLLAMA_API_KEY
  else
    OLLAMA_CLOUD_API_KEY=$(read_secret "Ollama Cloud API key")
  fi
fi

if [ -z "$SYNTHETIC_API_KEY" ] || [ -z "$OLLAMA_CLOUD_API_KEY" ]; then
  printf "Both Synthetic and Ollama Cloud API keys are required.\n" >&2
  exit 1
fi

umask 077
RUNTIME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omp-kimi-ds4.XXXXXX")
OMP_CONFIG="$RUNTIME_DIR/config.yml"

cleanup() {
  rm -f "$OMP_CONFIG"
  rmdir "$RUNTIME_DIR" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

printf '%s\n' \
  'modelRoles:' \
  "  default: \"$MAIN_MODEL\"" \
  "  task: \"$TASK_MODEL\"" \
  "  smol: \"$SMOL_MODEL\"" \
  "  tiny: \"$SMOL_MODEL\"" \
  'task:' \
  '  showResolvedModelBadge: true' \
  'retry:' \
  '  enabled: true' \
  '  maxRetries: 2' \
  '  baseDelayMs: 500' \
  '  maxDelayMs: 5000' \
  '  modelFallback: true' \
  '  fallbackChains:' \
  '    default:' \
  "      - \"$MAIN_MODEL\"" \
  "      - \"$SMOL_MODEL\"" \
  '    task:' \
  "      - \"$TASK_MODEL\"" \
  "      - \"$MAIN_MODEL\"" \
  '    smol:' \
  "      - \"$SMOL_MODEL\"" \
  "      - \"$MAIN_MODEL\"" \
  >"$OMP_CONFIG"

set +e
SYNTHETIC_API_KEY="$SYNTHETIC_API_KEY" \
OLLAMA_CLOUD_API_KEY="$OLLAMA_CLOUD_API_KEY" \
"$OMP_BIN" --config "$OMP_CONFIG" --model "$MAIN_MODEL" "$@"
OMP_STATUS=$?
set -e

exit "$OMP_STATUS"
