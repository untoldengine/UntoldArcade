"""Turn the artist's zombie .blend (Zombie_intact_blood_dirt.blend) into the game rig and
cook it with the untold exporter.

The source file is a review scene: lights, cameras, a dozen garment variants, cloth
simulation proxies and the "FINAL ZOMBIE" collection (armature + skinned body + fused
skinned clothing + eyes). This script keeps the final set only and makes it the rig the
demo and its clip pipeline expect, the UE4-mannequin convention that `ZombieAA` had:

  * bones renamed to `root/pelvis/spine_01..03/neck_01/head`, `clavicle_l/upperarm_l/
    lowerarm_l/hand_l`, `thigh_l/calf_l/foot_l/ball_l` (+ fingers) — sides by POSITION:
    the artist's `_R` bones sit on +X, which is the character's LEFT (it faces -Y);
  * the two neck bones merged into one `neck_01` (weights summed), `Hips` made a deform
    bone, a `root` bone added at the origin for root motion;
  * the whole set scaled from 0.77 m to HEIGHT metres and the scale applied;
  * the clothes re-skinned with the body's weights (nearest skin face) and freed of
    every hand and finger weight, so shirt and skin bend as one and the cuffs stay on
    the forearms;
  * the three texture sets baked into one 2x2 atlas of TEX_SIZE tiles, the UVs moved
    into their tiles, the alpha-masked hair cards and the cornea shell dropped, the
    shape keys baked, the skin the clothes cover removed (one face ring kept under
    every edge), and body, clothes and eyes joined into one mesh with one material —
    the engine binds the animation per skinned node and the exporter splits per
    material;
  * everything else deleted and orphan data purged.

Env: SRC (artist .blend), OUT_BLEND (prepped rig .blend, the BLEND for the retarget
tools), OUT_DIR (the Models folder; the exporter writes <OUT_DIR>/<NAME>/<NAME>.untold + Textures/ and an HDR/ side folder to delete), NAME (default
Zombie), HEIGHT (default 1.75), TEX_SIZE (default 2048), EXPORT=0 to skip the export.
Run headless:
  /Applications/Blender.app/Contents/MacOS/Blender -b --python Tools/blender/prep_zombie.py
Requires the Untold Engine Blender add-on (untold_exporter) installed.
"""
import bpy, bmesh, os, sys
import numpy as np
from mathutils import Vector
from mathutils.bvhtree import BVHTree

SRC = os.environ.get("SRC", os.path.expanduser("~/Downloads/Zombie_intact_blood_dirt.blend"))
OUT_BLEND = os.environ.get("OUT_BLEND", os.path.expanduser("~/Projects/Untold/zombie_bd.blend"))
OUT_DIR = os.environ.get("OUT_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                                                 "Sources", "CoolZombieKit", "Resources", "Models"))
NAME = os.environ.get("NAME", "Zombie")
HEIGHT = float(os.environ.get("HEIGHT", "1.75"))
TEX_SIZE = int(os.environ.get("TEX_SIZE", "2048"))
EXPORT = os.environ.get("EXPORT", "1") == "1"

KEEP = {"Zombie_Armature": "Zombie", "ZOMBIE_BODY": "Body", "ZOMBIE_CLOTH": "Clothes", "Plane": "Eyes"}

# Artist bone -> mannequin bone. Suffix handled separately: artist `_R` = +X = character's left.
RENAME = {
    "Hips": "pelvis", "Spine_down": "spine_01", "Spine_mid": "spine_02", "Spine_top": "spine_03",
    "Neck_down": "neck_01", "Head": "head",
    "clavicle": "clavicle", "Arm": "upperarm", "Forearm": "lowerarm", "Hand": "hand",
    "Leg_Up": "thigh", "Leg_Low": "calf", "Feet": "foot", "feet_finger": "ball",
    "Finger_Index_1": "index_01", "Finger_Index_2": "index_02", "Finger_Index_3": "index_03",
    "Finger_Middle_1": "middle_01", "Finger_Middle_2": "middle_02", "Finger_Middle_3": "middle_03",
    "Finger_Ring_1": "ring_01", "Finger_Ring_2": "ring_02", "Finger_Ring_3": "ring_03",
    "Finger_Pinky_1": "pinky_01", "Finger_Pinky_2": "pinky_02", "Finger_Pinky_3": "pinky_03",
    "Thumb_1": "thumb_01", "Finger_Thumb_2": "thumb_02", "Finger_Thumb_3": "thumb_03",
}


def log(*a):
    print("prep_zombie:", *a)


def mannequin_name(bone_name, head_x):
    """Map an artist bone name to the mannequin one; sides from the bone's position."""
    base, side = bone_name, None
    if bone_name.endswith("_R") or bone_name.endswith("_L"):
        base = bone_name[:-2]
        side = "l" if head_x > 0 else "r"  # +X is the character's left (faces -Y)
    new = RENAME.get(base)
    if new is None:
        return None
    return f"{new}_{side}" if side else new


# ---------------------------------------------------------------- load + isolate
bpy.ops.wm.open_mainfile(filepath=SRC)
scene = bpy.context.scene
keep_objects = [bpy.data.objects[n] for n in KEEP]
for o in list(bpy.data.objects):
    if o not in keep_objects:
        bpy.data.objects.remove(o, do_unlink=True)
# The kept objects go straight into the scene root; every collection goes.
for o in keep_objects:
    if o.name not in scene.collection.objects:
        scene.collection.objects.link(o)
for c in list(bpy.data.collections):
    bpy.data.collections.remove(c)
bpy.context.view_layer.update()
for o in keep_objects:
    o.hide_set(False); o.hide_viewport = False; o.hide_render = False
    o.name = KEEP[o.name]
    if o.type == "MESH":
        o.data.name = o.name
arm = bpy.data.objects["Zombie"]
body, clothes, eyes = (bpy.data.objects[n] for n in ("Body", "Clothes", "Eyes"))
meshes = [body, clothes, eyes]

# Eyes: keep one UV map.
for m in meshes:
    while len(m.data.uv_layers) > 1:
        m.data.uv_layers.remove(m.data.uv_layers[-1])

# ---------------------------------------------------------------- rig
bpy.ops.object.select_all(action="DESELECT")
arm.select_set(True); bpy.context.view_layer.objects.active = arm

# Neck_up -> Neck_down weights (summed), before the bone goes.
for m in meshes:
    g_up = m.vertex_groups.get("Neck_up"); g_down = m.vertex_groups.get("Neck_down")
    if g_up is None:
        continue
    if g_down is None:
        g_down = m.vertex_groups.new(name="Neck_down")
    up_index = g_up.index
    for v in m.data.vertices:
        w = next((g.weight for g in v.groups if g.group == up_index), 0.0)
        if w > 0:
            g_down.add([v.index], w, "ADD")
    m.vertex_groups.remove(g_up)

bpy.ops.object.mode_set(mode="EDIT")
eb = arm.data.edit_bones
neck_up = eb["Neck_up"]; neck = eb["Neck_down"]; head = eb["Head"]
head.use_connect = False
head.parent = neck
neck.tail = head.head.copy()
eb.remove(neck_up)
root = eb.new("root")
root.head = Vector((0, 0, 0)); root.tail = Vector((0, 0, 0.1)); root.roll = 0
hips = eb["Hips"]
hips.use_connect = False
hips.parent = root
bpy.ops.object.mode_set(mode="OBJECT")

arm.data.bones["Hips"].use_deform = True
for b in arm.data.bones:
    if b.name == "root":
        continue
    new = mannequin_name(b.name, b.head_local.x)
    if new is None:
        log("WARNING: no mannequin name for bone", b.name)
        continue
    b.name = new
# Bone renames propagate to vertex groups; make sure.
bone_names = {b.name for b in arm.data.bones}
for m in meshes:
    stale = [g.name for g in m.vertex_groups if g.name not in bone_names]
    if stale:
        log("WARNING: vertex groups without a bone on", m.name, stale)
log("bones:", len(arm.data.bones), sorted(bone_names))

# ---------------------------------------------------------------- scale to HEIGHT
dg = bpy.context.evaluated_depsgraph_get()
zs = [(body.matrix_world @ v.co).z for v in body.evaluated_get(dg).to_mesh().vertices]
factor = HEIGHT / (max(zs) - min(zs))
log(f"height {max(zs) - min(zs):.3f} m -> {HEIGHT} m, scale x{factor:.3f}")
for m in meshes:
    mw = m.matrix_world.copy()
    m.parent = None
    m.matrix_world = mw
for o in [arm] + meshes:
    o.scale = (factor, factor, factor)
bpy.ops.object.select_all(action="DESELECT")
for o in [arm] + meshes:
    o.select_set(True)
bpy.context.view_layer.objects.active = arm
bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
for m in meshes:
    m.parent = arm
    m.matrix_parent_inverse = arm.matrix_world.inverted()
    mod = next(md for md in m.modifiers if md.type == "ARMATURE")
    mod.object = arm

# ---------------------------------------------------------------- skin: body and clothes deform as one
# The clothes came with automatic weights of their own, which disagree with the
# body's where it bends (at the waist, the hips and the collar, neighbouring cloth and
# skin vertices differ by up to 1.5 in weight), so the skin pokes through the shirt;
# and 300 vertices of the rolled cuffs weigh on the hand bones, so a cuff turns with
# the wrist and folds over the forearm. The clothes take the body's weights instead,
# interpolated from the nearest skin face, and nothing of the clothes follows a hand or
# a finger: a cuff stays on the forearm.
def transfer_weights(src, dst):
    for g in src.vertex_groups:
        if dst.vertex_groups.get(g.name) is None:
            dst.vertex_groups.new(name=g.name)
    mod = dst.modifiers.new("BodyWeights", "DATA_TRANSFER")
    mod.object = src
    mod.use_vert_data = True
    mod.data_types_verts = {"VGROUP_WEIGHTS"}
    mod.vert_mapping = "POLYINTERP_NEAREST"
    mod.layers_vgroup_select_src = "ALL"
    mod.layers_vgroup_select_dst = "NAME"
    mod.mix_mode = "REPLACE"
    mod.mix_factor = 1.0
    with bpy.context.temp_override(object=dst, active_object=dst, selected_objects=[dst], selected_editable_objects=[dst]):
        bpy.ops.object.modifier_move_to_index(modifier=mod.name, index=0)
        bpy.ops.object.modifier_apply(modifier=mod.name)

HAND_PREFIXES = ("hand", "thumb", "finger", "index", "middle", "ring", "pinky")

def unhand(obj, fallback="lowerarm"):
    """Takes every hand and finger weight off `obj` and renormalises what is left; a
    vertex that had nothing else goes to the forearm of its side."""
    names = [g.name for g in obj.vertex_groups]
    hand = {i for i, n in enumerate(names) if n.lower().startswith(HAND_PREFIXES)}
    changed = rescued = 0
    for v in obj.data.vertices:
        weights = {g.group: g.weight for g in v.groups if g.weight > 0}
        held = weights.keys() & hand
        if not held:
            continue
        changed += 1
        side = "_l" if any(names[i].endswith("_l") for i in held) else "_r"
        for i in held:
            obj.vertex_groups[i].remove([v.index])
        rest = {i: w for i, w in weights.items() if i not in hand}
        total = sum(rest.values())
        if total < 1e-4:
            obj.vertex_groups[fallback + side].add([v.index], 1.0, "REPLACE")
            rescued += 1
        else:
            for i, w in rest.items():
                obj.vertex_groups[i].add([v.index], w / total, "REPLACE")
    return changed, rescued

transfer_weights(body, clothes)
changed, rescued = unhand(clothes)
log(f"clothes: weights taken from the body; {changed} vertices freed of the hands ({rescued} moved to the forearm)")

# No bone weighs on a vertex more than REACH metres from it. The automatic weights
# leave a little of the pelvis on the wrists (the hands hang beside the hips in the
# bind pose), and taking the hand weights off the cuffs doubled it to 15 %: with the
# arm raised a metre from where it was bound, that is a 15 cm fin on the vertices that
# have it beside vertices that do not (headset, 2026-10-27). A quarter of a metre is
# farther than any bone legitimately reaches on this body (the spine bones sit 13 cm
# apart, a shoulder vertex is 20 cm from the upper spine) and well short of the wrist
# to the pelvis (45 cm), so the crotch, the armpits and the collar keep their blends.
REACH = 0.25

def prune_far_weights(obj, arm, reach=REACH):
    segments = {b.name: (arm.matrix_world @ b.head_local, arm.matrix_world @ b.tail_local) for b in arm.data.bones if b.use_deform}
    def distance(p, a, b):
        ab = b - a; t = max(0.0, min(1.0, (p - a).dot(ab) / max(ab.length_squared, 1e-9)))
        return (p - (a + ab * t)).length
    names = [g.name for g in obj.vertex_groups]
    mw = obj.matrix_world
    pruned = 0; rehomed = 0; dropped_total = 0.0; farthest = 0.0
    for v in obj.data.vertices:
        weights = {names[g.group]: g.weight for g in v.groups if g.weight > 0 and names[g.group] in segments}
        if not weights:
            continue
        p = mw @ v.co
        distances = {n: distance(p, *segments[n]) for n in weights}
        dropped = {n: w for n, w in weights.items() if distances[n] > reach}
        if not dropped:
            continue
        pruned += 1; dropped_total += sum(dropped.values()); farthest = max(farthest, max(distances[n] for n in dropped))
        for n in dropped:
            obj.vertex_groups[n].remove([v.index])
        kept = {n: w for n, w in weights.items() if n not in dropped}
        total = sum(kept.values())
        if total < 1e-4:
            nearest = min(segments, key=lambda n: distance(p, *segments[n]))
            obj.vertex_groups[nearest].add([v.index], 1.0, "REPLACE"); rehomed += 1
        else:
            for n, w in kept.items():
                obj.vertex_groups[n].add([v.index], w / total, "REPLACE")
    return pruned, rehomed, dropped_total, farthest

for m in (body, clothes):
    pruned, rehomed, dropped, farthest = prune_far_weights(m, arm)
    log(f"{m.name}: {pruned} vertices lost weights of bones farther than {REACH} m ({rehomed} rehomed, {dropped:.1f} weight dropped in all, farthest {farthest:.2f} m)")

# ---------------------------------------------------------------- images
def image(name):
    img = bpy.data.images.get(name)
    if img is None:
        raise SystemExit(f"image {name} missing")
    return img


TEX_DIR = os.path.splitext(OUT_BLEND)[0] + "_textures"
os.makedirs(TEX_DIR, exist_ok=True)
_resampled = {}


def pixels(img):
    w, h = img.size
    a = np.empty(w * h * 4, dtype=np.float32)
    img.pixels.foreach_get(a)
    return a.reshape(h, w, 4)


def box_down(arr, size):
    h, w, _ = arr.shape
    f = max(1, w // size)
    if f <= 1:
        return arr
    return arr[: (h // f) * f, : (w // f) * f].reshape(h // f, f, w // f, f, 4).mean(axis=(1, 3))


def new_image(name, arr, colorspace):
    """A fresh image from an array, written to TEX_DIR and packed (the artist's 4K originals
    stay out of the prepped file)."""
    h, w, _ = arr.shape
    img = bpy.data.images.new(name, w, h, alpha=True)
    img.pixels.foreach_set(np.ascontiguousarray(arr, dtype=np.float32).reshape(-1))
    img.filepath_raw = os.path.join(TEX_DIR, name + ".png")
    img.file_format = "PNG"
    img.alpha_mode = "STRAIGHT"
    img.save()
    img.pack()
    img.colorspace_settings.name = colorspace
    return img


# Artist texture prefixes -> the names the model ships with.
TEX_NAMES = {"CARA_FUSIONADA": "ZombieFace", "CUERPO": "ZombieBody", "ropa": "ZombieClothes"}


def texture_name(img_name, suffix=""):
    stem = os.path.splitext(img_name)[0].replace(".1001", "").replace(".1002", "")
    for prefix, new in TEX_NAMES.items():
        if stem.startswith(prefix + "_"):
            return new + "_" + stem[len(prefix) + 1:] + suffix
    return stem + suffix


def downscale(img, size=TEX_SIZE, colorspace=None):
    """The image resampled to at most `size` texels, as a new packed image (cached by name)."""
    key = img.name
    if key in _resampled:
        return _resampled[key]
    cs = colorspace or img.colorspace_settings.name
    arr = box_down(pixels(img), size)
    out = new_image(texture_name(img.name), arr, cs)
    _resampled[key] = out
    return out


def alpha_fraction(alpha_img):
    return float((pixels(alpha_img)[:, :, 0] < 0.5).mean())


def bake_alpha_into(base_img, alpha_img):
    """The base color image with the alpha map's red channel as its alpha channel."""
    base = box_down(pixels(base_img), TEX_SIZE)
    alpha = box_down(pixels(alpha_img), base.shape[1])
    base = base.copy(); base[:, :, 3] = alpha[:, :, 0]
    out = new_image(texture_name(base_img.name, "_alpha"), base, "sRGB")
    _resampled[base_img.name] = out
    return out


def principled_material(name, base, rough=None, metal=None, normal=None, alpha=False, alpha_value=None, resample=True):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    nt = mat.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    bsdf = nt.nodes.new("ShaderNodeBsdfPrincipled")
    nt.links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])

    def tex(img, colorspace, y):
        node = nt.nodes.new("ShaderNodeTexImage")
        node.image = downscale(img) if resample else img
        node.image.colorspace_settings.name = colorspace
        node.location = (-500, y)
        return node

    tb = tex(base, "sRGB", 300)
    nt.links.new(tb.outputs["Color"], bsdf.inputs["Base Color"])
    if rough is not None:
        nt.links.new(tex(rough, "Non-Color", 0).outputs["Color"], bsdf.inputs["Roughness"])
    else:
        bsdf.inputs["Roughness"].default_value = 0.7
    if metal is not None:
        nt.links.new(tex(metal, "Non-Color", -300).outputs["Color"], bsdf.inputs["Metallic"])
    else:
        bsdf.inputs["Metallic"].default_value = 0.0
    if normal is not None:
        nm = nt.nodes.new("ShaderNodeNormalMap"); nm.location = (-250, -600)
        nt.links.new(tex(normal, "Non-Color", -600).outputs["Color"], nm.inputs["Color"])
        nt.links.new(nm.outputs["Normal"], bsdf.inputs["Normal"])
    if alpha:
        nt.links.new(tb.outputs["Alpha"], bsdf.inputs["Alpha"])
    if alpha_value is not None:
        bsdf.inputs["Alpha"].default_value = alpha_value
    if alpha or alpha_value is not None:
        if hasattr(mat, "surface_render_method"):
            mat.surface_render_method = "DITHERED" if alpha else "BLENDED"
        try:
            mat.blend_method = "HASHED" if alpha else "BLEND"
        except Exception:
            pass
    return mat


# ---------------------------------------------------------------- one mesh, one material
# The engine binds the animation per skinned mesh node, and the exporters split a
# multi-material object into one node per material (the add-on's September exporter
# also drops the skin of the fragments), so a character that must stay one animated
# body is one mesh with one material: the three texture sets go into one 2x2 atlas of
# TEX_SIZE tiles, the UVs move into their tile, the alpha-masked hair cards and the
# cornea shell go (the material is opaque), the shape keys are baked, and the three
# objects are joined into one.
import bmesh

TILE = TEX_SIZE
ATLAS = TILE * 2
TILES = {"face": (0, 1), "body": (1, 1), "clothes": (0, 0)}  # (column, row); row 0 is the bottom


def tile_array(img):
    return box_down(pixels(img), TILE)


def blank_atlas(fill):
    a = np.empty((ATLAS, ATLAS, 4), dtype=np.float32)
    a[:] = fill
    return a


def place(atlas, arr, tile):
    c, r = TILES[tile]
    h, w, _ = arr.shape
    atlas[r * TILE:r * TILE + h, c * TILE:c * TILE + w, :3] = arr[:, :, :3]


atlas_base = blank_atlas((0.5, 0.5, 0.5, 1.0))
atlas_rough = blank_atlas((0.7, 0.7, 0.7, 1.0))
atlas_normal = blank_atlas((0.5, 0.5, 1.0, 1.0))
sources = {
    "face": ("CARA_FUSIONADA_BaseColor.png", "CARA_FUSIONADA_Roughness.png", "CARA_FUSIONADA_Normal.png"),
    "body": ("CUERPO_BaseColor.png", "CUERPO_Roughness.png", "CUERPO_Normal.png"),
    "clothes": ("ropa_BaseColor.png", "ropa_Roughness.png", "ropa_Normal.png"),
}
for tile, (base, rough, normal) in sources.items():
    place(atlas_base, tile_array(image(base)), tile)
    place(atlas_rough, tile_array(image(rough)), tile)
    place(atlas_normal, tile_array(image(normal)), tile)
body_alpha_tex = tile_array(image("CUERPO_Alpha.png"))[:, :, 0]
log(f"alpha<0.5 texels: body {float((body_alpha_tex < 0.5).mean()):.1%} (those faces go), clothes {alpha_fraction(image('ropa_Alpha.png')):.1%} (ignored)")

atlas_base_img = new_image("Zombie_BaseColor", atlas_base, "sRGB")
atlas_rough_img = new_image("Zombie_Roughness", atlas_rough, "Non-Color")
atlas_normal_img = new_image("Zombie_Normal", atlas_normal, "Non-Color")
atlas_mat = principled_material("Zombie", atlas_base_img, rough=atlas_rough_img, normal=atlas_normal_img, resample=False)


def apply_shape_keys(obj):
    """Bake the current shape-key mix into the mesh (the zombie look lives in the keys)."""
    if not obj.data.shape_keys:
        return
    with bpy.context.temp_override(object=obj, active_object=obj, selected_objects=[obj], selected_editable_objects=[obj]):
        bpy.ops.object.shape_key_remove(all=True, apply_mix=True)


def delete_faces(obj, doomed):
    """Drop the polygons whose index is in `doomed`; loose geometry goes with them."""
    bm = bmesh.new()
    bm.from_mesh(obj.data)
    bm.faces.ensure_lookup_table()
    faces = [bm.faces[i] for i in doomed]
    bmesh.ops.delete(bm, geom=faces, context="FACES")
    bm.to_mesh(obj.data)
    bm.free()
    obj.data.update()


def uv_centre_alpha(obj, poly):
    uv = obj.data.uv_layers.active.data
    cu = sum((uv[li].uv for li in poly.loop_indices), Vector((0, 0))) / len(poly.loop_indices)
    x = int(min(max(cu.x % 1.0, 0.0), 0.999999) * TILE)
    y = int(min(max(cu.y % 1.0, 0.0), 0.999999) * TILE)
    return body_alpha_tex[y, x]


def remap_uvs(obj, slot_tiles):
    """Move each polygon's UVs into the atlas tile of its material slot."""
    uv = obj.data.uv_layers.active.data
    for poly in obj.data.polygons:
        tile = slot_tiles.get(poly.material_index)
        if tile is None:
            continue
        c, r = TILES[tile]
        for li in poly.loop_indices:
            u, v = uv[li].uv
            u = u if 0.0 <= u <= 1.0 else u % 1.0
            v = v if 0.0 <= v <= 1.0 else v % 1.0
            uv[li].uv = (u * 0.5 + c * 0.5, v * 0.5 + r * 0.5)


def slot_index(obj, needle):
    for i, s in enumerate(obj.material_slots):
        if s.material and needle in s.material.name.lower():
            return i
    return None


for m in meshes:
    apply_shape_keys(m)

# Body: face + skin slots; the hair cards (alpha-masked faces of the skin slot) go.
face_slot = slot_index(body, "cara"); skin_slot = slot_index(body, "cuerpo")
hair = [p.index for p in body.data.polygons if p.material_index == skin_slot and uv_centre_alpha(body, p) < 0.5]
remap_uvs(body, {face_slot: "face", skin_slot: "body"})
delete_faces(body, hair)
log(f"body: face slot {face_slot}, skin slot {skin_slot}, hair faces removed {len(hair)}")

# The skin the clothes cover goes: it is never seen, and where the two meshes bend
# apart it is what pokes through. A face is covered when a ray from its centre along
# its normal meets the clothes within `reach`; a one-face ring stays under every edge
# of the clothes, so a sleeve or a collar that lifts a little shows skin, not a hole.
# The hands and wrists are never culled: the rolled cuffs stand off the arm, and when
# the hand bends away from a cuff the skin under it shows — culled, it showed the
# inside of the cuff through a hole (headset, 2026-10-27).
def covered_faces(obj, cover, reach=0.04, keep_groups=(), keep_near=(), keep_radius=0.08):
    bm = bmesh.new(); bm.from_mesh(cover.data); bm.transform(cover.matrix_world)
    tree = BVHTree.FromBMesh(bm)
    mw = obj.matrix_world; nm = mw.to_3x3().inverted().transposed()
    names = [g.name for g in obj.vertex_groups]
    keep_index = {i for i, n in enumerate(names) if n.lower().startswith(keep_groups)}
    kept_vertices = set()
    for v in obj.data.vertices:
        if any(g.group in keep_index and g.weight > 0 for g in v.groups) \
           or any((mw @ v.co - point).length < keep_radius for point in keep_near):
            kept_vertices.add(v.index)
    covered = set()
    for p in obj.data.polygons:
        if any(v in kept_vertices for v in p.vertices):
            continue
        c = mw @ p.center; n = (nm @ p.normal).normalized()
        if tree.ray_cast(c + n * 0.001, n, reach)[0] is not None:
            covered.add(p.index)
    bm.free()
    exposed_vertices = {v for p in obj.data.polygons if p.index not in covered for v in p.vertices}
    return [i for i in covered if not any(v in exposed_vertices for v in obj.data.polygons[i].vertices)]

wrists = [arm.matrix_world @ arm.data.bones[name].head_local for name in ("hand_l", "hand_r")]
hidden = covered_faces(body, clothes, keep_groups=HAND_PREFIXES, keep_near=wrists)
delete_faces(body, hidden)
log(f"body: {len(hidden)} faces under the clothes removed, {len(body.data.polygons)} left")
# Eyes: the eye faces use the face textures; the cornea shell goes.
cornea_slot = slot_index(eyes, "cornea")
eye_slots = {i: "face" for i in range(len(eyes.material_slots)) if i != cornea_slot}
remap_uvs(eyes, eye_slots)
delete_faces(eyes, [p.index for p in eyes.data.polygons if p.material_index == cornea_slot])
log(f"eyes: cornea slot {cornea_slot} removed, {len(eyes.data.polygons)} faces left")
# Clothes: one slot.
remap_uvs(clothes, {i: "clothes" for i in range(len(clothes.material_slots))})

# One material everywhere, then one object. After the join every polygon must sit on
# slot 0: the exporters split by material INDEX, not by material.
for m in meshes:
    for s in m.material_slots:
        s.material = atlas_mat
with bpy.context.temp_override(object=body, active_object=body, selected_objects=meshes, selected_editable_objects=meshes):
    bpy.ops.object.join()
for p in body.data.polygons:
    p.material_index = 0
while len(body.material_slots) > 1:
    body.active_material_index = len(body.material_slots) - 1
    with bpy.context.temp_override(object=body, active_object=body):
        bpy.ops.object.material_slot_remove()
body.name = "ZombieMesh"; body.data.name = "ZombieMesh"
meshes = [body]
log(f"joined: {len(body.data.vertices)} verts, {len(body.data.polygons)} faces, slots {[s.material.name for s in body.material_slots]}, groups {len(body.vertex_groups)}")

# ---------------------------------------------------------------- purge + save
bpy.data.orphans_purge(do_local_ids=True, do_linked_ids=True, do_recursive=True)
for img in list(bpy.data.images):
    if img.users == 0:
        bpy.data.images.remove(img)
scene.frame_start, scene.frame_end, scene.render.fps = 1, 1, 30
os.makedirs(os.path.dirname(OUT_BLEND), exist_ok=True)
bpy.ops.wm.save_as_mainfile(filepath=OUT_BLEND, compress=True)
log("saved", OUT_BLEND)

dg = bpy.context.evaluated_depsgraph_get()
for m in meshes:
    me = m.evaluated_get(dg).to_mesh()
    zs = [(m.matrix_world @ v.co).z for v in me.vertices]
    log(f"  {m.name}: z {min(zs):.3f}..{max(zs):.3f} tris {sum(len(p.vertices) - 2 for p in me.polygons)} mats {[s.material.name for s in m.material_slots]}")
for n in ("root", "pelvis", "spine_03", "neck_01", "head", "upperarm_l", "hand_l", "thigh_l", "foot_l", "ball_l"):
    b = arm.data.bones[n]
    log(f"  bone {n}: parent={b.parent.name if b.parent else None} head={tuple(round(v, 3) for v in b.head_local)}")

# ---------------------------------------------------------------- export
if EXPORT:
    try:
        bpy.ops.preferences.addon_enable(module="untold_exporter")
    except Exception as e:
        log("addon enable:", e)
    os.makedirs(OUT_DIR, exist_ok=True)
    out = os.path.join(os.path.abspath(OUT_DIR), NAME + ".untold")
    res = bpy.ops.untold.export_asset(filepath=out, scope="SCENE", file_type_name="tile",
                                      convert_orientation=True, source_orientation="blender-native",
                                      compress_geometry=False, bake_textures=False)
    log("EXPORT", res, out)
print("DONE")
