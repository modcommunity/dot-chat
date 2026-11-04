class_name DotChatRouterAudience
extends Node
## Host seams and audience rules of [DotChatRouter]; split out so the router stays under the size budget.

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

## [code]func(listener: int, speaker: int, listener_at: Vector3, speaker_at: Vector3) -> bool[/code].
## Optional. For [constant DotChatChannel.Scope.RADIUS], asked only of a listener already
## inside the radius.
##
## [b]A radius is not a room.[/b] Two people either side of a wall can be well inside
## one, and a game that has walls has to be able to say so. This addon cannot: it knows
## positions and nothing about what stands between them, and it must not learn — what
## blocks sound is a level's decision, and a wall list here would be one more copy of a
## level to keep in step with the level. So the host is asked, after the distance test
## (the cheap one, which rules most people out first), and is handed both positions
## [member position_fn] already produced rather than asked for them again. Unset, the
## radius is the whole answer, as it always was.
var can_hear_fn: Callable = Callable()

## [code]func(peer: int, channel: StringName) -> bool[/code]. For
## [constant DotChatChannel.Scope.MEMBERS].
var membership_fn: Callable = Callable()

## [code]func(peer: int, channel: StringName) -> StringName[/code]: which group a peer is
## in on that channel — a party id, a squad — or [code]&""[/code] for none. For a
## [member DotChatChannel.grouped] channel, where a line reaches only the sender's group.
##
## [b]Separate from [member membership_fn] because that one is never told the sender.[/b]
## Both may be set: [member membership_fn] then says who may be in the channel at all,
## and this which conversation of it they are in. A line from the server has no sender
## group and reaches every peer that has one.
var group_fn: Callable = Callable()

## [code]func(peer: int) -> bool[/code]. Gates [member DotChatChannel.admin_only].
var is_admin_fn: Callable = Callable()

## [code]func(peer: int) -> bool[/code]. Consulted only when no gag source is
## registered, so a project without dot-moderation can still gag somebody.
var gag_fn: Callable = Callable()

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
			if here.distance_to(there) > chan.radius:
				return false
			if can_hear_fn.is_valid():
				return bool(can_hear_fn.call(peer, message.sender_peer, here, there))
			return true

		DotChatChannel.Scope.MEMBERS:
			if chan.grouped:
				return _same_group(peer, message, chan)
			if not membership_fn.is_valid():
				return false
			return bool(membership_fn.call(peer, chan.id))

		DotChatChannel.Scope.DIRECT:
			return peer == message.target_peer

	return false


## Whether [param peer] is in the sender's group on a grouped channel.
##
## Fails closed at every step: no [member group_fn], a sender with no group, or a receiver
## with none all answer false. The failure that matters here is one party reading another
## party's line, and every ambiguous case resolving to "nobody" is what rules it out.
func _same_group(peer: int, message: DotChatMessage, chan: DotChatChannel) -> bool:
	if not group_fn.is_valid():
		return false

	if membership_fn.is_valid() and not bool(membership_fn.call(peer, chan.id)):
		return false

	var theirs := _group_of(peer, chan.id)

	if theirs == &"":
		return false

	if message.is_from_server():
		# An announcement to the channel is for everybody in any group of it; the server
		# is not in a party and "the sender's group" means nothing for it.
		return true

	var senders := _group_of(message.sender_peer, chan.id)

	# A sender with no group reaches nobody. Returning everybody instead is how a player
	# who has just left their party would broadcast to every party on the server.
	return senders != &"" and senders == theirs


func _group_of(peer: int, channel_id: StringName) -> StringName:
	return StringName(str(group_fn.call(peer, channel_id)))
