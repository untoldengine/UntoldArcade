"""Retarget 100STYLE (Xsens, T-pose, Y-up, cm) BVH clips onto the SNP UE4
mannequin armature in zombie.blend and cook them with the untold exporter.

World-space delta retargeting with rest-pose alignment:
  M_b(f) = S_w(f) * S_0^-1 * R_align * T_0
where S_w/S_0 are the source bone's world rotation at frame f / at rest,
T_0 the target bone's world rest rotation and R_align the minimal rotation
taking the target rest bone direction onto the source rest bone direction
(this is what turns the mannequin's A-pose into the Xsens T-pose).
Hip travel and a smoothed heading go into the `root` bone; the pelvis keeps
height and sway relative to it.

Env: CLIPS="ID:s100_idle,FW:s100_walk" (100STYLE type:clip name), OUT dir,
FPS (default 30), RENDER=1 to write check frames, BLEND (rig .blend),
SRC_DIR (folder with the Zombie_*.bvh files and Frame_Cuts.csv).
Run headless: /Applications/Blender.app/Contents/MacOS/Blender -b --python Tools/retarget_100style.py
Requires the Untold Engine Blender add-on (untold_exporter) installed.

100STYLE: Mason, Starke, Komura 2022 — CC BY 4.0 (https://www.ianxmason.com/100style/).
"""
import bpy, csv, math, os, sys
from mathutils import Matrix, Vector, Quaternion

BLEND = os.environ.get("BLEND", os.path.expanduser("~/Projects/Untold/zombie.blend"))  # the ZombieAA rig + mesh
SRC_DIR = os.environ.get("SRC_DIR", os.path.expanduser("~/Downloads/100STYLE/Zombie"))  # Zombie_*.bvh + Frame_Cuts.csv
OUT = os.environ["OUT"]
FPS = int(os.environ.get("FPS", "30"))
RENDER = os.environ.get("RENDER") == "1"
CLIPS = [c.split(":") for c in os.environ.get("CLIPS", "ID:s100_idle").split(",")]

# source joint -> (target bone, source child used for the bone direction, target child)
MAP = {
    # The pelvis direction aims at the second spine joint (see retarget_kimodo.py).
    "Hips": ("pelvis", "Chest", "spine_02"),
    "Chest": ("spine_01", "Chest2", "spine_02"),
    "Chest2": ("spine_02", "Chest3", "spine_03"),
    "Chest4": ("spine_03", "Neck", "neck_01"),
    "Neck": ("neck_01", "Head", "head"),
    "Head": ("head", None, None),
    "RightCollar": ("clavicle_r", "RightShoulder", "upperarm_r"),
    "RightShoulder": ("upperarm_r", "RightElbow", "lowerarm_r"),
    "RightElbow": ("lowerarm_r", "RightWrist", "hand_r"),
    "RightWrist": ("hand_r", None, "middle_01_r"),
    "LeftCollar": ("clavicle_l", "LeftShoulder", "upperarm_l"),
    "LeftShoulder": ("upperarm_l", "LeftElbow", "lowerarm_l"),
    "LeftElbow": ("lowerarm_l", "LeftWrist", "hand_l"),
    "LeftWrist": ("hand_l", None, "middle_01_l"),
    "RightHip": ("thigh_r", "RightKnee", "calf_r"),
    "RightKnee": ("calf_r", "RightAnkle", "foot_r"),
    "RightAnkle": ("foot_r", "RightToe", "ball_r"),
    "RightToe": ("ball_r", None, None),
    "LeftHip": ("thigh_l", "LeftKnee", "calf_l"),
    "LeftKnee": ("calf_l", "LeftAnkle", "foot_l"),
    "LeftAnkle": ("foot_l", "LeftToe", "ball_l"),
    "LeftToe": ("ball_l", None, None),
}
# Target bone parent order for the analytic local solve.
ORDER = ["pelvis", "spine_01", "spine_02", "spine_03", "neck_01", "head",
         "clavicle_r", "upperarm_r", "lowerarm_r", "hand_r",
         "clavicle_l", "upperarm_l", "lowerarm_l", "hand_l",
         "thigh_r", "calf_r", "foot_r", "ball_r",
         "thigh_l", "calf_l", "foot_l", "ball_l"]
TGT_TO_SRC = {v[0]: k for k, v in MAP.items()}


def frame_cuts(kind):
    with open(os.path.join(SRC_DIR, "Frame_Cuts.csv")) as f:
        for row in csv.DictReader(f):
            if row["STYLE_NAME"] == "Zombie":
                a, b = row[f"{kind}_START"], row[f"{kind}_STOP"]
                return int(a), int(b)
    raise SystemExit("no Frame_Cuts row")


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

for kind, name in CLIPS:
    path = os.path.join(SRC_DIR, f"Zombie_{kind}.bvh")
    start, stop = frame_cuts(kind)
    before = set(bpy.data.objects)
    bpy.ops.import_anim.bvh(filepath=path, axis_forward="-Z", axis_up="Y", global_scale=0.01,
                            rotate_mode="QUATERNION", update_scene_fps=False, update_scene_duration=False,
                            use_fps_scale=False, frame_start=1)
    src = next(o for o in set(bpy.data.objects) - before if o.type == "ARMATURE")
    src_leg = (src.data.bones["LeftHip"].length + src.data.bones["LeftKnee"].length)
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
    hips_rest_fwd = S0["Hips"] @ Vector((0, 0, 1))  # source forward is +Z before import; use the world rest matrix on the file axis
    # After import the source faces Blender -Y; derive forward from the rest matrix instead of assuming.
    fwd_rest = (S0["Hips"].inverted() @ Vector((0, -1, 0)))

    action = bpy.data.actions.new(name)
    tgt.animation_data_create(); tgt.animation_data.action = action
    for pb in tgt.pose.bones:
        pb.rotation_mode = "QUATERNION"
        pb.rotation_quaternion = (1, 0, 0, 0); pb.location = (0, 0, 0); pb.scale = (1, 1, 1)

    step = max(1, round(60 / FPS))
    frames = list(range(start, stop + 1, step))
    # Pass 1: read source world matrices per frame.
    sw = []; hips_pos = []; headings = []
    for f in frames:
        bpy.context.scene.frame_set(f)
        row = {s: (src.matrix_world @ src.pose.bones[s].matrix).to_3x3() for s in MAP}
        sw.append(row)
        hp = (src.matrix_world @ src.pose.bones["Hips"].matrix).to_translation() * ratio
        hips_pos.append(hp)
        fwd = (row["Hips"] @ S0["Hips"].inverted()) @ Vector((0, -1, 0))
        headings.append(math.atan2(fwd.x, -fwd.y))  # yaw about Z: Rz(yaw) maps rest forward (0,-1,0) onto fwd
    headings = smooth_angles(headings, half_window=int(0.4 * FPS))
    # Root travel is the low-passed hip path; the sway stays in the pelvis
    # (as authored root motion does), so a standing clip has a still root.
    def smooth_xy(points, half_window):
        out = []
        n = len(points)
        for i in range(n):
            lo, hi = max(0, i - half_window), min(n, i + half_window + 1)
            sx = sum(p.x for p in points[lo:hi]); sy = sum(p.y for p in points[lo:hi])
            out.append(Vector((sx / (hi - lo), sy / (hi - lo), 0.0)))
        return out
    root_xy = smooth_xy(hips_pos, half_window=int(0.5 * FPS))
    if kind == "ID":
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

    # Pass 3: root/pelvis split and keyframes.
    out_frame = 1
    replaned = 0
    for i, M in enumerate(solved):
        for tname in ORDER:
            M[tname].translation = M[tname].translation + Vector((0, 0, ground_shift))
        yaw = headings[i]
        replaned += plane_the_elbows(M, yaw)
        root_rest = rest_local["root"]
        rp = root_xy[i]
        M["root"] = Matrix.Translation((rp.x, rp.y, 0.0)) @ Matrix.Rotation(yaw, 4, "Z") @ root_rest
        for tname in ["root"] + ORDER:
            p = parent_of[tname]
            if p is None:
                basis = rest_local[tname].inverted() @ M[tname]
            else:
                basis = (rest_local[p].inverted() @ rest_local[tname]).inverted() @ M[p].inverted() @ M[tname]
            pb = tgt.pose.bones[tname]
            pb.rotation_quaternion = basis.to_quaternion()
            if tname in ("root", "pelvis"):
                pb.location = basis.to_translation()
                pb.keyframe_insert("location", frame=out_frame)
            pb.keyframe_insert("rotation_quaternion", frame=out_frame)
        out_frame += 1
    bpy.context.scene.frame_start = 1; bpy.context.scene.frame_end = out_frame - 1
    bpy.context.scene.render.fps = FPS
    print(f"RETARGET {kind} -> {name}: source frames {start}-{stop} @60 -> {out_frame-1} frames @{FPS}, leg ratio {ratio:.3f}")
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
            # Side view too (from the character's left).
            scn.render.filepath = os.path.join(OUT, f"{name}_f{fi}.png")
            bpy.ops.render.render(write_still=True)
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
