class_name DotChatFilter
extends RefCounted

## Turns what a player typed into something safe to put in front of everybody else.
##
## [b]This runs on the server and its output is what every client receives.[/b] Doing
## it on the sending client is doing it nowhere: the client is the one machine in the
## exchange under the control of the person whose input is the problem. A client may
## run the same pass to give immediate feedback, and must not be believed.
##
## The passes, in order, and each is here because of a specific thing text can do:
##
## [codeblock]
## control characters   a NUL or an ESC in a log file, a console, or a terminal
## invisible characters a message that is empty and still occupies eight lines
## direction overrides  text that reads as something other than what it is
## markup               a player drawing arbitrary BBCode in everyone else's window
## whitespace           two hundred spaces used as a line break
## length               measured in characters, refused rather than truncated
## censoring            what the community asked for, past the obvious evasions
## [/codeblock]
##
## Every one returns a [DotResult]: a message that is empty once cleaned is refused,
## not sent as a blank line.

# No log channel: static passes over a string, returning a DotResult. The refusal is the
# sender's to see, and DotChatRouter -- which knows who sent it -- is what logs.

## Code points removed outright when [member DotChatRules.strip_invisible] is on.
##
## Zero-width and formatting characters, the bidirectional overrides, and the byte
## order mark. Emoji joiners are here too, which is a deliberate trade: it breaks a
## small number of composed emoji and it stops a two-character message that renders
## as a hundred glyphs.
const INVISIBLE: Array[int] = [
	0x00AD, 0x061C, 0x180E,
	0x200B, 0x200C, 0x200D, 0x200E, 0x200F,
	0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
	0x2060, 0x2061, 0x2062, 0x2063, 0x2064,
	0x2066, 0x2067, 0x2068, 0x2069,
	0x206A, 0x206B, 0x206C, 0x206D, 0x206E, 0x206F,
	0xFEFF,
]

## Substitutions applied before a censor match, so a word list is not stepped around
## by spelling. Applied to a lowercased copy; the message itself is never rewritten
## by this.
const LEET: Dictionary = {
	"0": "o", "1": "i", "3": "e", "4": "a", "5": "s", "7": "t",
	"8": "b", "@": "a", "$": "s", "!": "i", "|": "l", "+": "t",
}


## Cleans [param text] under [param rules].
##
## Returns the cleaned string, or a failure whose code is
## [constant DotError.CODE_INVALID] for something structurally wrong (empty, too
## long). The caller decides whether to tell the sender why.
static func sanitise(text: String, rules: DotChatRules) -> DotResult:
	var out := text

	out = strip_controls(out, rules.allow_newlines)

	if rules.strip_invisible:
		out = strip_invisible_chars(out)

	if rules.collapse_whitespace:
		out = collapse(out, rules.allow_newlines)

	out = out.strip_edges()

	if out == "":
		return DotResult.fail(DotError.CODE_INVALID, "The message is empty.")

	# Length is measured before markup escaping, not after. Escaping makes a string
	# longer, so measuring afterwards would refuse a message that a player typed
	# inside the limit for containing a bracket — and the limit they were told about
	# is the one they can count.
	if out.length() > rules.max_length:
		if rules.refuse_over_length:
			return DotResult.fail(
				DotError.CODE_INVALID,
				"The message is too long (%d of %d characters)." % [
					out.length(), rules.max_length
				]
			)
		out = out.substr(0, rules.max_length)

	if rules.escape_markup:
		out = escape_bbcode(out)

	if rules.censor_words.size() > 0:
		out = censor(out, rules)

	if out.strip_edges() == "":
		return DotResult.fail(DotError.CODE_INVALID, "The message is empty.")

	return DotResult.success(out)


## Removes C0 and C1 control characters. Newlines survive only if allowed.
static func strip_controls(text: String, allow_newlines: bool) -> String:
	var out := ""
	for i in text.length():
		var c := text.unicode_at(i)
		if c == 10 or c == 13:
			if allow_newlines:
				out += "\n" if c == 10 else ""
			else:
				out += " "
			continue
		if c == 9:
			out += " "
			continue
		if c < 0x20 or c == 0x7F or (c >= 0x80 and c <= 0x9F):
			continue
		out += String.chr(c)
	return out


static func strip_invisible_chars(text: String) -> String:
	var out := ""
	for i in text.length():
		var c := text.unicode_at(i)
		if INVISIBLE.has(c):
			continue
		out += String.chr(c)
	return out


## Collapses runs of spaces. Runs of newlines collapse to at most two.
static func collapse(text: String, allow_newlines: bool) -> String:
	var out := ""
	var spaces := 0
	var newlines := 0

	for i in text.length():
		var c := text.unicode_at(i)

		if c == 10 and allow_newlines:
			spaces = 0
			newlines += 1
			if newlines <= 2:
				out += "\n"
			continue

		if c == 32:
			newlines = 0
			spaces += 1
			if spaces == 1:
				out += " "
			continue

		spaces = 0
		newlines = 0
		out += String.chr(c)

	return out


## Escapes the two characters BBCode reads, so a [RichTextLabel] draws them.
##
## [code][lb][/code] and [code][rb][/code] are the engine's own escapes, so the text
## is still legible in a plain [Label] — which matters, because a client that does
## not use BBCode at all should not be showing its players escape sequences.
static func escape_bbcode(text: String) -> String:
	# One pass, not two chained replaces. `[` -> `[lb]` inserts a `]`, which a
	# following `]` -> `[rb]` pass then rewrites — so "[a]" came out as "[lb[rb]a[rb]",
	# which is not what was typed and is not even balanced. The two-replace spelling
	# is the obvious one and it is wrong for input containing either bracket, which is
	# to say for exactly the input the escape exists for.
	var out := ""
	for i in text.length():
		var c := text[i]
		if c == "[":
			out += "[lb]"
		elif c == "]":
			out += "[rb]"
		else:
			out += c
	return out


## Applies the word list, replacing matches in the original text.
##
## The match runs against a normalised copy — lowercased, leet undone, repeated
## letters collapsed, punctuation dropped — while the replacement is applied to the
## original. That is what makes the list catch a spelling it does not contain without
## rewriting everything else a player typed.
static func censor(text: String, rules: DotChatRules) -> String:
	if rules.censor_words.is_empty():
		return text

	var words := text.split(" ", true)
	var out := PackedStringArray()

	for raw in words:
		var word := str(raw)
		var probe := normalise(word) if rules.censor_normalises else word.to_lower()
		var hit := false

		for banned in rules.censor_words:
			var needle := str(banned).to_lower()
			if needle == "":
				continue
			if rules.censor_normalises:
				needle = normalise(needle)
			if needle != "" and probe.find(needle) >= 0:
				hit = true
				break

		out.append(rules.censor_replacement if hit else word)

	return " ".join(out)


## The form a censor list is matched against.
##
## Lowercase, leet substitutions undone, non-alphanumerics dropped, runs of the same
## letter collapsed to one. [code]f  r  e  e  m  o  n  e  y[/code],
## [code]fr33-m0n3y[/code] and [code]freeeee money[/code] all normalise together.
static func normalise(text: String) -> String:
	var lowered := text.to_lower()
	var mapped := ""

	for i in lowered.length():
		var c := lowered[i]
		if LEET.has(c):
			mapped += str(LEET[c])
			continue
		mapped += c

	var out := ""
	var previous := ""

	for i in mapped.length():
		var c := mapped[i]
		var is_letter := (c >= "a" and c <= "z")
		var is_digit := (c >= "0" and c <= "9")
		if not is_letter and not is_digit:
			continue
		if c == previous:
			continue
		previous = c
		out += c

	return out


## Whether a display name is fit to put beside a message.
##
## A name is not a message and does not go through [method sanitise]: it is drawn
## every line rather than once, so the limits are tighter and a name that fails is
## replaced rather than refused — a player whose name cannot be drawn still has to be
## able to be talked about.
static func clean_name(name: String, max_length: int = 32) -> String:
	var out := strip_invisible_chars(strip_controls(name, false))
	out = collapse(out, false).strip_edges()

	# Truncated before it is escaped, never after. Cutting an escaped string at a
	# character count can land inside `[lb]` and leave `[l` in the middle of a name,
	# which is markup again — the exact thing the escape was for.
	if out.length() > max_length:
		out = out.substr(0, max_length)

	out = escape_bbcode(out).strip_edges()

	if out == "":
		return "player"

	return out
