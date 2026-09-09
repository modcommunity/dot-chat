@tool
class_name DotChatRules
extends DotConfig

## Every policy chat has, in one layered configuration.
##
## Layered like every [DotConfig] in this family — exported defaults, then a JSON
## file, then the environment, then the command line — so an operator can raise the
## rate limit on a busy lobby without an export, and a test can set one field and
## leave the rest alone.
##
## [b]The defaults are the ones a public server wants, not the ones a demo wants.[/b]
## Chat is the only subsystem in a game where one player can put arbitrary text in
## front of every other player, and every default here exists because of something
## that has been done with that.

@export_group("Text")

## Longest message accepted, in characters.
##
## Characters rather than bytes: a byte cap cuts a UTF-8 sequence in half, and a
## client that validates its input then drops the whole line. A player writing in a
## script that is three bytes per character is not writing three times as much.
@export_range(1, 4096, 1) var max_length: int = 256

## Lines longer than this are refused rather than truncated.
##
## Truncating is friendlier and wrong: a player cannot see that it happened, so the
## end of a sentence simply vanishes, and a client that pastes a long URL gets a URL
## that goes somewhere else.
@export var refuse_over_length: bool = true

## Whether a message may contain line breaks.
##
## Off, because one message with forty of them is a wall that scrolls everything else
## out of every player's window at the cost of one line against the rate limit.
@export var allow_newlines: bool = false

## Escape BBCode markup so a [RichTextLabel] draws it as text.
##
## [b]On, and turning it off is a decision about your interface's integrity.[/b] A
## client that draws chat through a [RichTextLabel] with BBCode enabled has given
## every player the ability to draw arbitrary markup in every other player's window:
## colours, sizes, images by URL, and [code][url][/code] tags that turn a line into a
## link somewhere the reader did not choose. Escaping happens on the server, once,
## because a client that trusts its peers is one client away from all of it.
@export var escape_markup: bool = true

## Strip characters that let text lie about its own direction or length —
## zero-width spaces, bidirectional overrides, soft hyphens.
##
## A right-to-left override turns [code]txt.exe[/code] into something that reads as
## [code]exe.txt[/code], and a hundred zero-width joiners is an invisible message
## that costs nothing to send and breaks the layout of everybody who receives it.
@export var strip_invisible: bool = true

## Collapse runs of whitespace into a single space.
@export var collapse_whitespace: bool = true

@export_group("Rate")

## Messages per minute, sustained.
@export_range(1, 600, 1) var rate_per_minute: int = 20

## How many may be sent back to back before the sustained rate applies.
@export_range(1.0, 60.0, 1.0) var burst: float = 4.0

## Seconds a sender is silenced after exceeding the rate.
##
## Zero means "refuse this line and carry on", which is what a player who typed too
## fast deserves. A positive value is for a server that would rather a script that
## found the limit stopped being able to find it repeatedly.
@export_range(0.0, 300.0, 1.0) var flood_penalty_sec: float = 0.0

@export_group("Repetition")

## Seconds within which an identical message from the same sender is refused.
##
## 0 disables it. Repeating yourself once is normal; repeating yourself six times in
## eight seconds is the oldest form of chat spam there is and no rate limit generous
## enough to allow conversation will catch it.
@export_range(0.0, 300.0, 1.0) var duplicate_window_sec: float = 8.0

## How many messages back the duplicate check looks, per sender.
@export_range(1, 32, 1) var duplicate_depth: int = 3

@export_group("Commands")

## Prefixes that make a message a command rather than something to broadcast.
##
## Matches dot-server's [code]chat_command_prefixes[/code] default. A line starting
## with one of these is handed to the host instead of being sent to anybody, which is
## the only reason a mistyped [code]!ban[/code] does not appear in everybody's window.
@export var command_prefixes: PackedStringArray = PackedStringArray(["!", "/"])

## Whether a command that no handler claims is broadcast as an ordinary message.
##
## Off. A player who types [code]/rtv[/code] on a server without voting should be
## told nothing happened, not have it repeated to everybody as if they had said it.
@export var broadcast_unknown_commands: bool = false

@export_group("Filtering")

## Words replaced with [member censor_replacement], matched case-insensitively
## against a normalised form of the message.
##
## [b]dot-chat ships an empty list and no opinion about what belongs in it.[/b] What
## a community censors is that community's decision, and a default list would be one
## imposed by whoever wrote the addon.
@export var censor_words: PackedStringArray = PackedStringArray()

@export var censor_replacement: String = "***"

## Whether the censor normalises leet spelling and repeated letters before matching.
##
## Costs a pass over the message and is the difference between a list that works and
## one that is trivially stepped around.
@export var censor_normalises: bool = true

@export_group("History")

## Total lines the router keeps across every channel, as a backstop.
@export_range(0, 65536, 1) var history_limit: int = 1000


func env_prefix() -> String:
	return "DOT_CHAT_"


func cli_prefix() -> String:
	return "chat_"


func validate() -> DotResult:
	if max_length < 1:
		return DotResult.fail(DotError.CODE_INVALID, "max_length must be at least 1.")

	if rate_per_minute < 1:
		return DotResult.fail(DotError.CODE_INVALID, "rate_per_minute must be at least 1.")

	if burst < 1.0:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"burst below one message means nothing can ever be sent."
		)

	for prefix in command_prefixes:
		if str(prefix) == "":
			return DotResult.fail(
				DotError.CODE_INVALID,
				"An empty command prefix makes every message a command."
			)

	return DotResult.success(self)


## Messages per second, which is what [DotRateLimiter] takes.
func rate_per_second() -> float:
	return float(rate_per_minute) / 60.0


## Whether [param text] opens with a command prefix, and which one.
##
## Returns the prefix, or [code]""[/code].
func command_prefix_of(text: String) -> String:
	for prefix in command_prefixes:
		var p := str(prefix)
		if p != "" and text.begins_with(p):
			return p
	return ""
