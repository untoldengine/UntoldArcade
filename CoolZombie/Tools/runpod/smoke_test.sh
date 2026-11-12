#!/usr/bin/env bash
# One short Kimodo generation with BVH export: proves model download, CUDA, text encoding and export.
set -euo pipefail
source "${WS:-/workspace}/env.sh"
OUT="$WS/out/smoke"; mkdir -p "$OUT"
time "$WS/venvs/kimodo/bin/kimodo_gen" "A person walks forward." \
  --model Kimodo-SOMA-RP-v1.1 --duration 3.0 --seed 0 --diffusion_steps 50 \
  --bvh --bvh_standard_tpose --output "$OUT/walk"
ls -la "$OUT"
"$KIMODO_PY" - <<PY
import numpy as np
d = np.load("$OUT/walk.npz")
print({k: d[k].shape for k in d.files})
PY
head -c 300 "$OUT/walk.bvh"; echo; grep -m2 "Frames\|Frame Time" "$OUT/walk.bvh"
