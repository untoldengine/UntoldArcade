"""Retarget Kimodo SOMA-77 BVH clips (Y-up, +Z forward, cm, 30 fps, exported with
--bvh_standard_tpose so the rest pose is a T-pose) onto the SNP UE4 mannequin armature in
zombie.blend and cook them with the untold exporter.

Same world-space delta retarget as Tools/retarget_100style.py (see there for the maths):
  M_b(f) = S_w(f) * S_0^-1 * R_align * T_0
Hip travel and a smoothed heading go into the `root` bone; the pelvis keeps height and sway.
Only the source skeleton map, the frame selection (whole clip at the file's rate) and the clip
list differ from the 100STYLE tool.

Env: CLIPS="<bvh path>:<clip name>[:idle][:loop][:start=<s>][:end=<s>],..."
       idle = static root + mean heading; start/end trim the clip in seconds (end <= 0 counts
       from the clip's end, so end=-1 drops the last second) — used to cut the standing head
       of a start clip and the standing tail of a stop clip, which otherwise give motion
       matching still frames that lead into travel and make a held zombie twitch.
       loop = close the loop seam: the pose mismatch between the last frame and the first is
       split in half and eased out over the last and first 0.5 s, so a clip that plays on
       repeat (the hold idles, the wall hold) never hard-cuts at the wrap. Generated takes are
       not cyclic, and a 5-10 cm finger or hand jump every loop reads as a twitch.
     OUT dir, FPS (default 30), RENDER=1 to write check frames, BLEND (rig .blend).
Run headless:
  CLIPS=~/Downloads/kimodo_out/k_run_fast/p0/k_run_fast_p0/k_run_fast_p0_00.bvh:k_run_fast \
  OUT=/tmp/kimodo /Applications/Blender.app/Contents/MacOS/Blender -b --python Tools/retarget_kimodo.py
Requires the Untold Engine Blender add-on (untold_exporter) installed.

Clips come from NVIDIA Kimodo (nvidia/Kimodo-SOMA-RP-v1.1); weights are licensed by NVIDIA
Corporation under the NVIDIA Open Model License. See Tools/runpod/README.md.
"""
import bpy, os, sys, math, re
from mathutils import Matrix, Vector, Quaternion

BLEND = os.environ.get("BLEND", os.path.expanduser("~/Projects/Untold/zombie.blend"))  # the ZombieAA rig + mesh
OUT = os.environ["OUT"]
FPS = int(os.environ.get("FPS", "30"))
RENDER = os.environ.get("RENDER") == "1"
CLIPS = []
for item in os.environ["CLIPS"].split(","):
    parts = item.split(":")
    if len(parts) < 2:
        raise SystemExit(f"CLIPS entry {item!r} must be <bvh path>:<clip name>[:idle][:loop][:start=<s>][:end=<s>]")
    opts = {"idle": False, "loop": False, "start": 0.0, "end": 0.0}
    for tok in parts[2:]:
        if tok == "idle":
            opts["idle"] = True
        elif tok == "loop":
            opts["loop"] = True
        elif tok.startswith("start=") or tok.startswith("end="):
            key, val = tok.split("=", 1)
            opts[key] = float(val)
        else:
            raise SystemExit(f"unknown clip option {tok!r} in {item!r}")
    CLIPS.append((os.path.expanduser(parts[0]), parts[1], opts))

# SOMA-77 joint -> (target bone, source child used for the bone direction, target child)
MAP = {
    # The pelvis direction aims at the second spine joint: a rig whose first spine
    # joint sits level with the hips (the studio's zombie) would otherwise align a
    # horizontal 5 cm stub with the source's upright hips and pitch the pelvis over.
    "Hips": ("pelvis", "Spine1", "spine_02"),
    "Spine1": ("spine_01", "Spine2", "spine_02"),
    "Spine2": ("spine_02", "Chest", "spine_03"),
    "Chest": ("spine_03", "Neck1", "neck_01"),
    "Neck1": ("neck_01", "Head", "head"),  # SOMA has Neck1+Neck2; the mannequin one neck bone spans both
    "Head": ("head", None, None),
    "RightShoulder": ("clavicle_r", "RightArm", "upperarm_r"),
    "RightArm": ("upperarm_r", "RightForeArm", "lowerarm_r"),
    "RightForeArm": ("lowerarm_r", "RightHand", "hand_r"),
    "RightHand": ("hand_r", None, "middle_01_r"),
    "LeftShoulder": ("clavicle_l", "LeftArm", "upperarm_l"),
    "LeftArm": ("upperarm_l", "LeftForeArm", "lowerarm_l"),
    "LeftForeArm": ("lowerarm_l", "LeftHand", "hand_l"),
    "LeftHand": ("hand_l", None, "middle_01_l"),
    "RightLeg": ("thigh_r", "RightShin", "calf_r"),
    "RightShin": ("calf_r", "RightFoot", "foot_r"),
    "RightFoot": ("foot_r", "RightToeBase", "ball_r"),
    "RightToeBase": ("ball_r", None, None),
    "LeftLeg": ("thigh_l", "LeftShin", "calf_l"),
    "LeftShin": ("calf_l", "LeftFoot", "foot_l"),
    "LeftFoot": ("foot_l", "LeftToeBase", "ball_l"),
    "LeftToeBase": ("ball_l", None, None),
}
# Target bone parent order for the analytic local solve.
ORDER = ["pelvis", "spine_01", "spine_02", "spine_03", "neck_01", "head",
         "clavicle_r", "upperarm_r", "lowerarm_r", "hand_r",
         "clavicle_l", "upperarm_l", "lowerarm_l", "hand_l",
         "thigh_r", "calf_r", "foot_r", "ball_r",
         "thigh_l", "calf_l", "foot_l", "ball_l"]
TGT_TO_SRC = {v[0]: k for k, v in MAP.items()}


def bvh_frame_info(path):
    """(frame count, fps) from the MOTION header."""
    text = open(path).read()
    n = int(re.search(r"^Frames:\s*(\d+)", text, re.M).group(1))
    ft = float(re.search(r"^Frame Time:\s*([0-9.eE+-]+)", text, re.M).group(1))
    return n, round(1.0 / ft)


# Arms: the elbow stays in its anatomical plane. The Xsens zombie idle holds
# both elbows 1.6 cm INSIDE the shoulder-to-wrist line (a locked, slightly
# hyperextended hang), and a faithful transfer shows a broken elbow at arm's
# length on a headset (2026-10-27). An elbow more than 60 degrees away from its
# natural pole -- back and outward for a hanging arm, down and outward for a
# raised one -- is turned about the shoulder-to-hand axis onto the pole: the
# upper arm rotates about that axis, the forearm is re-aimed from the new elbow
# to the same hand, and the hand keeps its position and orientation. A bend
# that already lies within 60 degrees of the pole is left to the clip.
def plane_the_elbows(M, yaw, sides=(("l", 1.0), ("r", -1.0)), min_offset=0.002, max_angle=math.radians(60)):
    fwd = Vector((math.sin(yaw), -math.cos(yaw), 0.0))
    up = Vector((0.0, 0.0, 1.0))
    left = up.cross(fwd).normalized()
    changed = 0
    for side, sign in sides:
        upper, lower, hand = f"upperarm_{side}", f"lowerarm_{side}", f"hand_{side}"
        if upper not in M or lower not in M or hand not in M:
            continue
        S, E, H = M[upper].translation.copy(), M[lower].translation.copy(), M[hand].translation.copy()
        axis = H - S
        if axis.length < 1e-4:
            continue
        axis.normalize()
        offset = (E - S) - axis * (E - S).dot(axis)
        if offset.length < min_offset:
            continue
        pole = -fwd - 0.5 * up + 0.5 * sign * left
        pole = pole - axis * pole.dot(axis)
        if pole.length < 1e-4:
            continue
        pole.normalize()
        o = offset.normalized()
        angle = math.atan2(o.cross(pole).dot(axis), o.dot(pole))
        if abs(angle) <= max_angle:
            continue
        # Where the elbow goes: around the shoulder-to-hand axis onto the pole.
        new_elbow = S + Matrix.Rotation(angle, 3, axis) @ (E - S)
        # How the bones get there: each by the smallest rotation that takes its
        # old direction to its new one, a swing of a few degrees with no roll. A
        # turn of the upper arm about the shoulder-to-hand axis moved the elbow
        # the same way but, on a nearly straight arm, that axis is the bone's
        # own: the upper arm spun about itself and the sleeve wrapped like a
        # candy paper at the shoulder and the elbow (headset, 2026-10-27).
        swing = (E - S).normalized().rotation_difference((new_elbow - S).normalized()).to_matrix().to_4x4()
        upper_rot = swing @ M[upper].to_3x3().to_4x4()
        upper_rot.translation = S
        M[upper] = upper_rot
        realign = (H - E).normalized().rotation_difference((H - new_elbow).normalized()).to_matrix().to_4x4()
        lower_rot = realign @ M[lower].to_3x3().to_4x4()
        lower_rot.translation = new_elbow
        M[lower] = lower_rot
        changed += 1
    return changed


def world_rest_dir(arm, bone_name, child_name):
    """Unit direction of a bone in world space at rest (head -> child head, or head -> tail)."""
    b = arm.data.bones[bone_name]
    head = arm.matrix_world @ b.head_local
    if child_name and child_name in arm.data.bones:
        tail = arm.matrix_world @ arm.data.bones[child_name].head_local
    else:
        tail = arm.matrix_world @ b.tail_local
    return (tail - head).normalized()


def smooth_angles(angles, half_window):
    out = []
    n = len(angles)
    for i in range(n):
        sx = sy = 0.0
        for j in range(max(0, i - half_window), min(n, i + half_window + 1)):
            sx += math.cos(angles[j]); sy += math.sin(angles[j])
        out.append(math.atan2(sy, sx))
    return out


bpy.ops.wm.open_mainfile(filepath=BLEND)
tgt = next(o for o in bpy.data.objects if o.type == "ARMATURE")
mesh = next((o for o in bpy.data.objects if o.type == "MESH"), None)
tgt.animation_data_clear()
tgt.hide_set(False); tgt.hide_viewport = False  # the exporter skips hidden objects
try:
    bpy.ops.preferences.addon_enable(module="untold_exporter")
except Exception as e:
    print("addon enable:", e)

# Leg-length ratio scales hip positions so feet land on the ground.
tgt_leg = (tgt.data.bones["thigh_l"].length + tgt.data.bones["calf_l"].length)

for path, name, opts in CLIPS:
    is_idle = opts["idle"]
    n_frames, src_fps = bvh_frame_info(path)
    first = 1 + int(round(opts["start"] * src_fps))
    last = n_frames + int(round(opts["end"] * src_fps)) if opts["end"] <= 0 else int(round(opts["end"] * src_fps))
    last = max(first + 1, min(n_frames, last))
    before = set(bpy.data.objects)
    # Kimodo BVH: Y-up, +Z forward like the Xsens files, so the same axes; -Z keeps left/right
    # (axis_forward="Z" mirrors and faces +Y). Centimetres -> metres.
    bpy.ops.import_anim.bvh(filepath=path, axis_forward="-Z", axis_up="Y", global_scale=0.01,
                            rotate_mode="QUATERNION", update_scene_fps=False, update_scene_duration=False,
                            use_fps_scale=False, frame_start=1)
    src = next(o for o in set(bpy.data.objects) - before if o.type == "ARMATURE")
    missing = [s for s in MAP if s not in src.data.bones]
    if missing:
        raise SystemExit(f"{path}: not a SOMA-77 BVH, missing joints {missing}")
    src_leg = (src.data.bones["LeftLeg"].length + src.data.bones["LeftShin"].length)
    ratio = tgt_leg / src_leg

    # Rest data
    S0 = {}; R_align = {}; T0 = {}
    for sname, (tname, schild, tchild) in MAP.items():
        S0[sname] = (src.matrix_world @ src.data.bones[sname].matrix_local).to_3x3()
        T0[tname] = (tgt.matrix_world @ tgt.data.bones[tname].matrix_local).to_3x3()
        if schild is None:
            R_align[tname] = None  # leaf: inherit the parent's alignment (keeps the rig's own rest offset)
        else:
            ds = world_rest_dir(src, sname, schild)
            dt = world_rest_dir(tgt, tname, tchild)
            R_align[tname] = dt.rotation_difference(ds).to_matrix()
    for tname in ORDER:
        if R_align[tname] is None:
            p = tgt.data.bones[tname].parent.name
            R_align[tname] = R_align[p]
    rest_local = {b.name: b.matrix_local for b in tgt.data.bones}
    parent_of = {b.name: (b.parent.name if b.parent else None) for b in tgt.data.bones}

    action = bpy.data.actions.new(name)
    tgt.animation_data_create(); tgt.animation_data.action = action
    for pb in tgt.pose.bones:
        pb.rotation_mode = "QUATERNION"
        pb.rotation_quaternion = (1, 0, 0, 0); pb.location = (0, 0, 0); pb.scale = (1, 1, 1)

    step = max(1, round(src_fps / FPS))
    frames = list(range(first, last + 1, step))
    # Pass 1: read source world matrices per frame.
    sw = []; hips_pos = []; headings = []
    for f in frames:
        bpy.context.scene.frame_set(f)
        row = {s: (src.matrix_world @ src.pose.bones[s].matrix).to_3x3() for s in MAP}
        sw.append(row)
        hp = (src.matrix_world @ src.pose.bones["Hips"].matrix).to_translation() * ratio
        hips_pos.append(hp)
        fwd = (row["Hips"] @ S0["Hips"].inverted()) @ Vector((0, -1, 0))  # after import the source faces Blender -Y
        headings.append(math.atan2(fwd.x, -fwd.y))  # yaw about Z: Rz(yaw) maps rest forward (0,-1,0) onto fwd
    headings = smooth_angles(headings, half_window=int(0.4 * FPS))
    # Root travel is the low-passed hip path; the sway stays in the pelvis
    # (as authored root motion does), so a standing clip has a still root.
    def smooth_xy(points, half_window):
        # Moving average over a full window everywhere: the path is extended past both ends by
        # linear extrapolation (mean velocity of the first/last half window), so a short clip
        # keeps its true travel instead of losing half a window of motion at each end.
        n = len(points); w = half_window
        if n < 2 or w == 0:
            return [Vector((p.x, p.y, 0.0)) for p in points]
        k = min(w, n - 1)
        v0 = (points[0] - points[k]) / k
        v1 = (points[-1] - points[-1 - k]) / k
        padded = [points[0] + v0 * (w - i) for i in range(w)] + list(points) + [points[-1] + v1 * (i + 1) for i in range(w)]
        out = []
        for i in range(n):
            seg = padded[i:i + 2 * w + 1]
            out.append(Vector((sum(p.x for p in seg) / len(seg), sum(p.y for p in seg) / len(seg), 0.0)))
        return out
    root_xy = smooth_xy(hips_pos, half_window=int(0.5 * FPS))
    if is_idle:
        # An idle is in place: a static root (mean hip position, mean heading)
        # keeps the whole sway in the pelvis, so a still goal matches every
        # frame of it instead of only the least-drifted one.
        n = len(hips_pos)
        mean = Vector((sum(p.x for p in hips_pos) / n, sum(p.y for p in hips_pos) / n, 0.0))
        root_xy = [mean] * n
        mh = math.atan2(sum(math.sin(h) for h in headings), sum(math.cos(h) for h in headings))
        headings = [mh] * n

    # Pass 2: solve target bones analytically (armature space) for every frame.
    solved = []
    for i, f in enumerate(frames):
        M = {}
        for tname in ORDER:
            sname = TGT_TO_SRC[tname]
            rot = sw[i][sname] @ S0[sname].inverted() @ R_align[tname] @ T0[tname]
            m = rot.to_4x4()
            if tname == "pelvis":
                m.translation = hips_pos[i]
            else:
                # Keep the target's own bone lengths: place the head where the parent's chain puts it.
                p = parent_of[tname]
                offset = rest_local[p].inverted() @ rest_local[tname]
                m.translation = (M[p] @ offset).translation
            M[tname] = m
        solved.append(M)
    # Ground the clip: the lowest toe base over the clip sits at its rest height (~2 cm).
    ball_rest_z = tgt.data.bones["ball_l"].head_local.z
    zmin = min(min(M[b].translation.z for b in ("ball_l", "ball_r")) for M in solved)
    ground_shift = ball_rest_z - zmin
    print(f"  ground shift {ground_shift:+.3f} m (lowest toe base was at z={zmin:.3f})")

    # Pass 3: root/pelvis split into local keys (rotation, and location for root/pelvis).
    keys = []
    replaned = 0
    for i, M in enumerate(solved):
        for tname in ORDER:
            M[tname].translation = M[tname].translation + Vector((0, 0, ground_shift))
        yaw = headings[i]
        replaned += plane_the_elbows(M, yaw)
        root_rest = rest_local["root"]
        rp = root_xy[i]
        M["root"] = Matrix.Translation((rp.x, rp.y, 0.0)) @ Matrix.Rotation(yaw, 4, "Z") @ root_rest
        row = {}
        for tname in ["root"] + ORDER:
            p = parent_of[tname]
            if p is None:
                basis = rest_local[tname].inverted() @ M[tname]
            else:
                basis = (rest_local[p].inverted() @ rest_local[tname]).inverted() @ M[p].inverted() @ M[tname]
            row[tname] = (basis.to_quaternion(), basis.to_translation() if tname in ("root", "pelvis") else None)
        keys.append(row)

    if opts["loop"]:
        # Close the loop seam. The frame that would follow the last one is predicted at
        # constant velocity; its mismatch against the first frame (per bone, in the bone's
        # own frame) is the residual. Half of it eases in over the last window, the other
        # half eases out over the first, so the wrap is continuous to first order and no
        # single frame carries more than half the correction.
        K = min(int(0.5 * FPS), max(1, (len(keys) - 2) // 2))
        n = len(keys)
        def ease(t): return t * t * (3 - 2 * t)
        seam = 0.0
        for tname in keys[0]:
            q_prev, l_prev = keys[n - 2][tname]
            q_last, l_last = keys[n - 1][tname]
            q_first, l_first = keys[0][tname]
            step = q_prev.inverted() @ q_last
            q_pred = q_last @ step
            D = (q_pred.inverted() @ q_first).normalized()
            if D.w < 0: D.negate()
            seam = max(seam, abs(D.angle))
            Dl = (l_first - (l_last + (l_last - l_prev))) if l_last is not None else None
            for j in range(K):
                w_tail = 0.5 * ease((j + 1) / K)          # last frame carries half the residual
                w_head = 0.5 * ease(1 - j / K)            # first frame carries the other half
                for i, w, sign in ((n - K + j, w_tail, 1.0), (j, w_head, -1.0)):
                    q, l = keys[i][tname]
                    adj = Quaternion((1, 0, 0, 0)).slerp(D, w)
                    if sign < 0: adj.invert()
                    keys[i][tname] = (q @ adj, (l + Dl * (sign * w)) if l is not None else None)
        print(f"  loop seam closed: largest residual {math.degrees(seam):.1f} deg per bone, blended over {K} frames each side")

    out_frame = 1
    for row in keys:
        for tname, (q, l) in row.items():
            pb = tgt.pose.bones[tname]
            pb.rotation_quaternion = q
            if l is not None:
                pb.location = l
                pb.keyframe_insert("location", frame=out_frame)
            pb.keyframe_insert("rotation_quaternion", frame=out_frame)
        out_frame += 1
    bpy.context.scene.frame_start = 1; bpy.context.scene.frame_end = out_frame - 1
    bpy.context.scene.render.fps = FPS
    print(f"RETARGET {os.path.basename(path)} -> {name}: frames {first}-{last} of {n_frames} @{src_fps} -> {out_frame-1} frames @{FPS}, "
          f"leg ratio {ratio:.3f}{' (idle: static root)' if is_idle else ''}{' (loop closed)' if opts['loop'] else ''}")
    print(f"  elbows re-planed on {replaned} arm-frames")

    # Diagnostics: foot heights and travel.
    zs = []
    for fi in (1, (out_frame - 1) // 2, out_frame - 1):
        bpy.context.scene.frame_set(fi)
        for b in ("foot_l", "foot_r", "ball_l", "ball_r"):
            zs.append((tgt.matrix_world @ tgt.pose.bones[b].matrix).to_translation().z)
        r = (tgt.matrix_world @ tgt.pose.bones["root"].matrix).to_translation()
        h = (tgt.matrix_world @ tgt.pose.bones["hand_l"].matrix).to_translation()
        print(f"  frame {fi}: root=({r.x:.2f},{r.y:.2f}) hand_l=({h.x:.2f},{h.y:.2f},{h.z:.2f})")
    print(f"  foot z range over sampled frames: {min(zs):.3f} .. {max(zs):.3f}")
    travel = (root_xy[-1] - root_xy[0]).length
    print(f"  root travel {travel:.2f} m over {(out_frame-1)/FPS:.2f} s = {travel/((out_frame-1)/FPS):.2f} m/s, "
          f"heading {math.degrees(headings[0]):+.0f} -> {math.degrees(headings[-1]):+.0f} deg")

    if RENDER and mesh is not None:
        scn = bpy.context.scene
        scn.render.engine = "BLENDER_WORKBENCH"; scn.render.resolution_x = 900; scn.render.resolution_y = 900
        scn.render.resolution_percentage = 100
        scn.display.shading.light = "STUDIO"; scn.display.shading.show_shadows = True
        cam = bpy.data.objects.get("RetargetCam")
        if cam is None:
            cd = bpy.data.cameras.new("RetargetCam"); cam = bpy.data.objects.new("RetargetCam", cd); scn.collection.objects.link(cam)
        cam.data.lens = 40
        scn.camera = cam
        src.hide_render = True
        # Source stick figure: one small sphere per joint, offset to the character's left, so source and target pose can be compared.
        spheres = {}
        for sname in MAP:
            bpy.ops.mesh.primitive_ico_sphere_add(radius=0.035, subdivisions=1)
            sp = bpy.context.active_object; sp.name = f"src_{sname}"; spheres[sname] = sp
        for fi in (1, (out_frame - 1) // 3, 2 * (out_frame - 1) // 3):
            fi = max(1, fi)
            bpy.context.scene.frame_set(fi)
            r = (tgt.matrix_world @ tgt.pose.bones["pelvis"].matrix).to_translation()
            # Camera in the character's own frame: front three-quarter view from where it faces.
            yaw = headings[fi - 1]
            face = Vector((math.sin(yaw), -math.cos(yaw), 0))
            left = Vector((-face.y, face.x, 0))
            cam.location = Vector((r.x, r.y, 0.95)) + face * 3.4 + left * 1.6
            look = Vector((r.x, r.y, 0.95)) - cam.location
            cam.rotation_euler = look.to_track_quat("-Z", "Y").to_euler()
            sf = frames[fi - 1]
            bpy.context.scene.frame_set(sf)  # source is keyed on its own frame numbers
            hp = (src.matrix_world @ src.pose.bones["Hips"].matrix).to_translation() * ratio
            for sname, sp in spheres.items():
                wp = (src.matrix_world @ src.pose.bones[sname].matrix).to_translation() * ratio
                sp.location = wp - Vector((hp.x, hp.y, 0)) + Vector((r.x, r.y, ground_shift)) + left * 1.2
            bpy.context.scene.frame_set(fi)
            scn.render.filepath = os.path.join(OUT, f"{name}_f{fi}.png")
            bpy.ops.render.render(write_still=True)
            # Side view too (from the character's left).
            cam.location = Vector((r.x, r.y, 0.95)) + left * 4.0 + face * 0.6
            look = Vector((r.x, r.y, 0.95)) + left * 0.6 - cam.location
            cam.rotation_euler = look.to_track_quat("-Z", "Y").to_euler()
            scn.render.filepath = os.path.join(OUT, f"{name}_f{fi}_side.png")
            bpy.ops.render.render(write_still=True)
        for sp in spheres.values(): bpy.data.objects.remove(sp, do_unlink=True)
        src.hide_render = False

    # Export with the untold exporter (selected armature, current action).
    for o in bpy.data.objects: o.select_set(False)
    tgt.select_set(True); bpy.context.view_layer.objects.active = tgt
    os.makedirs(OUT, exist_ok=True)
    res = bpy.ops.untold.export_animation(filepath=os.path.join(OUT, name + ".untold"), scope="SELECTED",
                                          action_mode="CURRENT", convert_orientation=True, source_orientation="blender-native")
    print(f"EXPORT {name} {res}")

    # Clean up the source for the next clip.
    for o in set(bpy.data.objects) - before:
        bpy.data.objects.remove(o, do_unlink=True)
    tgt.animation_data.action = None
print("DONE")
