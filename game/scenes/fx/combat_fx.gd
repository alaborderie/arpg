class_name CombatFx
extends RefCounted
## Small hit-feedback helpers shared by every combatant scene.
##
## Scene-layer code (ADR 0003): this builds Nodes and tweens. It holds no game
## rules — it only *displays* a [DamageResult] the domain already produced.
## Deliberately low-poly-appropriate: a floating [Label3D] number and a brief
## white material flash, no particles or shaders.

## How long a hit flash stays on the mesh, in seconds.
const FLASH_SECONDS: float = 0.08
## How far up a damage number drifts before it fades out, in metres.
const NUMBER_RISE: float = 1.2
## Lifetime of a damage number, in seconds.
const NUMBER_SECONDS: float = 0.7
const NUMBER_COLOR: Color = Color(1.0, 1.0, 1.0)
const NUMBER_CRIT_COLOR: Color = Color(1.0, 0.85, 0.3)

static var _flash_material: StandardMaterial3D


## Spawns a floating damage number at [param world_position]. The label is parented
## to [param parent] (not to the victim) so it outlives a victim freed by the hit.
static func spawn_damage_number(parent: Node, world_position: Vector3, result: DamageResult) -> void:
	var label: Label3D = Label3D.new()
	label.text = ("%d!" % result.amount) if result.is_critical else str(result.amount)
	label.modulate = NUMBER_CRIT_COLOR if result.is_critical else NUMBER_COLOR
	label.font_size = 96 if result.is_critical else 64
	label.outline_size = 18
	label.pixel_size = 0.01
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	parent.add_child(label)
	label.global_position = world_position
	var tween: Tween = label.create_tween()
	tween.set_parallel(true)
	tween.tween_property(label, "position:y", label.position.y + NUMBER_RISE, NUMBER_SECONDS)
	tween.tween_property(label, "modulate:a", 0.0, NUMBER_SECONDS)
	tween.chain().tween_callback(label.queue_free)


## Flashes every mesh in [param meshes] white, same as [method flash] called once
## per mesh. G5's low-poly character/monster bodies are several stacked
## [MeshInstance3D] parts (legs, torso, head, ...) rather than one capsule, so a
## hit needs to flash the whole silhouette at once — each part still tracks and
## restores its own original material independently, so this is exactly
## equivalent to (and no more expensive than) calling [method flash] in a loop.
static func flash_all(meshes: Array) -> void:
	for mesh: Variant in meshes:
		if mesh is MeshInstance3D:
			flash(mesh as MeshInstance3D)


## Flashes [param mesh] white for [constant FLASH_SECONDS], then restores whatever
## material override it had. Reentrant: a flash landing during a flash is a no-op
## (the running one restores the true original).
static func flash(mesh: MeshInstance3D) -> void:
	var flash_mat: StandardMaterial3D = _get_flash_material()
	if mesh.material_override == flash_mat:
		return
	var original: Material = mesh.material_override
	mesh.material_override = flash_mat
	var tween: Tween = mesh.create_tween()
	tween.tween_interval(FLASH_SECONDS)
	tween.tween_callback(func() -> void: mesh.material_override = original)


static func _get_flash_material() -> StandardMaterial3D:
	if _flash_material == null:
		_flash_material = StandardMaterial3D.new()
		_flash_material.albedo_color = Color(1.0, 1.0, 1.0)
		_flash_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return _flash_material
