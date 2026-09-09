class_name DotChatClient
extends Node

## The receiving half: scrollback, unread counts, and the local echo problem.
##
## A client's job is smaller than a router's and has exactly one hard part. A player
## who types and sees nothing until the server answers thinks the game has hung; a
## client that draws its own line immediately shows them a message that may have been
## refused for flooding, gagging or length — and the player, having seen it, repeats
## it.
##
## So this does neither. It runs the [i]same[/i] [DotChatFilter] pass the server will
## run, refuses locally what the server would refuse, and tells the player why before
## anything is sent. What it will not do is draw the line: acceptance is the server's
## to grant, and the round trip that grants it is one frame on a loopback and eighty
## milliseconds on a bad connection, which is not long enough to be worth being wrong
## about.
##
## [codeblock]
## var chat := DotChatClient.new()
## chat.send_fn = func(text: String, channel: StringName) -> void:
##     link.rpc_say(String(channel), text)
## chat.message_received.connect(_on_line)
## add_child(chat)
##
## var res := chat.compose(&"all", entry.text)   # refused locally, or sent
## if not res.ok:
##     hud.flash(res.error.message)
## [/codeblock]

const CHANNEL := "chat"

const SERVICE := &"dot_chat_client"

## A message arrived and has been filed.
signal message_received(message: DotChatMessage, channel_id: StringName)

## The sequence numbers skipped. A client that has missed lines is a client whose
## scrollback has a hole in it, and it is better to say so than to draw a continuous
## conversation that is not one.
signal gap_detected(expected: int, received: int)

## The unread count for a channel changed.
signal unread_changed(channel_id: StringName, unread: int)

@export_group("Configuration")

## The same rules the server holds, for the local pre-check.
##
## [b]A copy, and not authoritative.[/b] If it disagrees with the server's the server
## wins, and the only symptom is a message the client thought was fine being refused
## — which is the right way round for the disagreement to fail.
@export var rules: DotChatRules = null

## Channels the client knows about, for prefixes and colours.
@export var channels: Array[DotChatChannel] = []

@export_range(0, 4096, 1) var history_limit: int = 300

@export var register_as: StringName = SERVICE

## [code]func(text: String, channel: StringName) -> void[/code]. How a composed line
## reaches the server.
var send_fn: Callable = Callable()

var history: DotChatHistory = null

## The channel the input box is currently addressing.
var active_channel: StringName = &"all"

var _by_id: Dictionary = {}
var _unread: Dictionary = {}
var _last_seq: int = 0
var _started: bool = false


func _ready() -> void:
	start()


func start() -> DotResult:
	if _started:
		return DotResult.success(self)

	if rules == null:
		rules = DotChatRules.new()

	history = DotChatHistory.new(history_limit)

	for chan in channels:
		if chan != null:
			add_channel(chan)

	if register_as != &"":
		DotRegistry.register(register_as, self)

	_started = true
	return DotResult.success(self)


func add_channel(chan: DotChatChannel) -> void:
	if chan == null:
		return
	_by_id[chan.id] = chan
	if history != null:
		history.set_limit(chan.id, maxi(1, chan.history_limit))


func channel(id: StringName) -> DotChatChannel:
	if _by_id.has(id):
		return _by_id[id]
	return null


# --- Sending ---------------------------------------------------------------

## Runs the local pre-check and, if it passes, hands the text to [member send_fn].
##
## Returns the text that was sent, or the failure the server would have returned.
## A command is passed through untouched — the server owns the command table, and a
## client that pre-checked one would refuse the commands it had not been told about.
func compose(channel_id: StringName, text: String) -> DotResult:
	if not _started:
		start()

	var raw := text.strip_edges()
	if raw == "":
		return DotResult.fail(DotError.CODE_INVALID, "The message is empty.")

	if rules.command_prefix_of(raw) == "":
		var cleaned := DotChatFilter.sanitise(raw, rules)
		if not cleaned.ok:
			return cleaned

	if not send_fn.is_valid():
		return DotResult.fail(
			DotError.CODE_STATE, "This chat client has nowhere to send to."
		)

	send_fn.call(raw, channel_id)
	return DotResult.success(raw)


# --- Receiving -------------------------------------------------------------

## Files one wire dictionary from the server.
func receive(wire: Dictionary) -> DotResult:
	if not _started:
		start()

	var parsed := DotChatMessage.from_dictionary(wire)
	if not parsed.ok:
		return parsed

	var message: DotChatMessage = parsed.value

	# Sequence numbers are per router and monotonic. A repeat is dropped rather than
	# drawn twice — a reconnect that replays a backlog would otherwise duplicate every
	# line the client already had.
	if message.seq > 0 and message.seq <= _last_seq:
		return DotResult.success(message)

	if _last_seq > 0 and message.seq > _last_seq + 1:
		gap_detected.emit(_last_seq + 1, message.seq)

	if message.seq > 0:
		_last_seq = message.seq

	history.append(message)

	if message.channel != active_channel:
		var count := unread(message.channel) + 1
		_unread[message.channel] = count
		unread_changed.emit(message.channel, count)

	message_received.emit(message, message.channel)
	return DotResult.success(message)


## Files a whole backlog in one call, without reporting a gap for it.
##
## A backlog is by definition a set of lines this client has not seen, and running it
## through [method receive] would report a gap between the newest backlog line and
## the first live one for every player who joins.
func receive_backlog(lines: Array) -> int:
	var filed := 0

	for entry in lines:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var parsed := DotChatMessage.from_dictionary(entry as Dictionary)
		if not parsed.ok:
			continue
		var message: DotChatMessage = parsed.value
		history.append(message)
		_last_seq = maxi(_last_seq, message.seq)
		message_received.emit(message, message.channel)
		filed += 1

	return filed


# --- Reading ---------------------------------------------------------------

## Formatted BBCode lines for one channel, oldest first.
func lines(
	channel_id: StringName, count: int = 50, options: Dictionary = {}
) -> PackedStringArray:
	var out := PackedStringArray()
	var chan := channel(channel_id)

	for message in history.recent(channel_id, count):
		out.append(DotChatFormat.line(message, chan, options))

	return out


## Formatted lines across every channel, in arrival order. What a single-window chat
## draws.
func all_lines(count: int = 50, options: Dictionary = {}) -> PackedStringArray:
	var out := PackedStringArray()

	for message in history.recent_all(count):
		out.append(DotChatFormat.line(message, channel(message.channel), options))

	return out


func unread(channel_id: StringName) -> int:
	if _unread.has(channel_id):
		return int(_unread[channel_id])
	return 0


func total_unread() -> int:
	var total := 0
	for value in _unread.values():
		total += int(value)
	return total


func mark_read(channel_id: StringName) -> void:
	if unread(channel_id) == 0:
		return
	_unread[channel_id] = 0
	unread_changed.emit(channel_id, 0)


func set_active_channel(channel_id: StringName) -> void:
	active_channel = channel_id
	mark_read(channel_id)


func clear() -> void:
	if history != null:
		history.clear()
	_unread.clear()
	_last_seq = 0


func _exit_tree() -> void:
	if register_as != &"":
		DotRegistry.unregister_instance(register_as, self)


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("chat client: %d channels, seq %d, %d unread" % [
		_by_id.size(), _last_seq, total_unread()
	])
	if history != null:
		out.append_array(history.describe_lines())
	return out
