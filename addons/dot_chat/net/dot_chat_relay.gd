@tool
class_name DotChatRelay
extends Node

## The other half of a conversation: the website's chat room and the match's, joined.
##
## A player on a web page and a player in the match cannot see each other. The site has a
## room per server — `LiveChatScope.GAME`, which its own model calls "relayed in-game
## chat" — and the game has [DotChatRouter], and until this existed neither had ever said
## a word to the other. This carries lines both ways and, optionally, lets a line typed on
## the site run as a console command.
##
## [codeblock]
## var relay := DotChatRelay.new()
## relay.router = chat_router
## relay.client = backbone_client          # dot-auth's DotBackboneClient, duck-typed
## relay.config = my_relay_config
## relay.command_fn = _run_console_command
## relay.permission_fn = admins.uid_has_permission
## add_child(relay)
## [/codeblock]
##
## [b]The backbone client is held as an [Object] and never named.[/b] dot-chat depends on
## dot-core and nothing else — a script that so much as MENTIONS [code]DotBackboneClient[/code]
## fails to compile in a project without dot-auth installed, which is most of them. Same
## reasoning, and the same shape, as [code]DotStatsReporter[/code]. The contract is two
## methods:
##
## [codeblock]
## func post_integration(path: String, body: Dictionary) -> DotResult
## func get_integration(path: String, query: Dictionary) -> DotResult
## [/codeblock]
##
## [b]Nothing here decides a permission.[/b] A relayed command is resolved to a uid and
## handed to the host's own [member permission_fn] — the server's admin manager, the same
## one a connected player goes through. A relay that carried its own permission model
## would be a second answer to "may this person do this", and the two would drift.

const CHANNEL := "chat.relay"
const SERVICE := &"dot_chat_relay"

## Where the two halves of the loop live on the backbone.
##
## [b]Written once, here.[/b] Two copies of a path is the bug this family has shipped in
## four shell scripts and three vendoring lists.
const PATH_POST := "chat"
const PATH_OUTBOUND := "chat/outbound"

## Where the command list is published, so a site composer can offer it.
const PATH_COMMANDS := "chat/commands"

const DEFAULT_CURSOR_PATH := "user://dot_chat_relay_cursor.json"

## A line arrived from the website and was announced in game.
signal site_line(author: String, author_uid: String, text: String)

## A line from the website was a command, and was run.
##
## [param allowed] is what the host's permission check answered. Emitted either way, so a
## refusal is visible to an audit log rather than only to whoever typed it.
signal site_command(author_uid: String, command: String, allowed: bool)

## A batch reached the site, or failed to.
signal delivered(count: int, ok: bool)

## The router this is joined to. Required.
@export var router: DotChatRouter = null

@export var config: DotChatRelayConfig = null

## Registry name, or empty not to register.
@export var register_as: StringName = SERVICE

## The backbone client. Any object with `post_integration` and `get_integration`.
var client: Object = null

## Builds a server uid from a site user id. Replaceable for a non-TMC deployment.
##
## Defaults to [member DotChatRelayConfig.author_uid_prefix] plus the id. A deployment
## whose mapping is not a prefix — a lookup table, a hash — assigns its own.
var uid_for_author: Callable = Callable()

## Runs a console command as somebody.
##
## `(uid: String, command: String, args: PackedStringArray, source: int)` — the source is
## [member DotChatRelayConfig.command_source], passed through rather than decided here.
##
## [b]A callable rather than a reference to a console.[/b] dot-chat does not depend on
## dot-server and must not: the games that use one use both, and the two that do not are
## the reason this is a seam.
var command_fn: Callable = Callable()

## Asks whether a uid holds a flag. `(uid: String, flag: String) -> bool`.
##
## Pointed at `DotAdminManager.uid_has_permission` in every game here, which is the method
## that already exists for exactly this question — deciding what somebody may do when they
## are not connected.
var permission_fn: Callable = Callable()

## The flag a relayed command requires before it is even attempted.
##
## [b]Its own flag, not the command's.[/b] The command's own permission is checked by the
## console as usual; this one asks a different question first — may this person drive this
## server from a web page at all — and an operator wants to be able to answer no to that
## without revoking anybody's in-game rights.
var command_flag: String = "rcon"

## `() -> Array[Dictionary]`, each `{name, usage, description, chat_allowed, permission}`.
##
## Re-read on every [method publish_commands] rather than captured, because the answer
## changes when a module loads: a callable that closed over a list would publish the table
## as it was at boot, for ever.
var commands_fn: Callable = Callable()

var _commands_published: int = 0
var _started: bool = false
var _queue: Array[Dictionary] = []
var _cursor: String = ""
var _timer: Timer = null
var _sending: bool = false
var _polling: bool = false

## True while this relay is announcing a line it received. See _on_message_accepted.
var _announcing: bool = false
var _dropped: int = 0
var _sent: int = 0
var _received: int = 0
var _failures: int = 0
var _last_error: String = ""


func _ready() -> void:
	if Engine.is_editor_hint():
		return
	start()


func _exit_tree() -> void:
	if register_as != &"" and DotRegistry.get_service(register_as) == self:
		DotRegistry.unregister(register_as)


func start() -> DotResult:
	if _started:
		return DotResult.success(self)

	if config == null:
		config = DotChatRelayConfig.new()

	var valid := config.validate()
	if not valid.ok:
		return valid.wrap("The chat relay configuration is not usable")

	if not config.enabled:
		# Not an error, and deliberately quiet. A server with no credential is the
		# commonest deployment there is, and a warning on every boot about a feature
		# nobody asked for is the shape this family calls "a setting nobody filled in".
		DotLog.debug(CHANNEL, "the chat relay is disabled")
		_started = true
		return DotResult.success(self)

	if router == null:
		return DotResult.fail(
			DotError.CODE_STATE, "The chat relay needs a DotChatRouter."
		)

	if client == null:
		return DotResult.fail(
			DotError.CODE_STATE,
			"The chat relay is enabled but has no backbone client."
		)

	if not uid_for_author.is_valid():
		uid_for_author = _default_uid_for_author

	_load_cursor()

	if config.send_game_chat:
		if not router.message_accepted.is_connected(_on_message_accepted):
			router.message_accepted.connect(_on_message_accepted)

	if config.receive_site_chat:
		_timer = Timer.new()
		_timer.name = "RelayPoll"
		_timer.wait_time = config.poll_seconds
		_timer.autostart = true
		_timer.timeout.connect(_on_poll)
		add_child(_timer)

	if register_as != &"":
		DotRegistry.register(register_as, self)

	_started = true

	# Published once at start, and again whenever the host says the table changed. It is
	# fire-and-forget on purpose: a site that cannot be told what this server accepts is a
	# site whose command MENU is empty, which is a worse autocomplete and not a broken
	# server -- so a failure here must never stop the relay that carries the chat itself.
	if config.publish_commands:
		publish_commands()

	DotLog.info(CHANNEL, "chat relay started", {
		"poll": config.poll_seconds,
		"commands": config.allow_commands,
		"cursor": _cursor if _cursor != "" else "(none)",
	})

	return DotResult.success(self)


# --- What this server accepts ----------------------------------------------

## Tells the site which commands it may offer when somebody types the prefix.
##
## [b]The list has to come from here because only here has it.[/b] A member typing `/` on a
## web page is typing at a machine the site does not control, whose command table depends on
## which game is loaded and which modules an operator installed -- so a list held by the site
## would be stale the first time either changed. Call it again after loading or unloading a
## module; [member commands_fn] is re-read every time.
##
## [b]Nothing published here is a permission.[/b] What a person may actually run is decided
## here, per line, by [member permission_fn] against this server's own admin file. This
## decides only what is worth OFFERING -- and offering something that will always be refused
## teaches people the site is broken, which is why the chat-allowed flag travels with it.
func publish_commands() -> void:
	if not _started and not config.enabled:
		return
	if client == null or not commands_fn.is_valid():
		return

	var listed: Variant = commands_fn.call()
	if not (listed is Array):
		DotLog.warn(CHANNEL, "commands_fn did not answer with an array", {
			"got": type_string(typeof(listed)),
		})
		return

	var rows: Array[Dictionary] = []
	for entry: Variant in listed as Array:
		if entry is Dictionary:
			rows.append(entry as Dictionary)

	var res: Variant = await client.call(
		"post_integration", PATH_COMMANDS, {"commands": rows}
	)
	var result := res as DotResult

	if result == null or not result.ok:
		# Info, not a warning. A deployment whose backbone has no such endpoint -- an older
		# site, or one that never enabled the feature -- would otherwise print a red line
		# every time a module loaded, and a red line about a condition that is normal is how
		# a real one stops being read.
		DotLog.info(CHANNEL, "the command list was not published", {
			"why": str(result.error) if result != null else "no result",
		})
		return

	_commands_published = rows.size()
	DotLog.debug(CHANNEL, "published the command list", {"count": rows.size()})


# --- Game -> site ----------------------------------------------------------

func _on_message_accepted(
	message: DotChatMessage, _recipients: PackedInt32Array
) -> void:
	if not config.enabled or not config.send_game_chat:
		return

	# [b]The line we are announcing right now is not a line to send back.[/b]
	# `announce_from` dispatches a relayed line as an ordinary SAY — which is right, it
	# is something a person said and should read like one — and `message_accepted` fires
	# synchronously inside it, so without this guard every message from the website is
	# posted straight back to the website.
	#
	# The site would not have looped for ever: its outbound half returns only USER-kind
	# rows and what this posts becomes GAME-kind. It would simply have shown every web
	# line twice, the second copy attributed to the game — which is worse than a loop,
	# because a loop is obvious and this looks like a display bug.
	#
	# A flag rather than matching on the sender key: a person signed into the website AND
	# playing on the server has the same uid in both places, and keying on that would
	# silently stop relaying the in-game lines of every admin who left a tab open.
	if _announcing:
		return

	# Only what a PLAYER said. The server's own announcements are the join and leave
	# notices, the vote prompts and the map changes — a running commentary nobody on a
	# web page asked for, and the relayed lines this addon itself announces are among
	# them, which would be a loop.
	if message.kind != DotChatMessage.Kind.SAY \
			and message.kind != DotChatMessage.Kind.ACTION:
		return

	# A whisper is addressed to one person and a team line to one team. Neither is a
	# thing to publish to a website where the audience rule does not exist.
	if message.channel != router.default_channel():
		return

	if message.text.strip_edges() == "":
		return

	_enqueue({
		"player": {"name": message.sender_name, "gameId": message.sender_key},
		"body": message.text,
		"ts": message.sent_at,
	})


func _enqueue(row: Dictionary) -> void:
	if config.server_id > 0:
		row["serverId"] = config.server_id

	_queue.append(row)

	# Bounded, oldest-first. See max_queued: a server that cannot reach the backbone
	# must not grow an array until it dies for the sake of chat.
	while _queue.size() > config.max_queued:
		_queue.pop_front()
		_dropped += 1

	_flush()


func _flush() -> void:
	if _sending or _queue.is_empty() or client == null:
		return
	_send_batch()


func _send_batch() -> void:
	_sending = true

	var batch: Array[Dictionary] = []
	while not _queue.is_empty() and batch.size() < config.send_batch:
		batch.append(_queue.pop_front())

	for row in batch:
		var res: Variant = await client.call("post_integration", PATH_POST, row)
		var result := res as DotResult

		if result == null or not result.ok:
			_failures += 1
			_last_error = result.error.message if result != null else "no result"

			# Put it back at the FRONT, in order. A failed line is not a dropped one
			# unless the queue is full, and the queue's own bound is what decides that
			# — two policies for one question is how a bounded queue becomes unbounded.
			_queue.push_front(row)
			delivered.emit(0, false)
			_sending = false
			return

		_sent += 1

	delivered.emit(batch.size(), true)
	_sending = false

	if not _queue.is_empty():
		_flush()


# --- Site -> game ----------------------------------------------------------

func _on_poll() -> void:
	if _polling or client == null or not config.enabled:
		return
	_poll()


func _poll() -> void:
	_polling = true

	var query := {"limit": config.poll_limit}
	if _cursor != "":
		query["since"] = _cursor

	var res: Variant = await client.call("get_integration", PATH_OUTBOUND, query)
	var result := res as DotResult

	if result == null or not result.ok:
		_failures += 1
		_last_error = result.error.message if result != null else "no result"
		_polling = false
		return

	var body: Variant = result.value

	if typeof(body) != TYPE_DICTIONARY:
		_polling = false
		return

	var doc: Dictionary = body
	var rows: Variant = doc.get("messages", [])

	if typeof(rows) == TYPE_ARRAY:
		for row in (rows as Array):
			if typeof(row) == TYPE_DICTIONARY:
				_deliver(row as Dictionary)

	# The endpoint's own `newest`, not the last row we happened to process. A row this
	# server chose to skip — a muted one — is still a row it has SEEN, and leaving the
	# cursor behind it means every poll from here on re-fetches and re-skips it for ever.
	var newest: Variant = doc.get("newest", null)

	if typeof(newest) == TYPE_STRING and str(newest) != "":
		_set_cursor(str(newest))

	_polling = false


func _deliver(row: Dictionary) -> void:
	var text := str(row.get("body", "")).strip_edges()

	if text == "":
		return

	if config.skip_muted and bool(row.get("muted", false)):
		return

	var author := str(row.get("author", ""))
	var author_id_value: Variant = row.get("authorId", null)
	var author_id := "" if author_id_value == null else str(author_id_value)
	var uid := "" if author_id == "" else str(uid_for_author.call(author_id))

	_received += 1

	# A command, if the host allows one and the line opens with a prefix.
	var prefix := ""
	if router.rules != null:
		prefix = router.rules.command_prefix_of(text)

	if prefix != "":
		_handle_command(uid, author, text, prefix)
		return

	var label := "[%s] %s" % [config.web_tag, author if author != "" else "web"]
	_announcing = true
	var announced := router.announce_from(
		text, label, uid, config.channel, DotChatMessage.Kind.SAY
	)
	_announcing = false

	if not announced.ok:
		DotLog.warn(CHANNEL, "a relayed line could not be announced", {
			"why": announced.error.message,
		})
		return

	site_line.emit(author, uid, text)


func _handle_command(
	uid: String, author: String, text: String, prefix: String
) -> void:
	var body := text.substr(prefix.length()).strip_edges()

	if body == "":
		return

	var parts := body.split(" ", false)
	var command := str(parts[0])
	var args := PackedStringArray()

	for i in range(1, parts.size()):
		args.append(str(parts[i]))

	if not config.allow_commands:
		site_command.emit(uid, command, false)
		return

	if uid == "" and config.require_known_author:
		DotLog.warn(CHANNEL, "a relayed command had no identifiable author", {
			"command": command, "author": author,
		})
		site_command.emit(uid, command, false)
		return

	# The SERVER's answer, always. This relay knows nothing about who may do what and
	# must not learn: the host's admin manager already answers this for connected
	# players, and a second answer here is a second thing to keep in step.
	var allowed := true

	if permission_fn.is_valid():
		allowed = bool(permission_fn.call(uid, command_flag))

	if not allowed:
		# The uid is in the line, and that is the point rather than an aside. An operator
		# setting this up has no other way to learn what a site member's uid IS -- it is
		# derived from a database id they cannot see -- so the first refusal is what tells
		# them which key to add to the admin file. Without that, granting the first admin
		# is a puzzle with no clue in it.
		DotLog.info(CHANNEL, "a relayed command was refused", {
			"uid": uid,
			"command": command,
			"flag": command_flag,
			"fix": "add '%s' to the server's admin file with the '%s' flag" % [
				uid, command_flag,
			],
		})
		site_command.emit(uid, command, false)
		return

	if not command_fn.is_valid():
		site_command.emit(uid, command, false)
		return

	command_fn.call(uid, command, args, config.command_source)
	site_command.emit(uid, command, true)


# --- The cursor ------------------------------------------------------------

func _cursor_path() -> String:
	return config.cursor_path if config.cursor_path != "" else DEFAULT_CURSOR_PATH


func _load_cursor() -> void:
	var path := _cursor_path()

	if not FileAccess.file_exists(path):
		return

	var read := DotPaths.read_json(path)

	if not read.ok:
		DotLog.warn(CHANNEL, "the relay cursor could not be read", {
			"path": path, "why": read.error.message,
		})
		return

	var data: Variant = read.value

	if typeof(data) == TYPE_DICTIONARY:
		_cursor = str((data as Dictionary).get("cursor", ""))


func _set_cursor(value: String) -> void:
	if value == _cursor:
		return

	_cursor = value

	var written := DotPaths.write_json(_cursor_path(), {"cursor": _cursor})

	if not written.ok:
		DotLog.warn(CHANNEL, "the relay cursor could not be written", {
			"why": written.error.message,
		})
		return

	# `user://` is an IndexedDB mirror on the web and a write is not a write until it is
	# flushed. A relay is a server-side thing and will almost never run in a browser, but
	# every other write path in this family calls this and the one that does not is the
	# one that is wrong on the day somebody tries.
	DotWeb.sync_filesystem()


func _default_uid_for_author(author_id: String) -> String:
	if author_id == "":
		return ""
	return "%s%s" % [config.author_uid_prefix, author_id]


# --- Reporting -------------------------------------------------------------

func describe() -> Dictionary:
	return {
		"enabled": config != null and config.enabled,
		"queued": _queue.size(),
		"sent": _sent,
		"received": _received,
		"dropped": _dropped,
		"failures": _failures,
		"cursor": _cursor,
		"last_error": _last_error,
	}


func describe_lines() -> PackedStringArray:
	if config == null or not config.enabled:
		return PackedStringArray(["chat relay: off"])

	return PackedStringArray([
		"chat relay   on, cursor %s" % (_cursor if _cursor != "" else "(none)"),
		"  out        %d sent, %d queued, %d dropped" % [
			_sent, _queue.size(), _dropped
		],
		"  in         %d received" % _received,
		"  commands   %s" % ("allowed" if config.allow_commands else "refused"),
		"  failures   %d%s" % [
			_failures, "  last: %s" % _last_error if _last_error != "" else ""
		],
	])
