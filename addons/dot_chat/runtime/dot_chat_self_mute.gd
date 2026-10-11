class_name DotChatSelfMute
extends RefCounted

## A player's own block list: the people whose chat this client does not draw and whose
## voice it does not play. The `sm` ("self mute") command, typed in the console as `sm` or in
## chat as `!sm` or `/sm`.
##
## [codeblock]
## sm              # who is here, numbered, and who is muted
## sm 2            # toggles the second one in that list
## sm ada          # toggles the one player whose name contains "ada"
## sm #14          # toggles the player with userid 14
## [/codeblock]
##
## [b]This client only, and nobody is told.[/b] A moderator's gag is the server's and
## everybody's ([DotChatRouter]'s `dot_mute_source`); this is a preference, like closing
## your ears, so it never crosses the wire: the line `!sm ada` is consumed by the chat box
## before it could be sent, the muted player cannot tell, and the server keeps no list it
## could leak. Lines are dropped before they are drawn; voice frames are dropped before
## they are decoded ([code]DotVoiceManager.set_local_mute[/code]).
##
## [b]One list for the whole process, in the registry as `dot_self_mute`.[/b] The chat box,
## the console, the chat client and every voice manager ask [method shared] for it, so a
## delivered game the shell switches to finds the same list the last game had, and the
## file it is kept in ([member path]) is named for the list, not for any game: inside the
## shell every game shares the shell's `user://`.
##
## [b]Keyed by the server's `key` for a player, with the name as the fallback.[/b] dot-chat
## attributes a line to the session's userid (`sender_key`), which a reconnect changes, so a
## mute keyed by it ends when the muted player presses reconnect. dot-server's scoreboard
## rows carry `key` (a digest of the account, salted per server: see dot-server's
## `player_key`) and `peer`, and this asks for that roster every [member refresh_sec]
## without the player holding Tab. A row without a key (a server before it, a client with
## no server) is matched by name, and an entry made by name is upgraded to the key the
## first time a roster shows that name with one.
##
## [b]Nothing here names dot-server, dot-ui or dot-voice.[/b] The link is the registry's
## `dot_client_link`, read for `scoreboard_received` and `request_scoreboard()`; the voice
## manager is the registry's `dot_voice_client` (bound as it is published), or anything
## handed to [method attach_voice] with `set_local_mute(peer, muted)`. dot-chat keeps its one
## dependency.

const CHANNEL := "chat.self_mute"

## The registry name the shared list is published under.
const SERVICE := &"dot_self_mute"

## Where every consumer that does not name this class loads it from.
const SCRIPT_PATH := "res://addons/dot_chat/runtime/dot_chat_self_mute.gd"

const LINK_SERVICE := &"dot_client_link"

## Where a game's own player's voice manager is published (dot-voice's
## `DotVoiceManager.CLIENT_SERVICE`, by `publish_as_client()`). Bound by name, so neither
## addon loads the other: whichever is built first, the list finds the manager.
const VOICE_SERVICE := &"dot_voice_client"

const DEFAULT_PATH := "user://dot_self_mute.json"

const FORMAT_VERSION := 1

## The list changed: somebody was muted or unmuted, or an entry learned a key or a new name.
signal changed()

## The file the list is kept in. Empty keeps nothing (a suite's own list).
var path: String = DEFAULT_PATH

## Seconds between roster requests while the process runs. A muted player who reconnects
## has a new peer, and their voice plays until the next roster says which one it is.
var refresh_sec: float = 8.0

## The list: `{key, name}`, one per muted player. `key` is empty for one known only by name.
var entries: Array[Dictionary] = []

## The last roster the server sent: `{id, name, key, peer, bot}` per player.
var roster: Array[Dictionary] = []

## This client's own userid, from the roster's `you`. Never listed: muting yourself is a
## way to find out the command works and then wonder where your chat went.
var you: int = 0

## The client link to read the roster from. Null asks the registry each time.
var link: Object = null

var _watched: WeakRef = null
var _voices: Array[WeakRef] = []
## voice manager instance id -> {peer: true} this list muted on it, so an unmute undoes
## exactly what this did and nothing a game muted itself.
var _voice_muted: Dictionary = {}
## The rows the last list numbered, so `sm 2` means what the player just read.
var _listed: Array[Dictionary] = []
var _ticking: bool = false


## The process's list: the registered one, or a new one loaded from [member path],
## registered, and asking for rosters.
##
## Returns an [Object], not this class: a list registered by another build of this script (a
## delivered pack's overlay) is still the list, and every caller duck-types it.
static func shared() -> Object:
	var existing: Object = DotRegistry.get_service(SERVICE)
	if existing != null:
		return existing

	var made := DotChatSelfMute.new()
	made.load_list()
	DotRegistry.register(SERVICE, made)
	made.watch()
	return made


# --- Persistence ---------------------------------------------------------------

func load_list() -> void:
	entries.clear()
	if path == "" or not FileAccess.file_exists(path):
		return

	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary) or not ((parsed as Dictionary).get("entries") is Array):
		DotLog.warn(CHANNEL, "the self-mute list could not be read; starting empty", {"path": path})
		return

	for raw in (parsed as Dictionary)["entries"]:
		if raw is Dictionary:
			var key := str((raw as Dictionary).get("key", ""))
			var name := str((raw as Dictionary).get("name", ""))
			if key != "" or name != "":
				entries.append({"key": key, "name": name})


func save_list() -> void:
	if path == "":
		return

	var _made := DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		DotLog.warn(CHANNEL, "the self-mute list could not be saved", {
			"path": path, "error": error_string(FileAccess.get_open_error()),
		})
		return

	file.store_string(JSON.stringify({"version": FORMAT_VERSION, "entries": entries}, "\t"))
	file.close()
	# A browser's user:// is an IndexedDB mirror: unflushed, a reload forgets the list.
	DotWeb.sync_filesystem()


# --- The roster ----------------------------------------------------------------

## Starts asking for rosters, once, for as long as the process runs, and binds the player's
## voice manager whenever one is published.
func watch() -> void:
	_watch_link()
	var bus := DotRegistry.signals()
	if not bus.service_registered.is_connected(_on_service_registered):
		bus.service_registered.connect(_on_service_registered)
	var voice: Object = DotRegistry.get_service(VOICE_SERVICE)
	if voice != null:
		attach_voice(voice)
	if _ticking:
		return
	_ticking = true
	_tick()


func _on_service_registered(service: StringName, instance: Object) -> void:
	if service == VOICE_SERVICE and instance != null:
		attach_voice(instance)
	elif service == LINK_SERVICE:
		var _l := _watch_link()


func _tick() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or refresh_sec <= 0.0:
		_ticking = false
		return
	refresh()
	var _c := tree.create_timer(refresh_sec, true).timeout.connect(_tick)


## Asks the server for one roster, if there is a server to ask.
func refresh() -> void:
	var current := _watch_link()
	if current != null and current.has_method(&"request_scoreboard"):
		var _sent: Variant = current.call(&"request_scoreboard")


## Connects to the link, again whenever it is a different one. The shell's link outlives
## every game; a game run alone publishes its own.
func _watch_link() -> Object:
	var current: Object = link if link != null else DotRegistry.get_service(LINK_SERVICE)
	if current == null or not is_instance_valid(current):
		return null

	var previous: Object = _watched.get_ref() if _watched != null else null
	if previous == current:
		return current

	_watched = weakref(current)
	if current.has_signal(&"scoreboard_received") \
			and not current.is_connected(&"scoreboard_received", _on_board):
		var _c := current.connect(&"scoreboard_received", _on_board)
	# A new game is a new set of peers to a server that kept everybody's session.
	for signal_name: StringName in [&"spawned", &"game_changed"]:
		if current.has_signal(signal_name) and not current.is_connected(signal_name, _on_rejoined):
			var _c := current.connect(signal_name, _on_rejoined)

	var held: Variant = current.get(&"scoreboard")
	if held is Dictionary and not (held as Dictionary).is_empty():
		_on_board(held as Dictionary)
	return current


func _on_rejoined(_a: Variant = null, _b: Variant = null, _c: Variant = null) -> void:
	refresh()


func _on_board(snapshot: Dictionary) -> void:
	var rows: Variant = snapshot.get("players", [])
	set_roster(rows if rows is Array else [], int(snapshot.get("you", 0)))


## Takes a roster: dot-server's scoreboard rows, or a game's own with the same keys.
func set_roster(rows: Array, your_id: int = 0) -> void:
	roster.clear()
	you = your_id
	for raw in rows:
		if not (raw is Dictionary):
			continue
		var row := raw as Dictionary
		roster.append({
			"id": int(row.get("id", 0)),
			"name": str(row.get("name", "")),
			"key": str(row.get("key", "")),
			"peer": int(row.get("peer", 0)),
			"bot": bool(row.get("bot", false)),
		})

	var learned := false
	for entry in entries:
		for row in roster:
			if entry["key"] == "" and row["key"] != "" and row["name"] == entry["name"]:
				# Muted by name before the server said who that was: from now on it is the
				# person, and a rename does not unmute them.
				entry["key"] = row["key"]
				learned = true
			elif entry["key"] != "" and row["key"] == entry["key"] and row["name"] != entry["name"]:
				# The same person under a new name: the name is the fallback on a server
				# with no keys, so it is kept current.
				entry["name"] = row["name"]
				learned = true

	if learned:
		save_list()
		changed.emit()

	_apply_voices()


# --- Asking ----------------------------------------------------------------------

## Whether a line said by [param name] should be dropped. [param sender] is the line's
## sender key (dot-chat's `s`, the userid) when it has one: the roster row it names
## decides, and without one the row with that name does.
func is_muted(name: String, sender: String = "") -> bool:
	if entries.is_empty():
		return false

	var row := _row_for(sender, name)
	if row.is_empty():
		return _name_muted(name)
	return _row_muted(row)


## [method is_muted] for a dot-chat wire line: `{d: name, s: sender, m: text}`.
func is_muted_line(wire: Dictionary) -> bool:
	return is_muted(str(wire.get("d", "")), str(wire.get("s", "")))


func _row_for(sender: String, name: String) -> Dictionary:
	if sender.is_valid_int():
		var id := int(sender)
		for row in roster:
			# The name must agree too: a game whose sender key is its own player number
			# rather than dot-server's userid would otherwise land on somebody else's row.
			if row["id"] == id and (name == "" or row["name"] == name):
				return row
	if name == "":
		return {}
	for row in roster:
		if row["name"] == name:
			return row
	return {}


func _row_muted(row: Dictionary) -> bool:
	var key: String = row["key"]
	for entry in entries:
		if key != "" and entry["key"] == key:
			return true
		# A keyed row is a known person: a keyed entry with the same name and another key is
		# somebody else (or this person on another server), and is not them.
		if entry["name"] == row["name"] and (entry["key"] == "" or key == ""):
			return true
	return false


func _name_muted(name: String) -> bool:
	if name == "":
		return false
	for entry in entries:
		if entry["name"] == name:
			return true
	return false


# --- Changing ----------------------------------------------------------------------

## Mutes or unmutes one player. [param who] is a roster row or `{key, name}`.
func set_muted(who: Dictionary, muted: bool) -> void:
	var key := str(who.get("key", ""))
	var name := str(who.get("name", ""))
	var was := _row_muted({"key": key, "name": name})

	if muted == was:
		return

	if muted:
		entries.append({"key": key, "name": name})
	else:
		var kept: Array[Dictionary] = []
		for entry in entries:
			var same: bool = (key != "" and entry["key"] == key) \
				or (entry["name"] == name and (entry["key"] == "" or key == ""))
			if not same:
				kept.append(entry)
		entries = kept

	DotLog.debug(CHANNEL, "muted" if muted else "unmuted", {"keyed": key != ""})
	save_list()
	_apply_voices()
	changed.emit()


## Flips one player and returns whether they are muted now.
func toggle(who: Dictionary) -> bool:
	var now := not _row_muted({"key": str(who.get("key", "")), "name": str(who.get("name", ""))})
	set_muted(who, now)
	return now


# --- The command -------------------------------------------------------------------

## Whether a line typed in CHAT is this command: `!sm` or `/sm`, alone or with an argument.
## A bare `sm` in chat is a word somebody said, so only the prefixed forms are claimed.
func claims_chat(text: String) -> bool:
	var trimmed := text.strip_edges().to_lower()
	if not (trimmed.begins_with("!") or trimmed.begins_with("/")):
		return false
	var body := trimmed.substr(1)
	return body == "sm" or body.begins_with("sm ") or body.begins_with("sm\t")


## Runs a chat line [method claims_chat] claimed, and returns what to show the player.
func handle_chat(text: String) -> PackedStringArray:
	var body := text.strip_edges().substr(1).strip_edges()
	var parts := body.split(" ", false)
	parts.remove_at(0)
	return run(parts)


## The command itself: no argument lists, one argument toggles. Returns the lines to show.
func run(args: PackedStringArray) -> PackedStringArray:
	refresh()

	var query := " ".join(args).strip_edges()
	if query == "":
		return list_lines()

	var found := resolve(query)
	if found.has("error"):
		return PackedStringArray([str(found["error"])])
	if found.has("several"):
		var out := PackedStringArray([
			"%d players match \"%s\". Type more of the name, or sm and a number:" % [
				(found["several"] as Array).size(), query,
			]
		])
		_listed.clear()
		for row: Dictionary in found["several"]:
			_listed.append(row)
			out.append(_line_for(_listed.size(), row))
		return out

	var row: Dictionary = found["row"]
	if toggle(row):
		return PackedStringArray([
			"Muted %s: chat and voice, for you only." % row["name"]
		])
	return PackedStringArray(["Unmuted %s." % row["name"]])


## Who [param query] means: `{row}`, `{several: [rows]}` or `{error}`.
##
## `#14` is a userid; a bare number is a line of the last list; anything else is a name,
## whole first and then any part of one, ignoring case, and a part must be unique.
func resolve(query: String) -> Dictionary:
	var candidates := _candidates()

	if query.begins_with("#") and query.substr(1).is_valid_int():
		var id := int(query.substr(1))
		for row in candidates:
			if row.get("id", 0) == id and not row.get("absent", false):
				return {"row": row}
		return {"error": "Nobody here has userid #%d. Type sm for the list." % id}

	if query.is_valid_int():
		if _listed.is_empty():
			_listed = _sorted(candidates)
		var index := int(query)
		if index >= 1 and index <= _listed.size():
			return {"row": _listed[index - 1]}

	var lower := query.to_lower()
	var whole: Array[Dictionary] = []
	var part: Array[Dictionary] = []
	for row in candidates:
		var name := str(row["name"]).to_lower()
		if name == lower:
			whole.append(row)
		elif name.contains(lower):
			part.append(row)

	if whole.size() == 1:
		return {"row": whole[0]}
	if whole.size() > 1:
		return {"several": whole}
	if part.size() == 1:
		return {"row": part[0]}
	if part.size() > 1:
		return {"several": _sorted(part)}
	return {"error": "Nobody here matches \"%s\". Type sm for the list." % query}


## The numbered list `sm` prints, and remembers for `sm <number>`.
func list_lines() -> PackedStringArray:
	_listed = _sorted(_candidates())

	if _listed.is_empty():
		if _watch_link() != null and roster.is_empty():
			return PackedStringArray(["Asking the server who is here; type sm again in a moment."])
		return PackedStringArray(["Nobody else is here, and nobody is muted."])

	var out := PackedStringArray([
		"Self mute, yours only. sm <n | name | #id> toggles:",
	])
	for i in _listed.size():
		out.append(_line_for(i + 1, _listed[i]))
	return out


func _line_for(number: int, row: Dictionary) -> String:
	var tags := PackedStringArray()
	if row.get("absent", false):
		tags.append("not here")
	elif int(row.get("id", 0)) > 0:
		tags.append("#%d" % int(row["id"]))
	var state := "MUTED" if _row_muted(row) else ""
	return ("  %2d. %-24s %-10s %s" % [number, row["name"], " ".join(tags), state]).strip_edges(false, true)


## Everybody who could be muted or unmuted: the roster but yourself and the bots, then
## every muted entry nobody in it answers to, so a player who left can still be unmuted.
func _candidates() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for row in roster:
		if row["bot"] or (you != 0 and row["id"] == you) or str(row["name"]) == "":
			continue
		out.append(row)

	for entry in entries:
		var present := false
		for row in out:
			if _same(entry, row):
				present = true
				break
		if not present:
			out.append({"id": 0, "name": entry["name"], "key": entry["key"], "peer": 0, "absent": true})
	return out


func _same(entry: Dictionary, row: Dictionary) -> bool:
	if entry["key"] != "" and row["key"] != "":
		return entry["key"] == row["key"]
	return entry["name"] == row["name"]


func _sorted(rows: Array[Dictionary]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	out.assign(rows)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if bool(a.get("absent", false)) != bool(b.get("absent", false)):
			return not bool(a.get("absent", false))
		return str(a["name"]).naturalnocasecmp_to(str(b["name"])) < 0)
	return out


# --- Voice -------------------------------------------------------------------------

## Hands a voice manager this list: every muted player in the roster with a peer is muted on
## it now, and again whenever the list or the roster changes. Kept weakly; idempotent.
func attach_voice(manager: Object) -> void:
	if manager == null or not manager.has_method(&"set_local_mute"):
		return
	for ref in _voices:
		if ref.get_ref() == manager:
			_apply_voice(manager)
			return
	_voices.append(weakref(manager))
	_apply_voice(manager)


func _apply_voices() -> void:
	var alive: Array[WeakRef] = []
	for ref in _voices:
		var manager: Object = ref.get_ref()
		if manager != null and is_instance_valid(manager):
			alive.append(ref)
			_apply_voice(manager)
	_voices = alive


func _apply_voice(manager: Object) -> void:
	var wanted := {}
	for row in roster:
		if row["peer"] != 0 and _row_muted(row):
			wanted[row["peer"]] = true

	var id := manager.get_instance_id()
	var before: Dictionary = _voice_muted.get(id, {})
	for peer in before:
		if not wanted.has(peer):
			manager.call(&"set_local_mute", peer, false)
	for peer in wanted:
		if not before.has(peer):
			manager.call(&"set_local_mute", peer, true)
	_voice_muted[id] = wanted


## The peers this list has muted on voice right now.
func muted_peers() -> PackedInt32Array:
	var out := PackedInt32Array()
	for row in roster:
		if row["peer"] != 0 and _row_muted(row):
			out.append(row["peer"])
	return out


func describe() -> Dictionary:
	return {
		"muted": entries.size(),
		"roster": roster.size(),
		"voices": _voices.size(),
		"voice_muted": muted_peers().size(),
		"path": path,
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray(["self mute: %d muted, %d in the roster" % [entries.size(), roster.size()]])
	for entry in entries:
		out.append("  %s%s" % [entry["name"], "" if entry["key"] != "" else " (by name)"])
	return out
