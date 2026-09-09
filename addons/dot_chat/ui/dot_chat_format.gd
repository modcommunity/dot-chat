class_name DotChatFormat
extends RefCounted

## Turns a [DotChatMessage] into a line to draw. Ships no art and no scene.
##
## dot-ui's rule applies here for the same reason: an addon that draws its own chat
## window is an addon every game has to fight. What a game actually wants from a chat
## addon is the [i]line[/i] — correctly attributed, correctly coloured, with the
## player's text kept as text — and then to draw it in its own window with its own
## theme.
##
## [b]The text is already escaped and the decoration is not.[/b] Everything this adds
## — the timestamp, the channel prefix, the colour tags around the name — is produced
## here from server-decided values, and the one part a player supplied went through
## [DotChatFilter] before it was ever sent. That is the whole reason the escaping
## happens on the server: by the time a formatter sees a message, there is no way to
## tell which parts came from where.

## Options a game passes to [method line]. A [Dictionary] rather than a resource
## because a formatter is called once per line per frame and this is read-only.
const DEFAULTS: Dictionary = {
	"timestamps": false,
	"channel_prefix": true,
	"name_colour": Color(0.85, 0.88, 0.95),
	"system_colour": Color(0.65, 0.70, 0.80),
	"admin_colour": Color(0.95, 0.75, 0.35),
	"action_colour": Color(0.75, 0.85, 0.95),
	"text_colour": Color(1, 1, 1),
}


## A BBCode line for a [RichTextLabel].
static func line(
	message: DotChatMessage,
	channel: DotChatChannel = null,
	options: Dictionary = {}
) -> String:
	var opts := DEFAULTS.duplicate()
	for key in options.keys():
		opts[key] = options[key]

	var out := ""

	if bool(opts["timestamps"]) and message.sent_at > 0:
		out += "[color=#7a8090]%s[/color] " % clock(message.sent_at)

	if bool(opts["channel_prefix"]) and channel != null and channel.prefix != "":
		out += "%s " % _coloured(channel.prefix, channel.colour)

	match message.kind:
		DotChatMessage.Kind.SYSTEM:
			return out + _coloured(message.text, opts["system_colour"])

		DotChatMessage.Kind.ADMIN:
			return out + _coloured(message.text, opts["admin_colour"])

		DotChatMessage.Kind.JOIN:
			return out + _coloured(
				"%s joined" % message.sender_name, opts["system_colour"]
			)

		DotChatMessage.Kind.LEAVE:
			return out + _coloured(
				"%s left" % message.sender_name, opts["system_colour"]
			)

		DotChatMessage.Kind.ACTION:
			return out + _coloured(
				"* %s %s" % [message.sender_name, message.text], opts["action_colour"]
			)

		DotChatMessage.Kind.WHISPER:
			out += _coloured("%s whispers:" % message.sender_name, opts["name_colour"])
			return out + " " + _coloured(message.text, opts["text_colour"])

	out += _coloured("%s:" % message.sender_name, opts["name_colour"])
	return out + " " + _coloured(message.text, opts["text_colour"])


## The same line with no markup, for a plain [Label], a console or a log file.
##
## [b]Not "the BBCode line with the tags removed".[/b] The message text contains
## [code][lb][/code] where the player typed a bracket, so a tag-stripping pass over
## the formatted line would leave those in place and a log would read differently
## from the game.
static func plain(message: DotChatMessage, channel: DotChatChannel = null) -> String:
	var prefix := ""
	if channel != null and channel.prefix != "":
		prefix = "%s " % channel.prefix
	return prefix + unescape(message.describe())


## Puts back the two characters [method DotChatFilter.escape_bbcode] replaced.
##
## For a destination that does not read markup at all. Never call it on the way into
## a [RichTextLabel]: that hands a player's brackets straight back to the parser and
## undoes the whole point of the escape.
static func unescape(text: String) -> String:
	return text.replace("[lb]", "[").replace("[rb]", "]")


## [code]HH:MM[/code] in local time.
static func clock(unix_seconds: int) -> String:
	var t := Time.get_time_dict_from_unix_time(unix_seconds)
	return "%02d:%02d" % [int(t["hour"]), int(t["minute"])]


static func _coloured(text: String, colour: Variant) -> String:
	var c: Color = colour if typeof(colour) == TYPE_COLOR else Color(1, 1, 1)
	return "[color=#%s]%s[/color]" % [c.to_html(false), text]
