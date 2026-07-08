class_name HealthBar3D
extends Node3D
## A small world-space health bar: two stacked billboard [QuadMesh] quads
## (background + fill), built procedurally in [method _ready] — the same
## "cheap, boring, no SubViewport" idiom [CombatFx] already uses for floating
## damage numbers, just persistent instead of transient (G4, issue #11).
##
## Cost model: everything here is setup-time (two tiny meshes + materials per
## entity). Steady-state cost is one [method set_fraction] call per hit/heal —
## callers hook it off a `health_changed` signal (see [Player]/[Monster]); this
## class has no [method _process] and does no per-frame work, which is what
## keeps ~10+ live monsters cheap.
##
## Billboard choice: both quads use `BILLBOARD_ENABLED`, not `FIXED_Y`. The
## isometric rig ([CameraRig]) is pitched [constant CameraRig.PITCH_DEGREES]
## (50 deg) off the horizon and never rotates — a `FIXED_Y` quad only yaws to
## face the camera and stays upright, so from a steep fixed pitch it presents
## as a foreshortened sliver. Full `BILLBOARD_ENABLED` tilts the quad to square
## on to the camera exactly like [CombatFx]'s `Label3D` damage numbers already
## do, so the two floating-UI idioms read consistently from this angle.
##
## Depth handling: this bar is parented under [Player]/[Monster], whose
## `look_at()`-driven facing is a pure yaw rotation (`_face()` in both zeroes
## the Y component of the look direction first). The fill quad sits
## [constant FILL_LIFT] above the background in local +Y purely so the two
## coplanar quads don't z-fight; a pure-Y offset is unaffected by a pure-yaw
## parent rotation, so the separation holds no matter which way the body is
## currently facing.

## Full-bar width/height in metres.
const BAR_WIDTH: float = 0.9
const BAR_HEIGHT: float = 0.14
## Local +Y lift the fill quad gets over the background — just enough to win
## the depth test without being visible as a gap from the camera's fixed angle.
const FILL_LIFT: float = 0.01
const BACKGROUND_COLOR: Color = Color(0.05, 0.05, 0.05)
## Default fill tint (monsters); [Player] overrides via [method set_color].
const DEFAULT_FILL_COLOR: Color = Color(0.8, 0.15, 0.15)

var _fill: MeshInstance3D
var _fill_material: StandardMaterial3D
var _fill_color: Color = DEFAULT_FILL_COLOR
## Last fraction passed to [method set_fraction]; read by tests instead of
## reaching into the mesh transform directly.
var _fraction: float = 1.0


func _ready() -> void:
	var background: MeshInstance3D = _make_quad(BACKGROUND_COLOR)
	background.name = "Background"
	add_child(background)

	_fill = _make_quad(_fill_color)
	_fill.name = "Fill"
	_fill.position.y = FILL_LIFT
	add_child(_fill)
	_fill_material = _fill.material_override as StandardMaterial3D
	set_fraction(_fraction)


## Tints the fill quad (e.g. green for the player, red for monsters). Safe to
## call before or after [method _ready] — the color is applied immediately if
## the fill material already exists, and used as the initial color otherwise.
func set_color(color: Color) -> void:
	_fill_color = color
	if _fill_material != null:
		_fill_material.albedo_color = color


## Scales/repositions the fill to [param fraction] of full (clamped 0..1) and
## hides the whole bar at 0 — "empties then hides" (G4 ticket). Call this only
## from a health-changed signal handler, never from [method _process]: with
## ~10+ live monsters, polling every frame would be wasted work for a value
## that only ever moves on a hit or a heal.
func set_fraction(fraction: float) -> void:
	_fraction = clampf(fraction, 0.0, 1.0)
	visible = _fraction > 0.0
	if not visible or _fill == null:
		return
	_fill.scale.x = _fraction
	# The quad is centered at its origin; keep the left edge fixed and let the
	# right edge recede as the fraction shrinks (the usual "drains rightward"
	# health-bar look) rather than shrinking symmetrically from the middle.
	_fill.position.x = -(BAR_WIDTH * 0.5) * (1.0 - _fraction)


## The last fraction passed to [method set_fraction] (1.0 until the first
## call). Scene tests read this instead of poking at mesh transforms.
func current_fraction() -> float:
	return _fraction


func _make_quad(color: Color) -> MeshInstance3D:
	var mesh: QuadMesh = QuadMesh.new()
	mesh.size = Vector2(BAR_WIDTH, BAR_HEIGHT)
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	var instance: MeshInstance3D = MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	return instance
