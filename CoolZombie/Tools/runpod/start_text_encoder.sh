#!/usr/bin/env bash
# Start the shared LLM2Vec text-encoder service (Kimodo and ARDY both reach it through
# TEXT_ENCODER_URL; their loaders try the service first and fall back to an in-process copy).
# ~16 GB VRAM in bf16. Detached, so it survives the SSH session. `--wait` polls until it answers.
set -euo pipefail
source "${WS:-/workspace}/env.sh"
LOG="$WS/logs/text_encoder.log"
# Once the weights are cached the encoder never needs the hub, and the data-center IP is shared:
# an unlucky 429 on the model API used to kill it at startup (2026-09-09).
export HF_HUB_OFFLINE=${HF_HUB_OFFLINE:-1}
if [ "${1:-}" = "--wait" ]; then
  for i in $(seq 1 120); do
    if curl -sf -o /dev/null "$TEXT_ENCODER_URL"; then echo "text encoder up at $TEXT_ENCODER_URL"; exit 0; fi
    sleep 5
  done
  echo "text encoder did not answer within 10 min; tail of $LOG:"; tail -30 "$LOG"; exit 1
fi
if curl -sf -o /dev/null "$TEXT_ENCODER_URL"; then echo "already up at $TEXT_ENCODER_URL"; exit 0; fi
mkdir -p "$WS/logs"
setsid nohup "$WS/venvs/kimodo/bin/kimodo_textencoder" > "$LOG" 2>&1 < /dev/null &
echo "starting kimodo_textencoder (log: $LOG); run '$0 --wait' to block until it answers"
