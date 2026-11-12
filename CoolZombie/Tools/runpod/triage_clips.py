#!/usr/bin/env python3
"""Score the Kimodo samples of a gen_clips.py run so the best take per clip can be picked.

    python3 Tools/runpod/triage_clips.py ~/Downloads/kimodo_out/kimodo [--clip k_run_fast] [--json picks.json]

Per sample (from its NPZ, Kimodo frame: metres, Y-up, +Z forward, +X left, 30 fps):
  speed      mean horizontal root speed over the clip (m/s)
  end_err    distance between the requested path end (constraints.json) and the actual root end (m)
  path_err   mean distance between requested and actual root position over the constrained frames (m)
  turn       heading change first->last frame (deg, +left)
  skate      mean horizontal speed of the lowest foot joint while it is within 2 cm of its
             lowest height (m/s; 0 = planted, >0.3 = visible sliding)
  hands_z    mean forward reach of the hands relative to the root over the last second (m), for the wall clip
A `--json` file records the default pick per clip (lowest path_err + skate) as "<clip>": "<npz path>",
which retarget_batch.sh reads; edit it by hand after viewing.
"""
import argparse
import glob
import json
import math
import os
import sys

import numpy as np

FPS = 30
HAND_IDX = None


def joint_indices(bvh_path):
    """Joint order of the exported SOMA-77 BVH (same order as the NPZ arrays)."""
    names = []
    for line in open(bvh_path):
        t = line.split()
        if t and t[0] in ("ROOT", "JOINT") and t[1] != "Root":
            names.append(t[1])
    return names


def score(npz_path, constraint):
    d = np.load(npz_path)
    root = d["root_positions"]
    pj = d["posed_joints"]
    T = len(root)
    dur = T / FPS
    horiz = root[:, [0, 2]]
    speed = np.linalg.norm(horiz[-1] - horiz[0]) / dur
    h = d["global_root_heading"]
    a0, a1 = math.atan2(h[0][1], h[0][0]), math.atan2(h[-1][1], h[-1][0])
    turn = math.degrees((a1 - a0 + math.pi) % (2 * math.pi) - math.pi)
    end_err = path_err = float("nan")
    if constraint is not None:
        idx = np.array(constraint["frame_indices"])
        req = np.array(constraint["smooth_root_2d"])
        keep = idx < T
        act = d["smooth_root_pos"][idx[keep]][:, [0, 2]]
        err = np.linalg.norm(act - req[keep], axis=1)
        path_err, end_err = float(err.mean()), float(err[-1])
    names = score.names
    feet = [names.index(n) for n in ("LeftFoot", "RightFoot", "LeftToeBase", "RightToeBase") if n in names]
    fy = pj[:, feet, 1]
    fxz = pj[:, feet][:, :, [0, 2]]
    vel = np.linalg.norm(np.diff(fxz, axis=0), axis=2) * FPS  # [T-1, F]
    low = fy[1:] < (fy.min(axis=0) + 0.02)
    skate = float(vel[low].mean()) if low.any() else float("nan")
    hands = [names.index(n) for n in ("LeftHand", "RightHand")]
    last = slice(max(0, T - FPS), T)
    hands_z = float((pj[last][:, hands, 2].mean(axis=1) - root[last, 2]).mean())
    # Hand motion: mean speed of both hands relative to the root (m/s), for the arm-posture takes —
    # the pose layer only borrows the arms, so a take whose hands keep moving beats a still one.
    rel = pj[:, hands, :] - root[:, None, :]
    hands_v = float(np.linalg.norm(np.diff(rel, axis=0), axis=2).mean() * FPS)
    return dict(frames=T, speed=speed, end_err=end_err, path_err=path_err, turn=turn, skate=skate, hands_z=hands_z, hands_v=hands_v)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("out_dir")
    ap.add_argument("--clip", help="only this clip")
    ap.add_argument("--json", help="write default picks here")
    ap.add_argument("--prefer", help="prompt key (p0, p1) whose samples win the default pick when available, for a consistent style")
    args = ap.parse_args()
    manifest = json.load(open(os.path.join(args.out_dir, "manifest.json")))
    picks = {}
    for clip, entry in manifest.items():
        if clip.startswith("_") or (args.clip and clip != args.clip):
            continue
        cpath = os.path.join(args.out_dir, clip, "constraints.json")
        cons = json.load(open(cpath))[0] if os.path.exists(cpath) else None
        samples = []
        for pk, pv in entry.get("prompts", {}).items():
            for f in pv["files"]:
                npz = os.path.join(args.out_dir, os.path.relpath(f["npz"], start=os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(f["npz"]))))))
                if not os.path.exists(npz):
                    npz = f["npz"]
                if not os.path.exists(npz):
                    continue
                samples.append((pk, npz))
        if "hold" in entry:
            for f in entry["hold"]["files"]:
                npz = f["npz"] if os.path.exists(f["npz"]) else os.path.join(args.out_dir, clip, "hold", os.path.basename(os.path.dirname(f["npz"])), os.path.basename(f["npz"]))
                if os.path.exists(npz):
                    samples.append(("hold", npz))
        if not samples:
            continue
        bvh = samples[0][1][:-4] + ".bvh"
        score.names = joint_indices(bvh) if os.path.exists(bvh) else joint_indices(glob.glob(os.path.join(args.out_dir, "**", "*.bvh"), recursive=True)[0])
        print(f"\n{clip}  ({entry.get('note','')}) requested {entry['duration']:.2f}s")
        print(f"  {'sample':<14}{'frames':>7}{'speed':>7}{'end_err':>9}{'path_err':>10}{'turn':>7}{'skate':>7}{'hands_z':>9}{'hands_v':>9}")
        best = None
        for pk, npz in samples:
            s = score(npz, cons)
            tag = f"{pk}/{os.path.basename(npz)[-6:-4]}"
            print(f"  {tag:<14}{s['frames']:>7}{s['speed']:>7.2f}{s['end_err']:>9.2f}{s['path_err']:>10.2f}{s['turn']:>7.0f}{s['skate']:>7.2f}{s['hands_z']:>9.2f}{s['hands_v']:>9.2f}")
            key = (0 if math.isnan(s["path_err"]) else s["path_err"]) + s["skate"]
            if args.prefer and pk != args.prefer and pk != "hold":
                key += 10  # other prompt families only win when the preferred one has no sample
            if best is None or key < best[0]:
                best = (key, npz)
        picks[clip] = best[1]
    if args.json:
        json.dump(picks, open(args.json, "w"), indent=1)
        print(f"\ndefault picks -> {args.json}")


if __name__ == "__main__":
    main()
