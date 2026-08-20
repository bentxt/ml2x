#!/bin/sh

set -eu

MAIN_MODEL="neuralwatt/kimi-k3:max"
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

if [ -z "${NEURALWATT_API_KEY:-}" ]; then
  NEURALWATT_API_KEY=$(read_secret "Neuralwatt API key")
fi

if [ -z "${OLLAMA_CLOUD_API_KEY:-}" ]; then
  if [ -n "${OLLAMA_API_KEY:-}" ]; then
    OLLAMA_CLOUD_API_KEY=$OLLAMA_API_KEY
  else
    OLLAMA_CLOUD_API_KEY=$(read_secret "Ollama Cloud API key")
  fi
fi

if [ -z "$NEURALWATT_API_KEY" ] || [ -z "$OLLAMA_CLOUD_API_KEY" ]; then
  printf "Both Neuralwatt and Ollama Cloud API keys are required.\n" >&2
  exit 1
fi

umask 077
RUNTIME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omp-neuralwatt-kimi.XXXXXX")
OMP_CONFIG="$RUNTIME_DIR/config.yml"
OMP_EXTENSION="$RUNTIME_DIR/neuralwatt-provider.js"

cleanup() {
  rm -f "$OMP_CONFIG" "$OMP_EXTENSION"
  rmdir "$RUNTIME_DIR" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

cat >"$OMP_EXTENSION" <<'EOF'
export default function neuralwattProvider(pi) {
  const apiKey = process.env.NEURALWATT_API_KEY;
  if (!apiKey) {
    throw new Error("NEURALWATT_API_KEY is missing");
  }

  pi.registerProvider("neuralwatt", {
    baseUrl: "https://api.neuralwatt.com/v1",
    apiKey,
    authHeader: true,
    api: "openai-completions",
    compat: {
      supportsDeveloperRole: false,
      supportsReasoningEffort: true,
      supportsUsageInStreaming: true,
    },
    models: [
      {
        id: "kimi-k3",
        name: "Kimi K3 (Neuralwatt)",
        reasoning: true,
        input: ["text", "image"],
        contextWindow: 1048560,
        maxTokens: 131072,
        cost: {
          input: 3.0,
          output: 15.0,
          cacheRead: 0.3,
          cacheWrite: 0,
        },
        thinking: {
          mode: "effort",
          efforts: ["low", "high", "max"],
          defaultLevel: "max",
          requiresEffort: true,
        },
      },
    ],
  });
}
EOF

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
NEURALWATT_API_KEY="$NEURALWATT_API_KEY" \
OLLAMA_CLOUD_API_KEY="$OLLAMA_CLOUD_API_KEY" \
"$OMP_BIN" \
  --extension "$OMP_EXTENSION" \
  --config "$OMP_CONFIG" \
  --model "$MAIN_MODEL" \
  "$@"
OMP_STATUS=$?
set -e

exit "$OMP_STATUS"
