# Headless character prep for the CoolMirror demo:
#   Blender --background --python prep_character.py -- <in.fbx> <textures_dir> <out.blend> <render.png>
# - applies object transforms (FBX cm scale)
# - relinks/creates texture nodes from <textures_dir> by name convention
# - adds bicepsL/bicepsR shape keys inflated from upper-arm skin weights
# - renders a verification still
import os
import re
import sys

import bpy
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1 :]
fbx_path, textures_dir, out_blend, render_png = argv[0], argv[1], argv[2], argv[3]

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.fbx(filepath=fbx_path)

# ── apply transforms so the armature/mesh live at unit scale ──────────────
for obj in bpy.data.objects:
    obj.select_set(True)
bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
for obj in bpy.data.objects:
    obj.select_set(False)

texture_files = {f.lower(): f for f in os.listdir(textures_dir)}

def find_texture(stem_candidates, suffixes):
    for stem in stem_candidates:
        for suffix in suffixes:
            key = f"{stem}_{suffix}.png".lower()
            if key in texture_files:
                return os.path.join(textures_dir, texture_files[key])
    return None

def material_stems(mat_name):
    base = re.sub(r"\.\d+$", "", mat_name)
    stems = [base]
    for cut in ("_MIC", "_MAT_INST", "_INST", "_MAT", "_Mat_INST", "_Master_MIC"):
        if base.endswith(cut):
            stems.append(base[: -len(cut)])
    # Texture packs often use slightly different part names than materials.
    for stem in list(stems):
        for old, new in (
            ("LowerPadsPlates", "PadsPlate"),
            ("PadsPlates", "PadsPlate"),
            ("UpperCarbonPads", "CarbonPads"),
            ("Upper", ""),
            ("Gloves", "Hand"),
        ):
            if old in stem:
                stems.append(stem.replace(old, new))
    return stems

# ── repair broken image paths, then fill materials missing texture nodes ──
for image in bpy.data.images:
    path = bpy.path.abspath(image.filepath) if image.filepath else ""
    if path and not os.path.exists(path):
        candidate = texture_files.get(os.path.basename(path).lower())
        if candidate:
            image.filepath = os.path.join(textures_dir, candidate)
            image.reload()

wired = 0
for mat in bpy.data.materials:
    if not mat.use_nodes:
        continue
    tree = mat.node_tree
    principled = next((n for n in tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
    if principled is None:
        continue
    stems = material_stems(mat.name)

    def hook(input_name, tex_path, non_color=False, via_normal_map=False):
        global wired
        socket = principled.inputs.get(input_name)
        if socket is None or socket.is_linked or tex_path is None:
            return
        node = tree.nodes.new("ShaderNodeTexImage")
        node.image = bpy.data.images.load(tex_path, check_existing=True)
        if non_color:
            node.image.colorspace_settings.name = "Non-Color"
        if via_normal_map:
            normal_map = next((n for n in tree.nodes if n.type == "NORMAL_MAP"), None)
            if normal_map is None:
                normal_map = tree.nodes.new("ShaderNodeNormalMap")
                tree.links.new(normal_map.outputs["Normal"], socket)
            if not normal_map.inputs["Color"].is_linked:
                tree.links.new(node.outputs["Color"], normal_map.inputs["Color"])
                wired += 1
        else:
            tree.links.new(node.outputs["Color"], socket)
            wired += 1

    hook("Base Color", find_texture(stems, ["BaseColor", "D", "Diffuse", "Albedo"]))
    hook("Roughness", find_texture(stems, ["Roughness", "R"]), non_color=True)
    hook("Metallic", find_texture(stems, ["Metallic", "M"]), non_color=True)
    hook("Normal", find_texture(stems, ["Normal", "N"]), non_color=True, via_normal_map=True)
print(f"[prep] wired {wired} texture links")

# ── biceps shape keys from upper-arm vertex groups ────────────────────────
def side_of(name):
    n = name.lower()
    if re.search(r"(^|[^a-z])l([^a-z]|$)|left", n):
        return "L"
    if re.search(r"(^|[^a-z])r([^a-z]|$)|right", n):
        return "R"
    return None

for obj in bpy.data.objects:
    if obj.type != "MESH" or not obj.vertex_groups:
        continue
    mesh = obj.data
    height = max(obj.dimensions.z, 1e-5)
    if mesh.shape_keys is None:
        obj.shape_key_add(name="Basis", from_mix=False)
    for side in ("L", "R"):
        def matches(name):
            packed = name.lower().replace(" ", "").replace("_", "").replace(":", "")
            if "forearm" in packed or "lower" in packed:
                return False
            has_arm = "uparm" in packed or "upperarm" in packed or packed.endswith("arm")
            explicit_side = f"{side.lower()}uparm" in packed or f"{side.lower()}upperarm" in packed
            return has_arm and (explicit_side or side_of(name) == side)

        groups = [g for g in obj.vertex_groups if matches(g.name)]
        if not groups:
            print(f"[prep] {obj.name}: no upper-arm group for side {side}")
            continue
        group_indices = {g.index for g in groups}
        key = obj.shape_key_add(name=f"biceps{side}", from_mix=False)
        moved = 0
        for vertex in mesh.vertices:
            weight = max((g.weight for g in vertex.groups if g.group in group_indices), default=0.0)
            if weight > 0.15:
                normal = Vector(vertex.normal)
                key.data[vertex.index].co = Vector(vertex.co) + normal * (0.022 * height / 2.0) * (weight ** 2)
                moved += 1
        print(f"[prep] {obj.name}: biceps{side} from {[g.name for g in groups]} ({moved} verts)")

# ── verification render ───────────────────────────────────────────────────
scene = bpy.context.scene
meshes = [o for o in bpy.data.objects if o.type == "MESH"]
center = sum((o.matrix_world.translation for o in meshes), Vector()) / len(meshes)
top = max((o.matrix_world @ Vector(v)) .z for o in meshes for v in o.bound_box)
bottom = min((o.matrix_world @ Vector(v)).z for o in meshes for v in o.bound_box)
mid = Vector((center.x, center.y, (top + bottom) / 2))
size = max(top - bottom, 0.5)

cam_data = bpy.data.cameras.new("VerifyCam")
cam = bpy.data.objects.new("VerifyCam", cam_data)
scene.collection.objects.link(cam)
cam.location = mid + Vector((0, -size * 1.9, 0))
cam.rotation_euler = (1.5708, 0, 0)
scene.camera = cam

sun_data = bpy.data.lights.new("VerifySun", type="SUN")
sun_data.energy = 3.0
sun = bpy.data.objects.new("VerifySun", sun_data)
scene.collection.objects.link(sun)
sun.rotation_euler = (0.9, 0.2, 0.5)

scene.render.resolution_x = 720
scene.render.resolution_y = 960
scene.render.filepath = render_png
try:
    scene.render.engine = "BLENDER_EEVEE_NEXT"
except TypeError:
    pass
bpy.ops.render.render(write_still=True)
print(f"[prep] rendered {render_png}")

# camera/sun are helpers only; remove before saving
bpy.data.objects.remove(cam)
bpy.data.objects.remove(sun)
bpy.ops.wm.save_as_mainfile(filepath=out_blend)
print(f"[prep] saved {out_blend}")
