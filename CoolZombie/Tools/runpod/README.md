# Generating gap clips on a RunPod GPU (Kimodo / ARDY)

Phase 1 of the AI-animation plan: generate the locomotion clips the 100STYLE Zombie set lacks
(a faster chase run, turns and pivots, start/stop transitions, hands planted on a wall) with
NVIDIA's Kimodo on a rented GPU, then retarget and cook them the way `Tools/retarget_100style.py`
does for the 100STYLE clips. ARDY (NVIDIA's streaming model) is installed alongside for
experiments but Kimodo is the Phase 1 tool: offline, constraint-driven, 30 fps SOMA BVH out.

Files in this folder are copied to the pod as `/workspace/tools/`:

| file | runs on | what |
| --- | --- | --- |
| `setup_pod.sh` | pod | idempotent environment: pinned Kimodo + ARDY checkouts, one `uv` venv each (they pin different `transformers`), torch 2.8 cu128 wheels (Blackwell), checkpoints into `/workspace/hf` |
| `start_text_encoder.sh` | pod | shared LLM2Vec text-encoder service on :9550 (`--wait` polls) |
| `smoke_test.sh` | pod | one 3 s walk with BVH export |
| `clips.json` | pod | the gap-clip spec: prompts + root-path primitives per clip |
| `gen_clips.py` | pod (kimodo venv) | turns a spec into Kimodo constraint files, runs `kimodo_gen`, writes `manifest.json` (`--spec`, `--only`, `--hold-only`) |
| `clips_core.json` | pod | the locomotion core in the same style: idle, hold idles, shamble-to-jog ladder, backward/side walks, 45° arcs, standing pivots |
| `triage_clips.py` | Mac | scores every take (speed, path error, turn, foot skate, hand reach) and writes default picks; `--prefer p0` keeps one prompt family |
| `cook_options.json` | Mac | per-clip cook options (static root and closed loop seam for the idles, trims for starts/stops/pivots) merged in by `retarget_batch.sh` |
| `retarget_batch.sh` | Mac | picks.json (+ cook options) -> one Blender run of `Tools/retarget_kimodo.py` |
| `harness/` | engine worktree | the headless chase harness and its result tables (see its README) |
| `engine_patches/` | — | diff of the engine branch the demo currently builds against (`feature/mm_oneshot_clips`: one-shot clips in motion matching) |

## Licensing

- Kimodo and ARDY code: Apache-2.0. Weights (`nvidia/Kimodo-SOMA-RP-v1.1`, `nvidia/ARDY-Core-*`):
  NVIDIA Open Model License, commercial use allowed with the attribution "Licensed by NVIDIA
  Corporation under the NVIDIA Open Model License"; NVIDIA claims no rights on the outputs.
- Text encoder: LLM2Vec adapters (MIT) on `meta-llama/Meta-Llama-3-8B-Instruct` (Llama 3
  Community License, gated on Hugging Face: request access with the studio account, then
  `hf auth login` on the pod). It only embeds the prompt; nothing of it ends up in a clip.
- Never feed MoCap Online or Mixamo data into any model (their licenses forbid ML use).
  100STYLE (CC BY 4.0) stays the style reference for the prompts.

## Pod recipe

| | |
| --- | --- |
| GPU | NVIDIA RTX PRO 6000 Blackwell Server Edition, 96 GB (RT cores, so the same box serves Isaac Sim later) |
| Cloud / data center | Secure Cloud, `EU-RO-1` (fallback `EUR-IS-1`): both stock the card and offer STANDARD network volumes |
| Image | `runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404` (its sshd honours `PUBLIC_KEY`; venvs bring their own Python/torch) |
| Disks | container 40 GB; `/workspace` 60 GB pod volume, or a network volume (see below) |
| Ports | `22/tcp` SSH, `7860/http` kimodo_demo, `2333/http` + `2334/http` ARDY demo/viewer |
| Env | `HF_HOME=/workspace/hf` `UV_CACHE_DIR=/workspace/.cache/uv` `UV_PYTHON_INSTALL_DIR=/workspace/.cache/uv-python` |
| Price (2026-09-08) | $2.09/h secure, $1.69/h community while running; stopped = storage only |

Two ways to create it:

- **Runpod MCP `create-pod`** (what the Claude session uses): the fields above plus
  `sshPublicKey` = contents of `~/.ssh/id_ed25519.pub`. The MCP tool cannot attach a network
  volume (REST v2 `mounts.network.volumeId` is not exposed), so `/workspace` is a pod volume:
  it survives stop/start but dies with the pod, and a stopped pod can only restart on the same
  host, which may have no free GPU. Everything is rebuilt by `setup_pod.sh` in ~20 min, and
  outputs are synced to the Mac as they are produced, so that is acceptable for Phase 1.
- **runpodctl with a network volume** (once `runpodctl doctor` has stored the API key; the
  volume can then follow us to a fresh pod in the same data center):

  ```bash
  runpodctl network-volume create --name untold-anim --size 100 --data-center-id EU-RO-1
  runpodctl pod create --name untold-anim \
    --image runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404 \
    --gpu-id "NVIDIA RTX PRO 6000 Blackwell Server Edition" --cloud-type SECURE \
    --data-center-ids EU-RO-1 --network-volume-id <vol-id> --volume-mount-path /workspace \
    --container-disk-in-gb 40 --ports "22/tcp,7860/http,2333/http,2334/http" \
    --env '{"HF_HOME":"/workspace/hf","UV_CACHE_DIR":"/workspace/.cache/uv","UV_PYTHON_INSTALL_DIR":"/workspace/.cache/uv-python"}' \
    --ssh --stop-after <iso8601>
  ```

  Check flag names against `runpodctl pod create --help`; the CLI moves fast.

## Connect

Read the pod's public IP and the external port mapped to `22/tcp` (`get-pod` in MCP,
`runpodctl ssh info <id>` in the CLI). The port changes on every stop/start.

```bash
ssh -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p <port> root@<ip>
```

## Set up (after every start: `/root`, apt and the container disk are wiped on stop)

`/workspace` is a network file system on these hosts, so `rsync -a` fails on the ownership step
(exit 23); the flags below skip it. Environment build took 11 min on 2026-09-08.

```bash
rsync -rlptz --no-owner --no-group -e "ssh -p <port> -i ~/.ssh/id_ed25519" Tools/runpod/ root@<ip>:/workspace/tools/
ssh ... 'bash /workspace/tools/setup_pod.sh'
# once, by hand, with a token that has access to meta-llama/Meta-Llama-3-8B-Instruct:
ssh ... 'source /workspace/env.sh && hf auth login'
ssh ... 'bash /workspace/tools/setup_pod.sh'                 # now also fetches the gated weights (~16 GB)
ssh ... 'bash /workspace/tools/start_text_encoder.sh'        # ~16 GB VRAM, detached
ssh ... 'bash /workspace/tools/start_text_encoder.sh --wait'
ssh ... 'bash /workspace/tools/smoke_test.sh'
```

Smaller cards: `TEXT_ENCODER_DEVICE=cpu` keeps generation under 3 GB of VRAM.

## Generate the gap clips

`clips.json` lists every clip with its prompts and a root path made of primitives
(`straight`, `ramp`, `arc`, `pivot`, `stop`). Paths are in Kimodo's canonical frame: metres,
Y-up, the character starts at the origin facing +Z and +X is its left, so `angle_deg > 0`
turns left. Keep prompts to one sentence (Kimodo splits prompts on periods) and start them
with a subject, as its training prompts do. Each clip yields `len(prompts) x samples`
candidates; pick per clip after viewing.

```bash
ssh ... 'source /workspace/env.sh && $KIMODO_PY /workspace/tools/gen_clips.py --list'
ssh ... 'source /workspace/env.sh && $KIMODO_PY /workspace/tools/gen_clips.py --out /workspace/out/kimodo'
ssh ... 'source /workspace/env.sh && $KIMODO_PY /workspace/tools/gen_clips.py --spec /workspace/tools/clips_core.json --out /workspace/out/kimodo'
rsync -rlptz -e "ssh -p <port> -i ~/.ssh/id_ed25519" root@<ip>:/workspace/out/ ~/Downloads/kimodo_out/
```

Outputs per clip: `constraints.json`, `p<i>/<clip>_p<i>/<clip>_p<i>_NN.{npz,bvh}` and
`manifest.json` at the top (prompt, seed, timing, files, license line). The hands-on-wall
clip adds a `hold/` pass, see `gen_clips.py`.

Viewing on the pod: `kimodo_demo` on port 7860 loads an NPZ ("Load/Save > Motion") and its
constraints; `kimodo_convert` converts NPZ <-> BVH offline.

## Retarget + cook

`Tools/retarget_kimodo.py` reuses the world-space delta retarget of
`retarget_100style.py` with the SOMA map: `Hips->pelvis`, `Spine1->spine_01`,
`Spine2->spine_02`, `Chest->spine_03`, `Neck1->neck_01`, `Head->head`,
`{Left,Right}Shoulder->clavicle`, `Arm->upperarm`, `ForeArm->lowerarm`, `Hand->hand`,
`{Left,Right}Leg->thigh`, `Shin->calf`, `Foot->foot`, `ToeBase->ball`. The BVH has a `Root`
wrapper joint above `Hips`, centimetres, Y-up, +Z forward, 30 fps, and (with
`--bvh_standard_tpose`) a T-pose rest, so the Blender import settings of the 100STYLE tool
apply (`axis_forward="-Z"`, `axis_up="Y"`, `global_scale=0.01`). Validated headless on a static
30-frame copy of Kimodo's `somaskel77_standard_tpose.bvh` (import, alignment, grounding and a
67-channel export all pass; `RENDER=1` check frames show the mannequin in the T-pose).

```bash
CLIPS="~/Downloads/kimodo_out/k_run_fast/p0/k_run_fast_p0/k_run_fast_p0_00.bvh:k_run_fast,\
~/Downloads/kimodo_out/k_stop_walk/p0/k_stop_walk_p0/k_stop_walk_p0_00.bvh:k_stop_walk" \
OUT=/tmp/kimodo RENDER=1 /Applications/Blender.app/Contents/MacOS/Blender -b --python Tools/retarget_kimodo.py
```

Append `:idle` to a clip that should keep a static root, `:loop` to close its loop seam (half
the last-to-first pose mismatch eased out over each end — for clips that play on repeat outside
motion matching: the idles, the wall hold), `:start=<s>` / `:end=<s>` to trim it (seconds;
`end` at or below zero counts from the clip's end). In `picks.json` a value may be an object
instead of a path: `{"npz": "...", "start": 0.7}` or `{"npz": "...", "loop": true}`.
The shipped start clips are trimmed to a 0.3 s standing lead and the stop clips to a 0.5 s
standing tail: a longer still segment that leads into travel is a frame motion matching keeps
re-selecting for a zero goal, and the held zombie twitches (found with the headless chase
harness, 2026-09-08). Cooked clips go to
`Sources/CoolZombieKit/Resources/Animations/<clip>/<clip>.untold` and into `ZombieResources`
as a `kimodo` clip set.

## When the pod loses its GPU (2026-09-09)

A stopped pod can find its card taken; the console then offers to migrate. The migration
brought `/workspace/.cache` (the uv cache) and `/workspace/repos` but NOT `/workspace/hf` (the
weights and the login) nor `/workspace/out` — sync outputs to the Mac after every batch, as the
plan says, and expect to log in again. The data-center IP is shared, so anonymous Hugging Face
downloads answer 429 and `hf auth whoami` (rate-limited "intentionally strictly") fails right
after a login: `setup_pod.sh` now reads the stored token file instead of asking whoami, and
`start_text_encoder.sh` runs with `HF_HUB_OFFLINE=1` once everything is cached. The MCP plugin's
`start-pod` was also unknown to its server that day; the console's Start works. Verify a new
pod's host key against `stream-pod-logs` (ED25519 line) before the first `ssh`.

## Stop when idle

`stop-pod` (MCP) or `runpodctl pod stop <id>`: GPU billing stops, `/workspace` persists.
Delete the pod (and any network volume) when Phase 1 is done.
