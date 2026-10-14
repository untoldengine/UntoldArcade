"""Shared helpers for the Oche Blender prep scripts (headless Blender 5.x).

The artist files put the board centre at the world origin, the board front
on −Y and Z up, metric units (docs/assets/README_lowpoly.txt). The board
plane is therefore X–Z: X is the viewer's right when looking at the face
from −Y, Z is up. `export-untold --convert-orientation` maps Blender
(x, y, z) → engine (x, z, −y), so these become the engine's x and y and the
face ends up on engine +z, which is the game's board +z (toward the player).
"""

import math
import re
import sys

import bpy


def script_args():
    """Arguments after `--` on the Blender command line."""
    argv = sys.argv
    if "--" in argv:
        return argv[argv.index("--") + 1:]
    return []


def log(message):
    print(f"[oche] {message}", flush=True)


def find_collection(pattern):
    """First collection whose name matches `pattern` (regex, case-insensitive)."""
    regex = re.compile(pattern, re.IGNORECASE)
    for collection in bpy.data.collections:
        if regex.search(collection.name):
            return collection
    return None


def mesh_objects(collection, recursive=True):
    """Mesh objects in a collection (and its children)."""
    found = []
    if collection is None:
        return found
    for obj in collection.objects:
        if obj.type == "MESH":
            found.append(obj)
    if recursive:
        for child in collection.children:
            found.extend(mesh_objects(child, True))
    return found


def world_vertices(obj):
    """World-space vertex coordinates of a mesh object (evaluated, modifiers applied)."""
    depsgraph = bpy.context.evaluated_depsgraph_get()
    evaluated = obj.evaluated_get(depsgraph)
    mesh = evaluated.to_mesh()
    matrix = evaluated.matrix_world
    points = [matrix @ v.co for v in mesh.vertices]
    evaluated.to_mesh_clear()
    return points


def board_polar(point):
    """(radius, clockwise angle in degrees from the top) of a point in the board plane."""
    r = math.hypot(point.x, point.z)
    degrees = math.degrees(math.atan2(point.x, point.z)) % 360.0
    return r, degrees


def triangle_count(objects):
    total = 0
    depsgraph = bpy.context.evaluated_depsgraph_get()
    for obj in objects:
        if obj.type != "MESH":
            continue
        mesh = obj.evaluated_get(depsgraph).to_mesh()
        mesh.calc_loop_triangles()
        total += len(mesh.loop_triangles)
        obj.evaluated_get(depsgraph).to_mesh_clear()
    return total


def delete_objects(objects):
    """Removes objects through the data API: works for objects in other
    scenes or excluded collections, which the selection operators refuse."""
    for obj in list(objects):
        try:
            bpy.data.objects.remove(obj, do_unlink=True)
        except ReferenceError:
            pass


def activate_scene_containing(collection):
    """Makes the scene that links `collection` the active one (the artist
    files have a second "product studio" scene with linked copies)."""
    for scene in bpy.data.scenes:
        if collection == scene.collection or collection in scene.collection.children_recursive:
            bpy.context.window.scene = scene
            return scene
    return bpy.context.scene


def _make_selectable(obj):
    obj.hide_viewport = False
    obj.hide_select = False
    try:
        obj.hide_set(False)
    except RuntimeError:
        pass
    view_layer = bpy.context.view_layer
    if obj.name not in view_layer.objects:
        bpy.context.scene.collection.objects.link(obj)
    # Collections excluded from the view layer hide their objects from selection.
    def enable(layer_collection):
        if obj.name in layer_collection.collection.objects:
            layer_collection.exclude = False
            layer_collection.hide_viewport = False
        for child in layer_collection.children:
            enable(child)
    enable(view_layer.layer_collection)


def select_only(objects, active=None):
    for obj in objects:
        _make_selectable(obj)
    bpy.ops.object.select_all(action="DESELECT")
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = active or (objects[0] if objects else None)


def keep_only_collections(keep):
    """Removes every object outside the kept collections (and all lights/cameras)."""
    kept = set()
    for collection in keep:
        for obj in collection.all_objects:
            kept.add(obj.name)
    doomed = [obj for obj in bpy.data.objects if obj.name not in kept or obj.type in {"LIGHT", "CAMERA"}]
    delete_objects(doomed)
    # Drop now-empty collections so the export stays tidy.
    for collection in list(bpy.data.collections):
        if collection not in keep and not collection.all_objects and not any(c in keep for c in collection.children_recursive):
            bpy.data.collections.remove(collection)


def unparent_keep_transform(objects):
    """Clears parents while keeping the world pose: a parent removed through
    the data API would otherwise drop its children back to their local basis."""
    for obj in objects:
        if obj.parent is None:
            continue
        world = obj.matrix_world.copy()
        obj.parent = None
        obj.matrix_world = world


def rebase_to(objects, empty):
    """Moves `objects` so that `empty`'s frame becomes the world frame
    (the empty ends up at the origin with identity rotation)."""
    unparent_keep_transform(objects)
    inverse = empty.matrix_world.inverted()
    for obj in objects:
        obj.matrix_world = inverse @ obj.matrix_world


def apply_transforms(objects):
    select_only(objects)
    if objects:
        bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)


def join(objects, name):
    """Joins `objects` into one mesh named `name` (first object becomes the host)."""
    if not objects:
        return None
    select_only(objects, active=objects[0])
    if len(objects) > 1:
        bpy.ops.object.join()
    host = bpy.context.view_layer.objects.active
    host.name = name
    host.data.name = name
    return host


def principled_material(name, base_color, roughness, metallic=0.0):
    material = bpy.data.materials.new(name)
    material.use_nodes = True
    nodes = material.node_tree.nodes
    bsdf = nodes.get("Principled BSDF")
    if bsdf is None:
        bsdf = nodes.new("ShaderNodeBsdfPrincipled")
        output = nodes.get("Material Output") or nodes.new("ShaderNodeOutputMaterial")
        material.node_tree.links.new(bsdf.outputs["BSDF"], output.inputs["Surface"])
    bsdf.inputs["Base Color"].default_value = (*base_color, 1.0)
    bsdf.inputs["Roughness"].default_value = roughness
    bsdf.inputs["Metallic"].default_value = metallic
    return material


def textured_material(name, base_color_path, roughness_path=None, normal_path=None, metallic_path=None):
    """A Principled material fed by image textures on the active UV map."""
    material = principled_material(name, (1, 1, 1), 0.85)
    tree = material.node_tree
    nodes, links = tree.nodes, tree.links
    bsdf = nodes.get("Principled BSDF")

    def image_node(path, colorspace):
        image = bpy.data.images.load(path, check_existing=True)
        image.colorspace_settings.name = colorspace
        node = nodes.new("ShaderNodeTexImage")
        node.image = image
        return node

    base = image_node(base_color_path, "sRGB")
    links.new(base.outputs["Color"], bsdf.inputs["Base Color"])
    if roughness_path:
        rough = image_node(roughness_path, "Non-Color")
        links.new(rough.outputs["Color"], bsdf.inputs["Roughness"])
    if metallic_path:
        metal = image_node(metallic_path, "Non-Color")
        links.new(metal.outputs["Color"], bsdf.inputs["Metallic"])
    if normal_path:
        normal_image = image_node(normal_path, "Non-Color")
        normal_map = nodes.new("ShaderNodeNormalMap")
        normal_map.inputs["Strength"].default_value = 1.0
        links.new(normal_image.outputs["Color"], normal_map.inputs["Color"])
        links.new(normal_map.outputs["Normal"], bsdf.inputs["Normal"])
    return material


def planar_board_uv(obj, extent=0.2255, flip_v=False):
    """UV u = (x + extent) / (2 extent), v = (z + extent) / (2 extent) in the
    board plane (local coordinates, transforms applied). The authored PNGs
    put local +Y (board top) on the first row, i.e. v = 1 in Blender's
    bottom-up convention, so no flip is needed in Blender; flip only if the
    engine samples row 0 as v = 0."""
    mesh = obj.data
    layer = mesh.uv_layers.get("Board") or mesh.uv_layers.new(name="Board")
    mesh.uv_layers.active = layer
    size = extent * 2
    for loop in mesh.loops:
        co = mesh.vertices[loop.vertex_index].co
        u = (co.x + extent) / size
        v = (co.z + extent) / size
        if flip_v:
            v = 1.0 - v
        layer.data[loop.index].uv = (u, v)


def save_as(path):
    bpy.ops.wm.save_as_mainfile(filepath=path, compress=True)
    log(f"saved {path}")


def route_socket_to_emission(obj, socket_name):
    """Rewires every material on `obj` so its Principled `socket_name` input
    (a texture or a constant) is emitted directly: baking EMIT then captures
    the raw Base Color or Metallic value, which a DIFFUSE bake of a metallic
    surface would return as black. Destructive: only for bake sources."""
    for slot in obj.material_slots:
        material = slot.material
        if material is None or not material.use_nodes:
            continue
        tree = material.node_tree
        bsdf = next((n for n in tree.nodes if n.type == "BSDF_PRINCIPLED"), None)
        output = next((n for n in tree.nodes if n.type == "OUTPUT_MATERIAL"), None)
        if bsdf is None or output is None:
            continue
        emission = tree.nodes.new("ShaderNodeEmission")
        emission.inputs["Strength"].default_value = 1.0
        source = bsdf.inputs[socket_name]
        if source.is_linked:
            tree.links.new(source.links[0].from_socket, emission.inputs["Color"])
        else:
            value = source.default_value
            if isinstance(value, float):
                emission.inputs["Color"].default_value = (value, value, value, 1.0)
            else:
                emission.inputs["Color"].default_value = tuple(value)
        for link in list(output.inputs["Surface"].links):
            tree.links.remove(link)
        tree.links.new(emission.outputs["Emission"], output.inputs["Surface"])
