class_name GroundDrop
extends StaticBody3D
## One item lying on the ground, waiting to be picked up.
##
## Adapter (ADR 0003): holds the rolled-item Dictionary [LootRoller] produced and
## displays it — a small rarity-tinted marker plus a named [Label3D]. No rules here;
## picking it up is the player's business.
##
## Picking follows the ADR 0010 pattern: this body sits alone on physics layer 3
## (`collision_layer = 4`) with no collision mask, so the click raycast in main.gd
## can find drops while bodies and the navmesh bake (which parsed the map's static
## colliders long before any drop spawns) never interact with them.

var _item: Dictionary = {}

@onready var _body: MeshInstance3D = $Body
@onready var _name_label: Label3D = $NameLabel


## Hands over the rolled item and paints the drop. Call after add_child, like
## Monster.setup.
func setup(item: Dictionary) -> void:
	_item = item
	var tint: Color = RarityColors.color_of(String(item.get("rarity", "normal")))
	_name_label.text = String(item.get("name", "?"))
	_name_label.modulate = tint
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = tint
	material.roughness = 1.0
	_body.material_override = material


## The rolled item this drop carries (see LootRoller for the shape).
func item() -> Dictionary:
	return _item
