@tool
class_name DotChatRelayConfig
extends DotConfig

## Everything the website relay needs, in one layered configuration.
##
## Layered like every [DotConfig] here — exported defaults, then a JSON file, then the
## environment, then the command line — so an operator can turn the relay on for one
## server without an export.
##
## [b]Every default here is OFF or conservative, and that is the point.[/b] A relay
## carries text between two populations who cannot see each other: people on a web page
## and people in a match. Turning that on is a decision an operator makes, not something
## that happens because an addon was installed — the same reasoning behind
## [code]pg_arena[/code] and [code]hungry_hunters_on[/code].

@export_group("Connection")

## Whether the relay runs at all.
##
## Off, because a server with no integration credential cannot relay anything and a
## relay that polls a backbone it cannot authenticate against is a red line in the log
## every few seconds. The host turns it on when it has a credential.
@export var enabled: bool = false

## How often the outbound poll runs, in seconds.
##
## Four seconds, matching the website panel's own [code]CHAT_POLL_MS[/code]. Faster is
## not better: the site's chat is a conversation between people typing, and a poll twice
## a second is fifty times the request rate for a latency nobody can perceive.
@export_range(0.5, 300.0, 0.5) var poll_seconds: float = 4.0

## How many site messages one poll may return.
##
## The endpoint caps this at 100 itself. Fifty is its own default and is far more than a
## single poll will ever have waiting; the number matters only for the FIRST poll after
## a server has been offline, which is exactly when a smaller number would drip-feed an
## hour of conversation into the game a page at a time.
@export_range(1, 100, 1) var poll_limit: int = 50

## The site's numeric id for this server, or 0 to let the credential decide.
##
## [b]Zero is the right answer for almost everybody.[/b] A server-scoped integration
## credential already names its server, and the endpoint refuses a [code]serverId[/code]
## that disagrees with it — so setting this can only ever match what the credential
## already says, or break. It exists for a deployment holding a credential that covers
## more than one server.
@export_range(0, 2147483647, 1) var server_id: int = 0

@export_group("In-game")

## Which channel a site line is announced on. Empty means the router's default.
@export var channel: StringName = &""

## The prefix put in front of a relayed line's author, in game.
##
## [b]A player has to be able to tell the two populations apart.[/b] Somebody on the
## website is not standing next to you, cannot see the match, and cannot be shot; a line
## from them that looks exactly like a line from the player beside you is a line that
## gets answered as though they were there.
@export var web_tag: String = "WEB"

## Whether lines typed IN GAME are sent to the website.
@export var send_game_chat: bool = true

## Whether lines typed on the WEBSITE are announced in game.
@export var receive_site_chat: bool = true

## Skip site lines the website itself marks as muted.
##
## The site dims these rather than hiding them, because there the author is visible in
## context. In game there is no context and no way to dim one line, so the default is to
## drop them.
@export var skip_muted: bool = true

@export_group("Commands")

## Whether a site line beginning with a command prefix runs as a console command.
##
## [b]Off, and this is the setting in this file that most deserves its default.[/b] It
## is a privilege path into a running server from a web page, used by somebody who is
## not connected to it and whose only proof of identity is the site session they wrote
## the message with. It is a real feature — every Discord admin relay has it — and it is
## not one that should switch itself on because a relay was configured.
##
## The permission check is the SERVER'S, always: the resolved uid goes to the server's
## own admin manager exactly as a connected player's would. This flag decides whether
## the question is asked at all, not what the answer is.
@export var allow_commands: bool = false

## Refuse a relayed command from an author the site could not identify.
##
## [b]True, and turning it off is almost certainly a mistake.[/b] A message with no
## author id cannot be resolved to a uid, so it cannot be checked against any permission
## — it can only be run as nobody or refused. There is no third option and running it as
## nobody is the one that ends badly.
@export var require_known_author: bool = true

## Prefix used to build a server uid from a site user id.
##
## [b]This is the seam for a server that does not use TMC's auth.[/b] dot-auth namespaces
## every identity by its provider — [code]backbone:clx8f2k0[/code],
## [code]steam:7656…[/code], [code]local:admin[/code] — so the uid an admin entry is
## keyed by depends on which provider authenticated them. The website relay's authors are
## site members, so the default is the backbone's namespace; a deployment whose admin
## file is keyed by its own provider sets this, or replaces
## [member DotChatRelay.uid_for_author] outright when the mapping is not a prefix.
@export var author_uid_prefix: String = "backbone:"

## How much a relayed command is trusted, as a [code]DotCmdContext.Source[/code].
##
## [b]3 is CHAT, and it is the default for a reason that bit.[/b] dot-server refuses a
## CHAT-sourced command unless it is marked [code]with_chat()[/code], and several games
## deliberately withhold that from their map commands — game-g2gfast's suite asserts it,
## because a map change destroys every run in progress and a records server does not let
## a player do that by typing. A relay defaulting to anything looser would quietly
## overrule a policy each game made on purpose.
##
## 2 is RCON, which is how an operator says "my site admins are remote administrators".
## That reaches everything RCON reaches, so it is a decision rather than a default — and
## it is still bounded by the person's own flags, never root.
##
## An int rather than the enum because dot-chat cannot name [DotCmdContext]: it depends
## on dot-core and nothing else, and the host is what owns a console.
@export_range(0, 4, 1) var command_source: int = 3

@export_group("Delivery")

## How many game lines are batched into one request.
@export_range(1, 100, 1) var send_batch: int = 20

## How many queued outbound lines are held before the oldest are dropped.
##
## A bounded queue, because the alternative is a server that cannot reach the backbone
## growing an array until it dies. Chat is the most droppable thing on a game server:
## a line nobody on the website reads is worth less than the match staying up.
@export_range(1, 100000, 1) var max_queued: int = 500

## Where the delivered-message cursor is kept.
##
## [b]It has to outlive the process.[/b] The cursor is the highest site message id this
## server has already put in front of its players; losing it means the next poll has no
## [code]since[/code] and the endpoint answers with the most recent page, which is an
## hour of the website's conversation arriving in the game at once. Empty uses
## [code]user://dot_chat_relay_cursor.json[/code].
@export var cursor_path: String = ""


func env_prefix() -> String:
	return "DOT_CHAT_RELAY_"


func cli_prefix() -> String:
	return "chat_relay_"


func validate() -> DotResult:
	if poll_seconds <= 0.0:
		return DotResult.fail(
			DotError.CODE_INVALID, "The relay poll interval must be positive."
		)

	if poll_limit < 1 or poll_limit > 100:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"The relay poll limit must be between 1 and 100.",
			str(poll_limit)
		)

	if send_batch < 1:
		return DotResult.fail(
			DotError.CODE_INVALID, "The relay send batch must be at least one."
		)

	if max_queued < send_batch:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"The relay queue must hold at least one batch.",
			"%d queued against a batch of %d" % [max_queued, send_batch]
		)

	# Commands without an author check is the one combination that is never right, and
	# refusing it here is cheaper than a server discovering it from an audit log.
	if allow_commands and not require_known_author:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Relayed commands need require_known_author: an unidentified author "
				+ "cannot be checked against any permission."
		)

	return DotResult.success(self)

