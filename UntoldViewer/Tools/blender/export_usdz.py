"""Exports a prepared board (prep_board.py output) as a USDZ for the RealityKit
comparison (docs/IMPLEMENTATION.md, "Engine vs RealityKit"):

    Blender -b /tmp/oche/board.blend --python export_usdz.py -- <out.usdz>

Same orientation convert as `export-untold --convert-orientation`: Blender
(x, y, z) → (x, z, −y), so the face ends up on +z, metres, modifiers applied
as the viewport shows them, materials as UsdPreviewSurface with the textures
packed into the archive.
"""

import os
import sys

import bpy

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from oche_common import log, script_args


def main():
    args = script_args()
    if len(args) < 1:
        raise SystemExit("usage: export_usdz.py -- <out.usdz>")
    out_path = os.path.abspath(args[0])
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    # The digits are text objects and the bristle wear is curves; `export-untold`
    # meshes them, the USD exporter would drop them (or write them as curves
    # RealityKit does not draw), so mesh them here the same way.
    convertible = [o for o in bpy.data.objects if o.type in {"CURVE", "FONT"}]
    if convertible:
        with bpy.context.temp_override(selected_objects=convertible, active_object=convertible[0],
                                       selected_editable_objects=convertible):
            bpy.ops.object.convert(target="MESH")
    meshes = [o for o in bpy.data.objects if o.type == "MESH"]
    empty = [o for o in meshes if len(o.data.polygons) == 0]
    for o in empty:
        bpy.data.objects.remove(o)
    meshes = [o for o in meshes if o not in empty]
    log(f"meshed {len(convertible)} curve/text objects ({len(empty)} empty, dropped); exporting {len(meshes)} meshes to {out_path}")
    bpy.ops.wm.usd_export(
        filepath=out_path,
        selected_objects_only=False,
        evaluation_mode="VIEWPORT",
        export_meshes=True,
        export_lights=False,
        export_cameras=False,
        export_curves=False,
        export_hair=False,
        export_volumes=False,
        export_animation=False,
        export_materials=True,
        generate_preview_surface=True,
        generate_materialx_network=False,
        export_textures_mode="NEW",
        export_uvmaps=True,
        export_normals=True,
        triangulate_meshes=True,
        convert_orientation=True,
        # Blender calls +Y "forward" here: −Y (the board face) lands on +Z.
        export_global_forward_selection="NEGATIVE_Z",
        export_global_up_selection="Y",
        convert_scene_units="METERS",
        use_instancing=False,
    )
    log(f"wrote {os.path.getsize(out_path) / 1e6:.1f} MB")


main()
