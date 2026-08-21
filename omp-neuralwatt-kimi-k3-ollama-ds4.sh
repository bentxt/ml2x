#!/bin/sh

set -eu

# Main session: Neuralwatt Kimi K3 at maximum reasoning effort.
# General subagents: Ollama Cloud DeepSeek V4 Flash 0731 at maximum effort,
# using Ollama's OpenAI-compatible SSE transport instead of native JSONL.
# Scout/lightweight subagents: the same DeepSeek model at high effort.
MAIN_MODEL="neuralwatt/kimi-k3:max"
TASK_MODEL="ollama-openai/deepseek-v4-flash:0731:max"
SMOL_MODEL="ollama-openai/deepseek-v4-flash:0731:high"
# OMP resolves --model before extension providers are registered. This bundled
# model is used only during startup; session_start immediately selects Kimi K3.
BOOT_MODEL="ollama-cloud/deepseek-v4-flash:0731:max"

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
RUNTIME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/omp-neuralwatt-kimi-ollama-ds4.XXXXXX")
OMP_CONFIG="$RUNTIME_DIR/config.yml"
OMP_EXTENSION="$RUNTIME_DIR/custom-providers.js"

cleanup() {
  rm -f "$OMP_CONFIG" "$OMP_EXTENSION"
  rmdir "$RUNTIME_DIR" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

# Register Neuralwatt and an OpenAI-compatible Ollama Cloud transport for this
# process. The latter avoids OMP's native Ollama JSONL response parser.
cat >"$OMP_EXTENSION" <<'EOF'
export default function customProviders(pi) {
  const neuralwattApiKey = process.env.NEURALWATT_API_KEY;
  const ollamaApiKey = process.env.OLLAMA_CLOUD_API_KEY;
  if (!neuralwattApiKey) {
    throw new Error("NEURALWATT_API_KEY is missing");
  }
  if (!ollamaApiKey) {
    throw new Error("OLLAMA_CLOUD_API_KEY is missing");
  }

  pi.registerProvider("neuralwatt", {
    baseUrl: "https://api.neuralwatt.com/v1",
    apiKey: neuralwattApiKey,
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

  pi.registerProvider("ollama-openai", {
    baseUrl: "https://ollama.com/v1",
    apiKey: ollamaApiKey,
    authHeader: true,
    api: "openai-completions",
    compat: {
      supportsDeveloperRole: false,
      supportsReasoningEffort: true,
      supportsUsageInStreaming: true,
    },
    models: [
      {
        id: "deepseek-v4-flash:0731",
        name: "DeepSeek V4 Flash 0731 (Ollama OpenAI transport)",
        reasoning: true,
        input: ["text"],
        contextWindow: 1048576,
        maxTokens: 65536,
        cost: {
          input: 0,
          output: 0,
          cacheRead: 0,
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

  // OMP resolves --model before extension providers are registered.
  // Start on the bundled Ollama model, then select Neuralwatt once the live
  // session and the extension-backed model registry are available.
  pi.on("session_start", async (_event, ctx) => {
    const model = ctx.models.resolve("neuralwatt/kimi-k3");
    if (!model) {
      ctx.ui.notify(
        "Neuralwatt Kimi K3 was registered but could not be resolved",
        "error",
      );
      return;
    }

    const selected = await pi.setModel(model);
    if (!selected) {
      ctx.ui.notify("OMP could not select Neuralwatt Kimi K3", "error");
      return;
    }

    pi.setThinkingLevel("max");
    ctx.ui.notify("Main model: Neuralwatt Kimi K3 (max)", "info");
  });
}
EOF

# This configuration is private to this invocation. It does not modify the
# user's normal OMP configuration.
printf '%s\n' \
  'modelRoles:' \
  "  default: \"$TASK_MODEL\"" \
  "  task: \"$TASK_MODEL\"" \
  "  smol: \"$SMOL_MODEL\"" \
  "  tiny: \"$SMOL_MODEL\"" \
  'task:' \
  '  showResolvedModelBadge: true' \
  'retry:' \
  '  enabled: true' \
  '  maxRetries: 3' \
  '  baseDelayMs: 500' \
  '  maxDelayMs: 5000' \
  '  modelFallback: true' \
  '  fallbackChains:' \
  '    default:' \
  "      - \"$TASK_MODEL\"" \
  "      - \"$MAIN_MODEL\"" \
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
  --model "$BOOT_MODEL" \
  "$@"
OMP_STATUS=$?
set -e

exit "$OMP_STATUS"
