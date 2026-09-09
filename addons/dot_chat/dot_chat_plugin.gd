@tool
extends EditorPlugin

## Editor entry point for dot-chat. Registers inspector types only.
##
## No autoloads. A process running a listen server holds a router and a client at
## once, and an autoload could be neither twice.

const _ICON := "res://addons/dot_chat/icon_placeholder.svg"

const _TYPES := [
	["DotChatRouter", "Node", "res://addons/dot_chat/runtime/dot_chat_router.gd"],
	["DotChatClient", "Node", "res://addons/dot_chat/runtime/dot_chat_client.gd"],
]


func _enter_tree() -> void:
	var icon: Texture2D = null
	if ResourceLoader.exists(_ICON):
		icon = load(_ICON) as Texture2D

	for entry in _TYPES:
		add_custom_type(entry[0], entry[1], load(entry[2]), icon)


func _exit_tree() -> void:
	for entry in _TYPES:
		remove_custom_type(entry[0])
