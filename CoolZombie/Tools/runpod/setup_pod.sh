#!/usr/bin/env bash
# Environment for the Untold AI-animation pod (Phase 1: Kimodo + ARDY clip generation).
#
# Idempotent: re-run after every pod (re)start. Everything lives under /workspace, the only
# path that survives a stop (the container disk, /root, apt state and PATH edits do not).
#
#   bash /workspace/tools/setup_pod.sh                   # installs everything that is not gated
#   source /workspace/env.sh && hf auth login            # once, by the user: token with access to
#                                                        #   meta-llama/Meta-Llama-3-8B-Instruct
#   bash /workspace/tools/setup_pod.sh                   # re-run: fetches the gated text-encoder base
set -euo pipefail

WS=${WS:-/workspace}
KIMODO_REPO=https://github.com/nv-tlabs/kimodo
KIMODO_SHA=1aece8c124d73d255ceff5086d983b844c9f4e94    # 2026-07-13 "update README with ARDY"
ARDY_REPO=https://github.com/nv-tlabs/ardy
ARDY_SHA=693f74d13b3d04a0a22ce127ee79c929dd89756b      # 2026-07-09 initial commit
TORCH_SPEC=${TORCH_SPEC:-"torch==2.8.0"}
TORCH_INDEX=${TORCH_INDEX:-https://download.pytorch.org/whl/cu128}   # Blackwell (sm_120) needs CUDA >= 12.8 wheels

log() { printf '\n== %s\n' "$*"; }

mkdir -p "$WS"/{bin,repos,venvs,hf,out,logs,tools} "$WS"/.cache/{uv,uv-python}

cat > "$WS/env.sh" <<EOF
# Source this in every shell/command on the pod: env vars given at pod creation reach PID 1 only.
export WS=$WS
export HF_HOME=$WS/hf
export UV_CACHE_DIR=$WS/.cache/uv
export UV_PYTHON_INSTALL_DIR=$WS/.cache/uv-python
export TEXT_ENCODER_URL=http://127.0.0.1:9550/
export PATH=$WS/venvs/kimodo/bin:$WS/bin:\$PATH   # hf, kimodo_gen, kimodo_convert on PATH
export KIMODO_PY=$WS/venvs/kimodo/bin/python
export ARDY_PY=$WS/venvs/ardy/bin/python
EOF
# shellcheck disable=SC1090
source "$WS/env.sh"

log "system packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends cmake build-essential git rsync tmux curl ca-certificates >/dev/null

log "uv (persisted under $WS/bin)"
if [ ! -x "$WS/bin/uv" ]; then
  curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR="$WS/bin" UV_NO_MODIFY_PATH=1 sh
fi
uv --version

log "repos (pinned)"
clone_pin() {
  local url=$1 dir=$2 sha=$3
  [ -d "$dir/.git" ] || git clone -q "$url" "$dir"
  git -C "$dir" fetch -q origin
  git -C "$dir" checkout -q "$sha"
  echo "  $dir @ $(git -C "$dir" rev-parse --short HEAD)"
}
clone_pin "$KIMODO_REPO" "$WS/repos/kimodo" "$KIMODO_SHA"
clone_pin "$ARDY_REPO" "$WS/repos/ardy" "$ARDY_SHA"

# Separate venvs: kimodo pins transformers==5.1.0, ardy pins transformers==5.8.1.
log "kimodo venv (python 3.10, $TORCH_SPEC cu128)"
[ -x "$KIMODO_PY" ] || uv venv --python 3.10 "$WS/venvs/kimodo"
uv pip install --python "$KIMODO_PY" "$TORCH_SPEC" --index-url "$TORCH_INDEX"
# protobuf/sentencepiece: transformers' tokenizer fallback needs them (the text-encoder server
# died without them on the migrated pod, 2026-09-09).
uv pip install --python "$KIMODO_PY" -e "$WS/repos/kimodo" "huggingface_hub>=1.0" "scipy" "protobuf" "sentencepiece"
uv pip install --python "$KIMODO_PY" "viser @ git+https://github.com/nv-tlabs/kimodo-viser.git" \
  || echo "WARN: kimodo-viser (interactive demo) did not install; CLI generation is unaffected"
uv pip install --python "$KIMODO_PY" "py-soma-x @ git+https://github.com/NVlabs/SOMA-X.git" \
  || echo "WARN: py-soma-x (SOMA layer skinning) did not install; BVH export is unaffected"

log "ardy venv (python 3.11, $TORCH_SPEC cu128)"
[ -x "$ARDY_PY" ] || uv venv --python 3.11 "$WS/venvs/ardy"
uv pip install --python "$ARDY_PY" "$TORCH_SPEC" --index-url "$TORCH_INDEX"
uv pip install --python "$ARDY_PY" -e "$WS/repos/ardy[demo]" "huggingface_hub>=1.0" \
  || uv pip install --python "$ARDY_PY" -e "$WS/repos/ardy" "huggingface_hub>=1.0"

HF="$WS/venvs/kimodo/bin/hf"
log "checkpoints (NVIDIA Open Model License / MIT adapters; not gated) -> $HF_HOME"
for repo in nvidia/Kimodo-SOMA-RP-v1.1 nvidia/ARDY-Core-RP-20FPS-Horizon40 \
            McGill-NLP/LLM2Vec-Meta-Llama-3-8B-Instruct-mntp \
            McGill-NLP/LLM2Vec-Meta-Llama-3-8B-Instruct-mntp-supervised; do
  "$HF" download "$repo" >/dev/null && echo "  ok  $repo"
done

log "text-encoder base model (gated: meta-llama/Meta-Llama-3-8B-Instruct)"
# The stored token decides, not `hf auth whoami`: that endpoint is rate-limited so strictly that
# the login itself plus one check can exhaust it from a shared data-center IP.
if [ -s "$HF_HOME/token" ]; then
  "$HF" download meta-llama/Meta-Llama-3-8B-Instruct --exclude "original/*" >/dev/null \
    && echo "  ok  meta-llama/Meta-Llama-3-8B-Instruct"
else
  cat <<MSG
  NOT LOGGED IN to Hugging Face. The LLM2Vec text encoder needs the gated Llama-3-8B-Instruct
  weights. Once, with an account that has access to that repo:
      source $WS/env.sh && hf auth login     # paste the token; it is stored under $HF_HOME
      bash $WS/tools/setup_pod.sh            # re-run to fetch the weights (~16 GB)
MSG
fi

log "verify"
nvidia-smi -L || true
"$KIMODO_PY" - <<'PY'
import torch, kimodo
name = torch.cuda.get_device_name(0) if torch.cuda.is_available() else "no gpu"
print("kimodo ok | torch", torch.__version__, "| cuda", torch.cuda.is_available(), "|", name)
PY
"$ARDY_PY" - <<'PY'
import torch, ardy
print("ardy ok | torch", torch.__version__, "| cuda", torch.cuda.is_available())
PY
echo
echo "done. next: bash $WS/tools/start_text_encoder.sh ; bash $WS/tools/start_text_encoder.sh --wait ; bash $WS/tools/smoke_test.sh"
