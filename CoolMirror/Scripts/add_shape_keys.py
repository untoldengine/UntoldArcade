# Adds two procedural demo shape keys to the redplayer character and saves a
# .blend for the untold exporter: "belly" inflates the torso band outward,
# "bighead" scales the head region up.
import sys

import bpy

argv = sys.argv[sys.argv.index("--") + 1 :]
input_path, output_path = argv[0], argv[1]

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.wm.usd_import(filepath=input_path)

meshes = [obj for obj in bpy.data.objects if obj.type == "MESH"]
assert meshes, "no mesh imported"

for obj in meshes:
    mesh = obj.data
    if not mesh.vertices:
        continue

    zs = [v.co.z for v in mesh.vertices]
    z_min, z_max = min(zs), max(zs)
    height = max(z_max - z_min, 1e-5)

    obj.shape_key_add(name="Basis", from_mix=False)

    belly = obj.shape_key_add(name="belly", from_mix=False)
    for vertex in mesh.vertices:
        t = (vertex.co.z - z_min) / height
        if 0.35 <= t <= 0.6:
            band = 1.0 - abs((t - 0.475) / 0.125)
            radial = vertex.co.xy.length
            if radial > 1e-5:
                direction = vertex.co.xy / radial
                push = 0.12 * height * band
                co = belly.data[vertex.index].co
                co.x += direction.x * push
                co.y += direction.y * push

    head_vertices = [v for v in mesh.vertices if (v.co.z - z_min) / height > 0.62]
    if head_vertices:
        cx = sum(v.co.x for v in head_vertices) / len(head_vertices)
        cy = sum(v.co.y for v in head_vertices) / len(head_vertices)
        cz = sum(v.co.z for v in head_vertices) / len(head_vertices)
        bighead = obj.shape_key_add(name="bighead", from_mix=False)
        for vertex in head_vertices:
            t = (vertex.co.z - z_min) / height
            blend = min((t - 0.62) / 0.1, 1.0)
            scale = 1.0 + 0.25 * blend
            co = bighead.data[vertex.index].co
            co.x = cx + (co.x - cx) * scale
            co.y = cy + (co.y - cy) * scale
            co.z = cz + (co.z - cz) * scale

    print(f"[shapekeys] {obj.name}: {len(mesh.shape_keys.key_blocks)} key blocks")

bpy.ops.wm.save_as_mainfile(filepath=output_path)
print("[shapekeys] saved", output_path)
