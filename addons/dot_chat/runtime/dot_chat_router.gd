class_name DotChatRouter
extends Node

## The server half of chat: what is accepted, who receives it, and what is kept.
##
## Everything a chat message goes through happens here and happens on the server,
## because every part of it is a decision a player must not be making about other
## players — whether they are allowed to speak, how fast, what the text may contain,
## whose window it lands in, and what name is drawn beside it.
##
## [b]dot-chat sends nothing itself.[/b] It has no transport, no RPC and no opinion
## about your netcode: the host gives it a [member send_fn] and it hands that a wire
## dictionary and a list of peers. That is what lets the same router serve a dot-net
## game, a dot-server module, a loopback test and a single-player game where
## [member send_fn] draws straight into the window.
##
## [codeblock]
## var router := DotChatRouter.new()
## router.send_fn = func(wire: Dictionary, to: PackedInt32Array) -> void:
##     for peer in to:
##         net.send_to(peer, wire)
## router.peers_fn = func() -> PackedInt32Array: return server.peer_ids()
## router.name_fn = func(peer: int) -> String: return server.session_of(peer).name
## router.key_fn  = func(peer: int) -> String: return server.session_of(peer).uid
## add_child(router)
##
## var res := router.submit(peer, &"all", typed_text)
## if not res.ok:
##     link.notify(peer, res.error.message)
## [/codeblock]
##
## [b]Gags are asked for, not stored.[/b] The router looks up whatever is registered
## as [code]dot_mute_source[/code] and calls [code]is_chat_muted(peer)[/code] on it —
## which is exactly the method [DotModerationManager] publishes and which, until this
## addon existed, nothing in the family called. Neither addon names the other and a
## project with only one of them works.

const CHANNEL := "chat"

## The registry name this publishes itself under.
const SERVICE := &"dot_chat_router"

## The registry name a gag source is looked up by. dot-moderation's manager
## registers itself here; anything answering [code]is_chat_muted(peer) -> bool[/code]
## will do.
const MUTE_SERVICE := &"dot_mute_source"

## A message was accepted and handed to [member send_fn].
signal message_accepted(message: DotChatMessage, recipients: PackedInt32Array)

## A message was refused. [param code] is a [DotError] code, never a sentence to
## branch on.
signal message_refused(peer: int, code: String, reason: String)

## A line beginning with a command prefix. The router does not broadcast these.
##
## [b]This is the whole integration with dot-server's chat commands and dot-vote's
## [code]!rtv[/code].[/b] The host connects, matches the command, and either handles
## it or tells the player nothing did.
signal command_entered(peer: int, command: String, args: PackedStringArray, raw: String)

@export_group("Configuration")

@export var rules: DotChatRules = null

## A JSON file layered over the exported defaults, as every [DotConfig] here is.
@export_file("*.json") var rules_file: String = ""

## Install [code]all[/code], [code]team[/code] and [code]whisper[/code] on ready.
##
## Off for a game that declares its own set. A router with no channels accepts
## nothing, which is a configuration error rather than a silent one — [method submit]
## refuses with [constant DotError.CODE_STATE] and says so.
@export var install_default_channels: bool = true

## Turn [code]/me something[/code] into a [constant DotChatMessage.Kind.ACTION].
##
## On, because it is a command in name only: no host handles it, every game wants it,
## and a router that emitted it as a command would leave every game writing the same
## six lines.
@export var handle_me_command: bool = true

@export_group("Integration")

## Registry name to publish under. Empty publishes nothing, which is what a second
## router in the same process wants.
@export var register_as: StringName = SERVICE

## Registry name to look a gag source up under.
@export var mute_service: StringName = MUTE_SERVICE

# --- Host-supplied seams ---------------------------------------------------

## [code]func(wire: Dictionary, recipients: PackedInt32Array) -> void[/code].
## Required. Nothing reaches a player without it.
var send_fn: Callable = Callable()

## [code]func() -> PackedInt32Array[/code]. Everybody currently connected.
var peers_fn: Callable = Callable()

## [code]func(peer: int) -> String[/code]. The name to draw.
var name_fn: Callable = Callable()

## [code]func(peer: int) -> String[/code]. The durable pseudonymous key.
var key_fn: Callable = Callable()

## [code]func(peer: int) -> StringName[/code]. For [constant DotChatChannel.Scope.TEAM].
var team_fn: Callable = Callable()

## [code]func(peer: int) -> Vector3[/code]. For [constant DotChatChannel.Scope.RADIUS].
##
## A 2D game returns [code]Vector3(x, y, 0)[/code]. Measuring a 2D distance in a 3D
## world is how dot-npc-ai called two NPCs standing on each other 1.8 metres apart.
var position_fn: Callable = Callable()

## [code]func(peer: int, channel: StringName) -> bool[/code]. For
## [constant DotChatChannel.Scope.MEMBERS].
var membership_fn: Callable = Callable()

## [code]func(peer: int) -> bool[/code]. Gates [member DotChatChannel.admin_only].
var is_admin_fn: Callable = Callable()

## [code]func(peer: int) -> bool[/code]. Consulted only when no gag source is
## registered, so a project without dot-moderation can still gag somebody.
var gag_fn: Callable = Callable()

## Recent lines, per channel and in total.
var history: DotChatHistory = null

var _channels: Dictionary = {}
var _order: Array[StringName] = []
var _limiter: DotRateLimiter = null
var _seq: int = 0
var _silenced_until: Dictionary = {}
var _recent_by_sender: Dictionary = {}
var _warned_about_mute_source: bool = false
var _command_claimed: bool = false
var _started: bool = false


func _ready() -> void:
	start()


## Prepares the router. Idempotent, and called by [method _ready].
##
## Explicit because a router created through a [DotNodeRef] has already run
## [method _ready] by the time its host assigns [member rules] — the same ordering
## that left dot-server's audit log unopened in every default configuration, warning
## about it on every boot in a way that read like a setting nobody had filled in.
func start() -> DotResult:
	if _started:
		return DotResult.success(self)

	if rules == null:
		rules = DotChatRules.new()

	if rules_file != "":
		var loaded := rules.apply_json_file(rules_file)
		if not loaded.ok:
			DotLog.warn(CHANNEL, "chat rules file was not applied", {
				"path": rules_file, "error": str(loaded.error)
			})

	var valid := rules.validate()
	if not valid.ok:
		return valid.wrap("The chat rules are not usable.")

	history = DotChatHistory.new(rules.history_limit)
	_limiter = DotRateLimiter.new(rules.rate_per_second(), rules.burst)

	if install_default_channels and _channels.is_empty():
		add_channel(DotChatChannel.everyone())
		add_channel(DotChatChannel.team())
		add_channel(DotChatChannel.direct())

	if register_as != &"":
		DotRegistry.register(register_as, self)

	_started = true
	DotLog.info(CHANNEL, "chat router ready", {
		"channels": _order.size(),
		"rate_per_minute": rules.rate_per_minute,
		"max_length": rules.max_length,
	})

	return DotResult.success(self)


# --- Channels --------------------------------------------------------------

func add_channel(channel: DotChatChannel) -> DotResult:
	if channel == null:
		return DotResult.fail(DotError.CODE_INVALID, "No channel.")

	var valid := channel.validate()
	if not valid.ok:
		return valid

	if _channels.has(channel.id):
		return DotResult.fail(
			DotError.CODE_INVALID, "That channel already exists.", String(channel.id)
		)

	_channels[channel.id] = channel
	_order.append(channel.id)

	if history != null:
		history.set_limit(channel.id, channel.history_limit)

	return DotResult.success(channel)


func remove_channel(id: StringName) -> void:
	_channels.erase(id)
	var index := _order.find(id)
	if index >= 0:
		_order.remove_at(index)
	if history != null:
		history.clear_channel(id)


func channel(id: StringName) -> DotChatChannel:
	if _channels.has(id):
		return _channels[id]
	return null


func has_channel(id: StringName) -> bool:
	return _channels.has(id)


func channel_ids() -> Array[StringName]:
	return _order.duplicate()


## The first installed channel, used when a caller does not name one.
func default_channel() -> StringName:
	if _order.is_empty():
		return &""
	return _order[0]


# --- Sending ---------------------------------------------------------------

## Whether [param text] is a command rather than something to broadcast.
func is_command(text: String) -> bool:
	return rules != null and rules.command_prefix_of(text.strip_edges()) != ""


## The whole path for a line a player typed.
##
## On success the value is the [DotChatMessage] that was sent — [b]or [code]null[/code]
## when the line was a command[/b], in which case [signal command_entered] has been
## emitted and nothing was broadcast. Ask [method is_command] first if the difference
## matters to the caller.
##
## On failure the code is one of:
## [codeblock]
## CODE_STATE       no such channel, or the router has no channels
## CODE_FORBIDDEN   gagged, not an admin, or the channel is the server's
## CODE_RATE_LIMITED too fast, or the same line twice
## CODE_INVALID     empty, too long, or nothing left once cleaned
## [/codeblock]
func submit(
	peer: int,
	channel_id: StringName,
	text: String,
	kind: DotChatMessage.Kind = DotChatMessage.Kind.SAY
) -> DotResult:
	if not _started:
		var started := start()
		if not started.ok:
			return started

	var target := channel_id
	if target == &"":
		target = default_channel()

	var chan := channel(target)
	if chan == null:
		return _refuse(peer, DotError.CODE_STATE, "No such chat channel.", String(target))

	if chan.server_only:
		return _refuse(
			peer, DotError.CODE_FORBIDDEN, "That channel is not open to players.",
			String(target)
		)

	var raw := text.strip_edges()
	if raw == "":
		return _refuse(peer, DotError.CODE_INVALID, "The message is empty.")

	var prefix := rules.command_prefix_of(raw)
	if prefix != "":
		return _handle_command(peer, target, raw, prefix)

	return _deliver_player_line(peer, chan, raw, kind)


## The [code]/me[/code] form, as a first-class call rather than a command.
func submit_action(peer: int, channel_id: StringName, text: String) -> DotResult:
	return submit(peer, channel_id, text, DotChatMessage.Kind.ACTION)


## A private line from one player to another.
##
## Refused when there is no direct channel installed, rather than falling back to a
## broadcast one — a whisper that is delivered to everybody is worse than a whisper
## that fails.
func whisper(
	peer: int, target_peer: int, text: String, channel_id: StringName = &"whisper"
) -> DotResult:
	var chan := channel(channel_id)
	if chan == null or chan.scope != DotChatChannel.Scope.DIRECT:
		return _refuse(
			peer, DotError.CODE_STATE, "This server has no whisper channel.",
			String(channel_id)
		)

	if target_peer == peer:
		return _refuse(peer, DotError.CODE_INVALID, "You cannot whisper to yourself.")

	var res := _deliver_player_line(
		peer, chan, text.strip_edges(), DotChatMessage.Kind.WHISPER, target_peer
	)
	return res


## A line from the server. Subject to no gag, no rate limit and no length rule.
##
## The text is still sanitised, because a game that interpolates a player's name into
## an announcement has put player-supplied text into a server line, and that is the
## one route by which markup a player wrote is drawn as a message the server said.
func announce(
	text: String,
	channel_id: StringName = &"",
	kind: DotChatMessage.Kind = DotChatMessage.Kind.SYSTEM
) -> DotResult:
	if not _started:
		var started := start()
		if not started.ok:
			return started

	var target := channel_id
	if target == &"":
		target = default_channel()

	var chan := channel(target)
	if chan == null:
		return DotResult.fail(
			DotError.CODE_STATE, "No such chat channel.", String(target)
		)

	var cleaned := text.strip_edges()
	if rules.escape_markup:
		cleaned = DotChatFilter.escape_bbcode(
			DotChatFilter.strip_invisible_chars(
				DotChatFilter.strip_controls(cleaned, rules.allow_newlines)
			)
		)

	if cleaned == "":
		return DotResult.fail(DotError.CODE_INVALID, "The announcement is empty.")

	var message := DotChatMessage.make(kind, target, "", "", cleaned)
	return _dispatch(message, chan, _recipients_for(message, chan))


## A line only [param peer] sees.
##
## [b]Deliberately not kept in history.[/b] History is what a moderator reads back
## and what a joining player is handed; a private notice in it would be shown to
## everybody who asked for either.
func notice(peer: int, text: String, channel_id: StringName = &"") -> DotResult:
	var target := channel_id
	if target == &"":
		target = default_channel()

	var message := DotChatMessage.system(target, text.strip_edges())
	message.seq = _next_seq()

	var to := PackedInt32Array()
	to.append(peer)

	return _send(message, to, false)


## The join notice. A game that does not want one simply never calls it.
func join_notice(peer: int, channel_id: StringName = &"") -> DotResult:
	return _presence(peer, DotChatMessage.Kind.JOIN, channel_id)


func leave_notice(peer: int, channel_id: StringName = &"") -> DotResult:
	return _presence(peer, DotChatMessage.Kind.LEAVE, channel_id)


## The lines to hand somebody who has just connected, as wire dictionaries.
##
## Per channel, capped by [member DotChatChannel.backlog], and only for channels the
## peer can currently receive on — the same audience test a live message goes
## through, so a player joining a team is not handed the other team's last twenty
## lines.
func backlog_for(peer: int) -> Array[Dictionary]:
	var out: Array[Dictionary] = []

	for id in _order:
		var chan: DotChatChannel = _channels[id]
		if chan.backlog <= 0:
			continue

		for message in history.recent(id, chan.backlog):
			if not _receives(peer, message, chan):
				continue
			out.append(message.to_dictionary())

	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("n", 0)) < int(b.get("n", 0)))

	return out


# --- The path a player's line takes ----------------------------------------

func _deliver_player_line(
	peer: int,
	chan: DotChatChannel,
	raw: String,
	kind: DotChatMessage.Kind,
	target_peer: int = 0
) -> DotResult:
	if chan.admin_only and not _is_admin(peer):
		return _refuse(
			peer, DotError.CODE_FORBIDDEN, "That channel is for administrators."
		)

	if not chan.ignores_gag and is_gagged(peer):
		return _refuse(peer, DotError.CODE_FORBIDDEN, "You are gagged.")

	var now := Time.get_ticks_msec()
	if _silenced_until.has(peer) and now < int(_silenced_until[peer]):
		var left := float(int(_silenced_until[peer]) - now) / 1000.0
		return _refuse(
			peer, DotError.CODE_RATE_LIMITED,
			"You are being quiet for another %.0f seconds." % ceilf(left)
		)

	if not _limiter.allow(peer, chan.rate_cost):
		if rules.flood_penalty_sec > 0.0:
			_silenced_until[peer] = now + int(rules.flood_penalty_sec * 1000.0)
		return _refuse(peer, DotError.CODE_RATE_LIMITED, "You are talking too fast.")

	var cleaned := DotChatFilter.sanitise(raw, rules)
	if not cleaned.ok:
		return _refuse(peer, cleaned.code(), cleaned.error.message)

	var text: String = cleaned.value

	if _is_duplicate(peer, text, now):
		return _refuse(peer, DotError.CODE_RATE_LIMITED, "You just said that.")

	_remember(peer, text, now)

	var message := DotChatMessage.new()
	message.kind = kind
	message.channel = chan.id
	message.text = text
	message.sender_peer = peer
	message.sender_key = _key_of(peer)
	message.sender_name = DotChatFilter.clean_name(_name_of(peer))
	message.target_peer = target_peer

	if target_peer != 0:
		message.target_key = _key_of(target_peer)

	return _dispatch(message, chan, _recipients_for(message, chan))


func _handle_command(
	peer: int, channel_id: StringName, raw: String, prefix: String
) -> DotResult:
	var body := raw.substr(prefix.length()).strip_edges()
	if body == "":
		return _refuse(peer, DotError.CODE_INVALID, "That is not a command.")

	var parts := body.split(" ", false)
	var command := str(parts[0]).to_lower()

	var args := PackedStringArray()
	for i in range(1, parts.size()):
		args.append(str(parts[i]))

	if handle_me_command and command == "me":
		if args.is_empty():
			return _refuse(peer, DotError.CODE_INVALID, "Say what you are doing.")
		return submit_action(peer, channel_id, " ".join(args))

	_command_claimed = false
	command_entered.emit(peer, command, args, raw)

	# A signal is emitted synchronously, so a handler that called claim_command() has
	# already done so by the time this line runs. That is the only way the router can
	# know whether anything handled a command without owning a table of them, and
	# without lying about it: "unknown" has to mean nobody claimed it, not "the router
	# does not recognise it", because the router recognises none of them.
	if not _command_claimed and rules.broadcast_unknown_commands:
		var chan := channel(channel_id)
		if chan != null:
			return _deliver_player_line(peer, chan, raw, DotChatMessage.Kind.SAY)

	# Success with no message. A command was consumed and nothing was broadcast; the
	# host decides whether it meant anything.
	return DotResult.success(null)


## Called from a [signal command_entered] handler that dealt with the command.
##
## Only [member DotChatRules.broadcast_unknown_commands] reads it, and only for the
## line being handled right now.
func claim_command() -> void:
	_command_claimed = true


## Whether the command currently being handled has been claimed.
func command_was_claimed() -> bool:
	return _command_claimed


func _presence(
	peer: int, kind: DotChatMessage.Kind, channel_id: StringName
) -> DotResult:
	var target := channel_id
	if target == &"":
		target = default_channel()

	var chan := channel(target)
	if chan == null:
		return DotResult.fail(DotError.CODE_STATE, "No such chat channel.")

	var message := DotChatMessage.make(
		kind, target, _key_of(peer), DotChatFilter.clean_name(_name_of(peer)), ""
	)
	message.sender_peer = peer

	return _dispatch(message, chan, _recipients_for(message, chan))


func _dispatch(
	message: DotChatMessage, chan: DotChatChannel, recipients: PackedInt32Array
) -> DotResult:
	message.seq = _next_seq()
	if message.sent_at == 0:
		message.sent_at = int(Time.get_unix_time_from_system())

	if chan.history_limit > 0:
		history.append(message.duplicate_message())

	return _send(message, recipients, true)


func _send(
	message: DotChatMessage, recipients: PackedInt32Array, announce_it: bool
) -> DotResult:
	if not send_fn.is_valid():
		# Not fatal, and warned every time rather than once: a router with no
		# transport is a router nobody hears, and the family has shipped several
		# values produced correctly and consumed by nothing.
		DotLog.warn(CHANNEL, "a chat message was accepted with no send_fn to carry it", {
			"channel": String(message.channel), "seq": message.seq
		})
	else:
		send_fn.call(message.to_dictionary(), recipients)

	if announce_it:
		message_accepted.emit(message, recipients)

	return DotResult.success(message)


func _refuse(peer: int, code: String, reason: String, detail: String = "") -> DotResult:
	message_refused.emit(peer, code, reason)
	return DotResult.failure(DotError.make(code, reason, detail))


# --- Audience --------------------------------------------------------------

## Who receives [param message]. Exposed because a host writing its own delivery
## still wants the router's answer.
func recipients_for(message: DotChatMessage) -> PackedInt32Array:
	var chan := channel(message.channel)
	if chan == null:
		return PackedInt32Array()
	return _recipients_for(message, chan)


func _recipients_for(
	message: DotChatMessage, chan: DotChatChannel
) -> PackedInt32Array:
	var out := PackedInt32Array()

	if chan.scope == DotChatChannel.Scope.DIRECT:
		if message.target_peer != 0:
			out.append(message.target_peer)
		if chan.echo_to_sender and message.sender_peer != 0:
			out.append(message.sender_peer)
		return out

	for peer in _peers():
		if not _receives(peer, message, chan):
			continue
		out.append(peer)

	return out


## Whether one peer is in the audience for one message.
func _receives(peer: int, message: DotChatMessage, chan: DotChatChannel) -> bool:
	if peer == message.sender_peer and message.sender_peer != 0:
		return chan.echo_to_sender

	match chan.scope:
		DotChatChannel.Scope.EVERYONE:
			return true

		DotChatChannel.Scope.TEAM:
			if message.is_from_server():
				return true
			var sender_team := _team_of(message.sender_peer)
			# A sender with no team reaches nobody. Returning everybody instead is how
			# a spectator's team line is broadcast to the team they are watching.
			if sender_team == &"":
				return false
			return _team_of(peer) == sender_team

		DotChatChannel.Scope.RADIUS:
			if message.is_from_server():
				return true
			if not position_fn.is_valid():
				return false
			var here: Vector3 = position_fn.call(peer)
			var there: Vector3 = position_fn.call(message.sender_peer)
			return here.distance_to(there) <= chan.radius

		DotChatChannel.Scope.MEMBERS:
			if not membership_fn.is_valid():
				return false
			return bool(membership_fn.call(peer, chan.id))

		DotChatChannel.Scope.DIRECT:
			return peer == message.target_peer

	return false


# --- Gags ------------------------------------------------------------------

## Whether [param peer] may not use text chat.
##
## Asks whatever is registered as [member mute_service] — dot-moderation's manager,
## normally — and falls back to [member gag_fn]. A project with neither has nobody
## gagged, which is the correct answer rather than an error.
func is_gagged(peer: int) -> bool:
	var source := DotRegistry.get_service(mute_service)

	if source != null:
		if source.has_method("is_chat_muted"):
			return bool(source.call("is_chat_muted", peer))

		if not _warned_about_mute_source:
			_warned_about_mute_source = true
			DotLog.warn(
				CHANNEL,
				"something is registered as a mute source but cannot answer is_chat_muted",
				{"service": String(mute_service), "class": source.get_class()}
			)

	if gag_fn.is_valid():
		return bool(gag_fn.call(peer))

	return false


# --- Duplicate suppression -------------------------------------------------

func _is_duplicate(peer: int, text: String, now: int) -> bool:
	if rules.duplicate_window_sec <= 0.0:
		return false
	if not _recent_by_sender.has(peer):
		return false

	var window := int(rules.duplicate_window_sec * 1000.0)
	var entries: Array = _recent_by_sender[peer]

	for entry in entries:
		var row: Dictionary = entry
		if now - int(row["at"]) > window:
			continue
		if str(row["text"]) == text:
			return true

	return false


func _remember(peer: int, text: String, now: int) -> void:
	if rules.duplicate_window_sec <= 0.0:
		return

	if not _recent_by_sender.has(peer):
		_recent_by_sender[peer] = []

	var entries: Array = _recent_by_sender[peer]
	entries.append({"text": text, "at": now})

	while entries.size() > rules.duplicate_depth:
		entries.remove_at(0)


## Forgets everything about a peer. Call it when one disconnects, or a server that
## has been up for a week is holding the last three lines of everybody who ever
## connected to it.
func forget(peer: int) -> void:
	_recent_by_sender.erase(peer)
	_silenced_until.erase(peer)
	if _limiter != null:
		_limiter.reset(peer)


# --- Host seams ------------------------------------------------------------

func _peers() -> PackedInt32Array:
	if not peers_fn.is_valid():
		return PackedInt32Array()

	var got: Variant = peers_fn.call()

	if typeof(got) == TYPE_PACKED_INT32_ARRAY:
		return got

	# A host is very likely to hand back an Array[int] — the type a Dictionary's keys
	# come back as — and `as PackedInt32Array` on one does not convert it. Converting
	# here costs a loop per message and saves every host the same five lines.
	var out := PackedInt32Array()
	if typeof(got) == TYPE_ARRAY:
		for value in (got as Array):
			out.append(int(value))

	return out


func _name_of(peer: int) -> String:
	if not name_fn.is_valid():
		return "player %d" % peer
	return str(name_fn.call(peer))


func _key_of(peer: int) -> String:
	if not key_fn.is_valid():
		return ""
	return str(key_fn.call(peer))


func _team_of(peer: int) -> StringName:
	if not team_fn.is_valid():
		return &""
	return StringName(str(team_fn.call(peer)))


func _is_admin(peer: int) -> bool:
	if not is_admin_fn.is_valid():
		return false
	return bool(is_admin_fn.call(peer))


func _next_seq() -> int:
	_seq += 1
	return _seq


func _exit_tree() -> void:
	if register_as != &"":
		DotRegistry.unregister_instance(register_as, self)


func describe() -> Dictionary:
	return {
		"channels": _order.size(),
		"messages": _seq,
		"history": history.size() if history != null else 0,
		"rate_per_minute": rules.rate_per_minute if rules != null else 0,
		"gag_source": String(mute_service) if DotRegistry.has(mute_service) else "",
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("chat router: %d channels, %d messages sent" % [_order.size(), _seq])

	for id in _order:
		var chan: DotChatChannel = _channels[id]
		out.append("  " + chan.describe())

	if history != null:
		out.append_array(history.describe_lines())

	out.append("  gag source: %s" % (
		"registered" if DotRegistry.has(mute_service) else
		("gag_fn" if gag_fn.is_valid() else "none")
	))

	return out
