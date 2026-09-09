class_name DotChatMessage
extends RefCounted

## One line of chat, from the moment a player pressed enter to the moment it is drawn.
##
## [b]A chat message is a document, not a string.[/b] The string is what a player
## typed; everything a client needs in order to draw it correctly — who said it, on
## which channel, whether it was a whisper, whether the server said it rather than a
## person — is separate from the text and is decided by the server. A game that sends
## a pre-formatted line instead has decided the colour, the name and the prefix on the
## machine least entitled to decide any of them, and has given every player a way to
## impersonate the server by typing its prefix.
##
## The wire form is a [Dictionary] with short keys, because chat is the one thing in a
## game that is sent as text and read by a human, and a hundred players in a lobby is
## a hundred of these a second.
##
## [codeblock]
## var message := DotChatMessage.say(&"all", "u_91af", "Ada", "hello")
## var wire := message.to_dictionary()
## var back := DotChatMessage.from_dictionary(wire)
## [/codeblock]

## What kind of line this is.
##
## The kind decides how it is drawn and, on the server, what it is allowed to skip.
## A [constant Kind.SYSTEM] line is not subject to a gag or a rate limit because
## nobody typed it; a [constant Kind.ACTION] is the [code]/me[/code] form and is
## drawn without the "name:" separator.
enum Kind {
	SAY,      ## An ordinary line somebody typed.
	ACTION,   ## The `/me` form: "* Ada waves".
	WHISPER,  ## Addressed to one person. Delivered to exactly two peers.
	SYSTEM,   ## The server speaking. Never attributed to a player.
	JOIN,     ## Somebody arrived.
	LEAVE,    ## Somebody left.
	ADMIN,    ## An administrative announcement, drawn distinctly from SYSTEM.
}

## Serialised names for [enum Kind], indexed by the enum value.
##
## [b]The names on the wire are these and only these.[/b] dot-moderation shipped a
## store that wrote a punishment's [i]player-facing[/i] name — "voice muted", with a
## space — and read it back through a parser that had no case for it, so every stored
## voice mute loaded as a warning and enforced nothing. Two ends of one serialisation
## are exactly as capable of never meeting as two ends of a wire, so the mapping is
## one table used in both directions and the self-test walks every value of the enum
## through it.
const KIND_NAMES: Array[String] = [
	"say", "action", "whisper", "system", "join", "leave", "admin",
]

## Kinds a player may not send. The server produces these itself.
const SERVER_KINDS: Array[int] = [Kind.SYSTEM, Kind.JOIN, Kind.LEAVE, Kind.ADMIN]

## Monotonic per-router sequence number. Lets a client detect a gap and ignore a
## duplicate; a timestamp cannot do either, because two lines can share a second.
var seq: int = 0

## Unix seconds, stamped by the server. Clients never stamp their own: a clock a
## player controls decides where their line sorts in everybody else's window.
var sent_at: int = 0

## Which channel this belongs to. Resolved against a [DotChatChannel].
var channel: StringName = &""

var kind: Kind = Kind.SAY

## The durable, pseudonymous key of whoever said it — a dot-user scope id, a guest
## id, whatever the host's [code]key_fn[/code] returns. Empty for a server line.
##
## [b]Not an account id.[/b] Chat is broadcast to everybody in the server, so a key
## that identifies a person across servers would be published to every player in
## every server they ever spoke in.
var sender_key: String = ""

## The transport peer that said it, for the server's own bookkeeping. Never sent.
var sender_peer: int = 0

## The name to draw. Captured at send time, because a player who renames themselves
## must not retroactively rename what they already said.
var sender_name: String = ""

## The player-visible text, already sanitised. See [DotChatFilter].
var text: String = ""

## For a whisper: the durable key of the recipient.
var target_key: String = ""

## For a whisper: the recipient's peer. Never sent.
var target_peer: int = 0

## Free-form extras a game attaches — a team id, a colour, a rank badge.
##
## Copied in and out. A [Dictionary] is a reference in GDScript, and handing out the
## live one is how [DotLeaderboardDef] ended up with every scoped board and its own
## template being one object.
var meta: Dictionary = {}


static func make(
	p_kind: Kind,
	p_channel: StringName,
	p_sender_key: String,
	p_sender_name: String,
	p_text: String
) -> DotChatMessage:
	var out := DotChatMessage.new()
	out.kind = p_kind
	out.channel = p_channel
	out.sender_key = p_sender_key
	out.sender_name = p_sender_name
	out.text = p_text
	out.sent_at = int(Time.get_unix_time_from_system())
	return out


static func say(
	p_channel: StringName, p_sender_key: String, p_sender_name: String, p_text: String
) -> DotChatMessage:
	return make(Kind.SAY, p_channel, p_sender_key, p_sender_name, p_text)


## A line the server said. No sender, and no gag or rate limit applies to it.
static func system(p_channel: StringName, p_text: String) -> DotChatMessage:
	return make(Kind.SYSTEM, p_channel, "", "", p_text)


func is_from_server() -> bool:
	return SERVER_KINDS.has(int(kind))


func kind_name() -> String:
	return KIND_NAMES[int(kind)]


## The enum value for a serialised name, or -1.
##
## Returns -1 rather than defaulting to [constant Kind.SAY], because a name this does
## not recognise is a version mismatch or a typo and silently turning it into an
## ordinary line is how a system announcement becomes attributable to a player.
static func kind_from_name(name: String) -> int:
	var index := KIND_NAMES.find(name)
	return index


## The wire form. Short keys; absent fields are omitted rather than sent empty.
##
## [member sender_peer] and [member target_peer] are deliberately not here. They are
## transport-local integers that mean nothing on another machine, and publishing the
## whisper target's peer id to everybody would leak who is talking to whom.
func to_dictionary() -> Dictionary:
	var out := {
		"n": seq,
		"t": sent_at,
		"c": String(channel),
		"k": kind_name(),
		"m": text,
	}

	if sender_key != "":
		out["s"] = sender_key
	if sender_name != "":
		out["d"] = sender_name
	if target_key != "":
		out["w"] = target_key
	if not meta.is_empty():
		out["x"] = meta.duplicate(true)

	return out


static func from_dictionary(data: Dictionary) -> DotResult:
	var kind_value := kind_from_name(str(data.get("k", "say")))
	if kind_value < 0:
		return DotResult.fail(
			DotError.CODE_PARSE,
			"Unknown chat message kind.",
			str(data.get("k", ""))
		)

	var out := DotChatMessage.new()
	out.seq = int(data.get("n", 0))
	out.sent_at = int(data.get("t", 0))
	out.channel = StringName(str(data.get("c", "")))
	out.kind = kind_value as Kind
	out.text = str(data.get("m", ""))
	out.sender_key = str(data.get("s", ""))
	out.sender_name = str(data.get("d", ""))
	out.target_key = str(data.get("w", ""))

	var extras: Variant = data.get("x")
	if typeof(extras) == TYPE_DICTIONARY:
		out.meta = (extras as Dictionary).duplicate(true)

	return DotResult.success(out)


func duplicate_message() -> DotChatMessage:
	var out := DotChatMessage.new()
	out.seq = seq
	out.sent_at = sent_at
	out.channel = channel
	out.kind = kind
	out.sender_key = sender_key
	out.sender_peer = sender_peer
	out.sender_name = sender_name
	out.text = text
	out.target_key = target_key
	out.target_peer = target_peer
	out.meta = meta.duplicate(true)
	return out


func describe() -> String:
	match kind:
		Kind.ACTION:
			return "* %s %s" % [sender_name, text]
		Kind.WHISPER:
			return "%s whispers: %s" % [sender_name, text]
		Kind.SYSTEM, Kind.ADMIN:
			return text
		Kind.JOIN:
			return "%s joined" % sender_name
		Kind.LEAVE:
			return "%s left" % sender_name
	return "%s: %s" % [sender_name, text]


func _to_string() -> String:
	return "[%s#%d] %s" % [String(channel), seq, describe()]
