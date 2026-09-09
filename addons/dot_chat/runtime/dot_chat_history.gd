class_name DotChatHistory
extends RefCounted

## Recent chat, capped per channel and in total.
##
## Both caps matter and they are not the same cap. Per channel, because scrollback in
## a window showing one channel should not be pushed out by traffic on another; in
## total, because a server with forty channels and a two-hundred-line cap on each has
## quietly agreed to hold eight thousand messages of player-supplied text for as long
## as it runs.
##
## Stored newest-last, which is the order a window draws them in. [method recent]
## returns copies: history that hands out its live objects is history a caller can
## rewrite, and a chat log people are moderated from is the last place that should be
## possible.

## Per-channel line caps, [code]channel -> int[/code].
var limits: Dictionary = {}

## Backstop across every channel. 0 disables it.
var total_limit: int = 1000

var _by_channel: Dictionary = {}
var _order: Array[DotChatMessage] = []


func _init(p_total_limit: int = 1000) -> void:
	total_limit = p_total_limit


## Sets the cap for one channel. Trims immediately if it is now over.
func set_limit(channel: StringName, limit: int) -> void:
	limits[channel] = maxi(0, limit)
	_trim_channel(channel)


func limit_for(channel: StringName) -> int:
	if limits.has(channel):
		return int(limits[channel])
	return 200


func append(message: DotChatMessage) -> void:
	if limit_for(message.channel) <= 0:
		return

	if not _by_channel.has(message.channel):
		var fresh: Array[DotChatMessage] = []
		_by_channel[message.channel] = fresh

	var bucket: Array[DotChatMessage] = _by_channel[message.channel]
	bucket.append(message)
	_order.append(message)

	_trim_channel(message.channel)
	_trim_total()


## The last [param count] messages on a channel, oldest first.
func recent(channel: StringName, count: int = 50) -> Array[DotChatMessage]:
	var out: Array[DotChatMessage] = []
	if not _by_channel.has(channel) or count <= 0:
		return out

	var bucket: Array[DotChatMessage] = _by_channel[channel]
	var start := maxi(0, bucket.size() - count)

	for i in range(start, bucket.size()):
		out.append((bucket[i] as DotChatMessage).duplicate_message())

	return out


## The last [param count] messages across every channel, in the order they arrived.
func recent_all(count: int = 50) -> Array[DotChatMessage]:
	var out: Array[DotChatMessage] = []
	var start := maxi(0, _order.size() - maxi(0, count))

	for i in range(start, _order.size()):
		out.append((_order[i] as DotChatMessage).duplicate_message())

	return out


## Every message a given peer or key sent, for a moderator looking at somebody.
func by_sender(sender_key: String, count: int = 50) -> Array[DotChatMessage]:
	var out: Array[DotChatMessage] = []

	for i in range(_order.size() - 1, -1, -1):
		if out.size() >= count:
			break
		var message: DotChatMessage = _order[i]
		if message.sender_key == sender_key:
			out.append(message.duplicate_message())

	out.reverse()
	return out


func size() -> int:
	return _order.size()


func channel_size(channel: StringName) -> int:
	if not _by_channel.has(channel):
		return 0
	return (_by_channel[channel] as Array).size()


func clear() -> void:
	_by_channel.clear()
	_order.clear()


func clear_channel(channel: StringName) -> void:
	if not _by_channel.has(channel):
		return

	var bucket: Array[DotChatMessage] = _by_channel[channel]
	for message in bucket:
		var index := _order.find(message)
		if index >= 0:
			_order.remove_at(index)

	_by_channel.erase(channel)


func _trim_channel(channel: StringName) -> void:
	if not _by_channel.has(channel):
		return

	var limit := limit_for(channel)
	var bucket: Array[DotChatMessage] = _by_channel[channel]

	while bucket.size() > limit:
		var dropped: DotChatMessage = bucket[0]
		bucket.remove_at(0)
		var index := _order.find(dropped)
		if index >= 0:
			_order.remove_at(index)


func _trim_total() -> void:
	if total_limit <= 0:
		return

	while _order.size() > total_limit:
		var dropped: DotChatMessage = _order[0]
		_order.remove_at(0)
		if _by_channel.has(dropped.channel):
			var bucket: Array[DotChatMessage] = _by_channel[dropped.channel]
			var index := bucket.find(dropped)
			if index >= 0:
				bucket.remove_at(index)


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("chat history: %d lines, cap %d" % [_order.size(), total_limit])

	var names: Array[StringName] = []
	for key in _by_channel.keys():
		names.append(key as StringName)

	# Not Array.sort(): Godot compares StringNames by their interned pointer, which is
	# stable within a process and arbitrary between two. dot-net assigned wire ids from
	# such a sort and two peers gave one message type two different ids.
	names.sort_custom(func(a: StringName, b: StringName) -> bool:
		return String(a) < String(b))

	for name in names:
		out.append("  %s: %d/%d" % [
			String(name), channel_size(name), limit_for(name)
		])

	return out
