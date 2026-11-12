#!/usr/bin/env bash
# Retarget + cook the picked Kimodo samples in one Blender run.
#   Tools/runpod/retarget_batch.sh picks.json /tmp/kimodo_cook [RENDER=1]
# picks.json: {"<clip name>": "<path to the picked .npz>", ...} (triage_clips.py --json writes the
# defaults; edit after viewing). The .bvh next to each .npz is what gets retargeted. A value may
# also be an object {"npz": path, "start": 0.7, "end": -1.0, "idle": false, "loop": false} to trim
# the clip (seconds; end <= 0 counts from the clip's end), give it a static root, or close its loop
# seam (clips that play on repeat); cook_options.json next to this script supplies those per clip.
set -euo pipefail
PICKS=$1; OUT=$2
OPTIONS="$(dirname "$0")/cook_options.json"
CLIPS=$(python3 - "$PICKS" "$OPTIONS" <<'PY'
import json, sys, os
picks = json.load(open(sys.argv[1]))
defaults = json.load(open(sys.argv[2])) if os.path.exists(sys.argv[2]) else {}
items = []
for clip, pick in picks.items():
    opts = dict(defaults.get(clip, {}))          # cook_options.json first ...
    opts.update(pick if isinstance(pick, dict) else {"npz": pick})  # ... then the pick's own fields
    bvh = opts["npz"][:-4] + ".bvh"
    if not os.path.exists(bvh):
        sys.exit(f"missing {bvh}")
    item = f"{bvh}:{clip}"
    if opts.get("idle"):
        item += ":idle"
    if opts.get("loop"):
        item += ":loop"
    for key in ("start", "end"):
        if key in opts:
            item += f":{key}={opts[key]}"
    items.append(item)
print(",".join(items))
PY
)
cd "$(dirname "$0")/../.."
CLIPS="$CLIPS" OUT="$OUT" RENDER="${RENDER:-0}" /Applications/Blender.app/Contents/MacOS/Blender -b --python Tools/retarget_kimodo.py \
  2>&1 | grep -E "RETARGET|ground shift|root travel|foot z|EXPORT|Error|Traceback|DONE"
