class_name XPBar
extends CanvasLayer
## The G3 XP bar: a bottom-of-screen readout of the current level and fill
## toward the next one (docs/0017).
##
## Adapter (ADR 0003): a dumb view over the player's level/XP, the same idiom
## as [InventoryPanel] — every redraw reads [Player.xp_progress]/[Player.level]
## fresh off the player's `xp_changed` signal, no progression state lives here.
## Display only: the ticket calls mouse/touch irrelevant, and this panel has no
## buttons to consume clicks (unlike InventoryPanel/SaveUI).

var _player: Player

@onready var _bar: ProgressBar = $Panel/Margin/Layout/Bar
@onready var _level_label: Label = $Panel/Margin/Layout/LevelLabel


## Binds the bar to [param player]. Called by main once the scene is composed.
func setup(player: Player) -> void:
	_player = player
	player.xp_changed.connect(_refresh)
	_refresh()


## Redraws from the player's current level/XP — see [ProgressionCurve.progress_for_total_xp]
## for the Dictionary shape. At `max_level` (`xp_to_next_level` is 0 by
## contract) the bar reads as full rather than dividing by zero.
func _refresh() -> void:
	if _player == null:
		return
	var progress: Dictionary = _player.xp_progress()
	var level: int = int(progress.get("level", _player.level()))
	var max_level: int = int(progress.get("max_level", level))
	var xp_into_level: int = int(progress.get("xp_into_level", 0))
	var xp_to_next_level: int = int(progress.get("xp_to_next_level", 0))
	if xp_to_next_level <= 0:
		_level_label.text = "Level %d (max)" % level if level >= max_level else "Level %d" % level
		_bar.max_value = 1.0
		_bar.value = 1.0
		return
	_level_label.text = "Level %d" % level
	_bar.max_value = float(xp_to_next_level)
	_bar.value = float(xp_into_level)
