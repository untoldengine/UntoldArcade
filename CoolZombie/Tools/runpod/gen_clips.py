#!/usr/bin/env python3
"""Generate the CoolZombie gap clips with NVIDIA Kimodo from clips.json.

Runs on the pod inside the kimodo venv:
    source /workspace/env.sh
    $KIMODO_PY /workspace/tools/gen_clips.py --out /workspace/out/kimodo [--only k_run_fast,k_pivot_l_90]
                                             [--samples 1] [--steps 50] [--dry-run] [--list]

Each clip's path steps become a dense Kimodo `root2d` constraint (one entry per frame, metres,
Y-up, start at the origin facing +Z, +X = the character's left; optional heading as [cos, sin]
of the angle from +Z toward +X, which is Kimodo's convention). `kimodo_gen` runs once per
prompt with --num_samples variations and writes NPZ + BVH (standard T-pose rest pose) under
<out>/<clip>/p<i>/. <out>/manifest.json indexes everything for the retarget step.

A clip with an "ee_hold" block gets a second pass: the chosen sample's frame with the hands
furthest forward (inside "window") is held for hold_seconds with an end-effector constraint
(the pose's own hand positions), giving a planted-hands segment for the hands-on-wall clip.
"""
import argparse
import glob
import json
import math
import os
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent


def build_path(steps, fps):
    """Integrate the path primitives into per-frame (x, z, theta); theta grows when turning left."""
    x = z = th = 0.0
    pts = [(x, z, th)]
    for st in steps:
        kind = st["type"]
        if kind == "stop":
            pts += [(x, z, th)] * max(1, round(st["duration"] * fps))
        elif kind in ("straight", "ramp"):
            # Travel relative to the heading: direction_deg 0 = forward, 180 = backward,
            # +90 = strafe left (the heading itself does not change).
            n = max(1, round(st["duration"] * fps))
            v0 = st["speed"] if kind == "straight" else st["from"]
            v1 = st["speed"] if kind == "straight" else st["to"]
            move = th + math.radians(st.get("direction_deg", 0))
            for i in range(n):
                v = v0 + (v1 - v0) * (i + 0.5) / n
                x += math.sin(move) * v / fps
                z += math.cos(move) * v / fps
                pts.append((x, z, th))
        elif kind == "arc":
            ang = math.radians(st["angle_deg"])
            r, v = st["radius"], st["speed"]
            n = max(1, round(abs(ang) * r / v * fps))
            for _ in range(n):
                th += ang / n
                x += math.sin(th) * v / fps
                z += math.cos(th) * v / fps
                pts.append((x, z, th))
        elif kind == "pivot":
            ang = math.radians(st["angle_deg"])
            n = max(1, round(st["duration"] * fps))
            for _ in range(n):
                th += ang / n
                pts.append((x, z, th))
        else:
            raise ValueError(f"unknown step type {kind!r}")
    return pts


def root_constraint(pts, heading):
    c = {
        "type": "root2d",
        "frame_indices": list(range(len(pts))),
        "smooth_root_2d": [[round(x, 4), round(z, 4)] for x, z, _ in pts],
    }
    if heading:
        c["global_root_heading"] = [[round(math.cos(t), 5), round(math.sin(t), 5)] for _, _, t in pts]
    return c


def kimodo_gen_cmd():
    exe = os.environ.get("KIMODO_GEN") or str(Path(sys.executable).parent / "kimodo_gen")
    if not Path(exe).exists():
        sys.exit(f"kimodo_gen not found at {exe}; run with the kimodo venv python or set KIMODO_GEN")
    return exe


def run_kimodo(exe, prompt, duration, seed, samples, constraints, stem, model, steps, cfg):
    cmd = [exe, prompt, "--model", model, "--duration", f"{duration:.4f}", "--num_samples", str(samples),
           "--seed", str(seed), "--diffusion_steps", str(steps), "--bvh", "--bvh_standard_tpose",
           "--output", str(stem), "--cfg_type", "separated", "--cfg_weight", str(cfg[0]), str(cfg[1])]
    if constraints:
        cmd += ["--constraints", str(constraints)]
    print("+", " ".join(f'"{a}"' if " " in a else a for a in cmd), flush=True)
    t0 = time.time()
    subprocess.run(cmd, check=True)
    return time.time() - t0


def outputs_for(stem):
    """kimodo_gen writes <stem>.npz for one sample or <stem>/<stem-name>_NN.npz for several."""
    stem = Path(stem)
    files = sorted(glob.glob(f"{stem}.npz")) + sorted(glob.glob(f"{stem}/{stem.name}_*.npz"))
    return [{"npz": f, "bvh": f[:-4] + ".bvh" if os.path.exists(f[:-4] + ".bvh") else None} for f in files]


def ee_hold_constraints(npz_path, spec, fps, base_root2d):
    import numpy as np
    from scipy.spatial.transform import Rotation as R
    from kimodo.skeleton.definitions import SOMASkeleton77

    d = np.load(npz_path)
    skel = SOMASkeleton77()
    names = list(getattr(skel, "bone_order_names", None) or getattr(skel, "joint_names"))
    lh, rh = names.index("LeftHand"), names.index("RightHand")
    pj = d["posed_joints"]
    hold = int(spec.get("hold_seconds", 2.5) * fps)
    w0, w1 = spec["window"]
    w1 = max(w0 + 1, min(w1, len(pj) - hold))  # the whole hold must fit after the chosen frame
    fwd = (pj[w0:w1, lh, 2] + pj[w0:w1, rh, 2]) / 2.0
    f = w0 + int(fwd.argmax())
    idx = list(range(f, min(f + hold, len(pj)), int(spec.get("step", 5))))[:19]
    aa = R.from_matrix(d["local_rot_mats"][f]).as_rotvec().tolist()
    root = [float(v) for v in d["root_positions"][f]]
    ee = {
        "type": "end-effector",
        "joint_names": spec.get("joints", ["LeftHand", "RightHand"]),  # base names Kimodo expands
        "frame_indices": idx,
        "local_joints_rot": [aa] * len(idx),
        "root_positions": [root] * len(idx),
        "smooth_root_2d": [[root[0], root[2]]] * len(idx),
    }
    n_full = len(base_root2d["frame_indices"])
    approach = {k: (v[:f] if isinstance(v, list) and len(v) == n_full else v) for k, v in base_root2d.items()}
    return [approach, ee], f, root


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--spec", default=str(HERE / "clips.json"))
    ap.add_argument("--out", default=os.path.join(os.environ.get("WS", "/workspace"), "out", "kimodo"))
    ap.add_argument("--only", help="comma-separated clip names")
    ap.add_argument("--samples", type=int, help="override variations per prompt")
    ap.add_argument("--steps", type=int, help="override diffusion steps")
    ap.add_argument("--model", help="override the Kimodo model")
    ap.add_argument("--dry-run", action="store_true", help="write constraints only")
    ap.add_argument("--hold-only", action="store_true", help="redo only the ee_hold pass, from the manifest's pass-1 files")
    ap.add_argument("--list", action="store_true")
    args = ap.parse_args()

    spec = json.load(open(args.spec))
    fps = spec.get("fps", 30)
    clips = spec["clips"]
    if args.only:
        wanted = set(args.only.split(","))
        clips = [c for c in clips if c["name"] in wanted]
        missing = wanted - {c["name"] for c in clips}
        if missing:
            sys.exit(f"unknown clips: {sorted(missing)}")
    if args.list:
        for c in clips:
            pts = build_path(c["path"], fps)
            print(f"{c['name']:<20} {len(pts)/fps:5.2f}s  {len(c['prompts'])} prompts  end=({pts[-1][0]:+.2f},{pts[-1][1]:+.2f}) "
                  f"heading={math.degrees(pts[-1][2]):+.0f}deg")
        return

    model = args.model or spec.get("model", "Kimodo-SOMA-RP-v1.1")
    samples = args.samples or spec.get("samples", 1)
    steps = args.steps or spec.get("diffusion_steps", 100)
    cfg = spec.get("cfg", [2.0, 2.0])
    base_seed = spec.get("seed", 0)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    exe = None if args.dry_run else kimodo_gen_cmd()
    manifest_path = out / "manifest.json"
    manifest = json.load(open(manifest_path)) if manifest_path.exists() else {}
    manifest.setdefault("_license", "Generated with NVIDIA Kimodo (nvidia/%s); weights licensed by NVIDIA "
                        "Corporation under the NVIDIA Open Model License." % model)

    for ci, clip in enumerate(clips):
        name = clip["name"]
        pts = build_path(clip["path"], fps)
        duration = len(pts) / fps
        if duration > 10.0:
            sys.exit(f"{name}: {duration:.2f}s exceeds Kimodo's 10 s per-prompt limit")
        heading = clip.get("heading", spec.get("heading", True))
        cdir = out / name
        cdir.mkdir(exist_ok=True)
        root2d = root_constraint(pts, heading)
        cpath = cdir / "constraints.json"
        json.dump([root2d], open(cpath, "w"))
        entry = manifest.setdefault(name, {})
        entry.update({"note": clip.get("note", ""), "duration": duration, "frames": len(pts),
                      "constraints": str(cpath), "path": clip["path"], "model": model})
        entry.setdefault("prompts", {})  # keep pass-1 files across --hold-only reruns
        print(f"\n### {name}: {duration:.2f}s, {len(pts)} frames, end=({pts[-1][0]:+.2f},{pts[-1][1]:+.2f}) "
              f"heading={math.degrees(pts[-1][2]):+.0f}deg")
        if args.dry_run:
            continue
        for pi, prompt in enumerate([] if args.hold_only else clip["prompts"]):
            prompt = prompt.replace(".", "").strip()  # one sentence: Kimodo splits prompts on periods
            seed = base_seed + 100 * ci + pi
            stem = cdir / f"p{pi}" / f"{name}_p{pi}"
            stem.parent.mkdir(exist_ok=True)
            secs = run_kimodo(exe, prompt, duration, seed, samples, cpath, stem, model, steps, cfg)
            files = outputs_for(stem)
            entry["prompts"][f"p{pi}"] = {"prompt": prompt, "seed": seed, "samples": samples,
                                          "seconds": round(secs, 1), "files": files}
            json.dump(manifest, open(manifest_path, "w"), indent=1)
            print(f"    p{pi}: {len(files)} sample(s) in {secs:.0f}s")
        hold = clip.get("ee_hold")
        if hold:
            pi, si = int(hold.get("prompt", 0)), int(hold.get("sample", 0))
            files = entry.get("prompts", {}).get(f"p{pi}", {}).get("files", [])
            if si >= len(files):
                print(f"    ee_hold: sample {si} missing, skipping")
                continue
            cons, f, root = ee_hold_constraints(files[si]["npz"], hold, fps, root2d)
            hpath = cdir / "constraints_hold.json"
            json.dump(cons, open(hpath, "w"))
            prompt = clip["prompts"][pi].replace(".", "").strip()
            stem = cdir / "hold" / f"{name}_hold"
            stem.parent.mkdir(exist_ok=True)
            secs = run_kimodo(exe, prompt, duration, base_seed + 100 * ci + 50, samples, hpath, stem, model, steps, cfg)
            entry["hold"] = {"prompt": prompt, "from_sample": files[si]["npz"], "hold_frame": f, "root": root,
                             "constraints": str(hpath), "seconds": round(secs, 1), "files": outputs_for(stem)}
            json.dump(manifest, open(manifest_path, "w"), indent=1)
            print(f"    hold pass from frame {f}: {len(entry['hold']['files'])} sample(s) in {secs:.0f}s")
    print(f"\nmanifest: {manifest_path}")


if __name__ == "__main__":
    main()
