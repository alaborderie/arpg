class_name RarityColors
extends RefCounted
## Rarity -> display tint, shared by the ground-drop label and the inventory UI.
##
## Scene-layer constants on purpose: which rarities *exist* (weights, affix counts)
## is balance data in `shared/loot_tables.json`; what colour they glow is pure
## presentation, so it lives with the rendering code (ADR 0005 cuts both ways).

const _COLORS: Dictionary = {
	"normal": Color(0.92, 0.92, 0.92),
	"magic": Color(0.5, 0.62, 1.0),
	"rare": Color(1.0, 0.84, 0.3),
}


## The tint for [param rarity]; unknown rarities render white rather than crash.
static func color_of(rarity: String) -> Color:
	var color: Color = _COLORS.get(rarity, Color.WHITE)
	return color
