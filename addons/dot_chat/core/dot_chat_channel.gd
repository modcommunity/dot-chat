@tool
class_name DotChatChannel
extends Resource

## One place people can talk, and the rule for who hears it.
##
## A game has more of these than it first thinks: everybody, the team, the dead, the
## party, the admins, and the server's own announcements. They differ in exactly two
## interesting ways — who receives a line, and what a sender must be in order to put
## one there — so they are one resource with a scope rather than one class each.
##
## [b]Membership is asked, never stored here.[/b] Which team a peer is on is a fact
## the game owns and changes every round; a channel that kept its own roster would be
## a second copy of it, and the second copy is the one that goes stale. A channel
## says [i]how[/i] to find the audience and [DotChatRouter] supplies the callables
## that answer.

## How the audience for a line is worked out.
enum Scope {
	## Everybody connected. The default channel of most games.
	EVERYONE,
	## Everybody whose team matches the sender's, as reported by the router's
	## [code]team_fn[/code]. A sender with no team reaches nobody, which is correct:
	## a spectator typing on the team channel must not be broadcast to a team.
	TEAM,
	## Everybody within [member radius] of the sender, by the router's
	## [code]position_fn[/code]. Proximity chat.
	RADIUS,
	## Exactly the sender and one named recipient.
	DIRECT,
	## Everybody the router's [code]membership_fn[/code] says belongs to this channel
	## — a clan, the admins, the dead. For a channel of many small groups at once — a
	## party each — set [member grouped] as well.
	MEMBERS,
}

@export_group("Identity")

## Stable id used on the wire and in commands. Lowercase, no spaces.
@export var id: StringName = &""

## What a player sees in a channel picker.
@export var display_name: String = ""

## Drawn before the name, e.g. [code](TEAM)[/code]. Server-side only, so a player
## cannot type one.
@export var prefix: String = ""

## A hint for the client's formatter. dot-chat draws nothing itself.
@export var colour: Color = Color(1, 1, 1)

@export_group("Audience")

@export var scope: Scope = Scope.EVERYONE

## Metres for [constant Scope.RADIUS]. Ignored otherwise.
@export_range(1.0, 10000.0, 1.0) var radius: float = 25.0

## For [constant Scope.MEMBERS]: a line reaches only the peers in the [i]sender's[/i]
## group, as the router's [code]group_fn[/code] answers it.
##
## [b]Why membership alone cannot do this.[/b] [code]membership_fn(peer, channel)[/code]
## is asked about the receiver and never hears who is talking, so on a server with three
## parties a "party" channel built on it reaches all three — every party member on the
## server reads every other party's line. The question a party channel needs is "same
## group as the sender", and only a rule that is handed the sender can ask it.
##
## [b]Opt-in per channel, not per router.[/b] A router may carry a plain members channel
## (the players on a run, the dead) beside a grouped one, and a router-wide switch would
## make every one of those reach nobody the day a host set [code]group_fn[/code].
##
## A sender with no group reaches nobody but themselves, for the reason a teamless sender
## on a team channel does. A grouped channel on a router with no [code]group_fn[/code]
## reaches nobody either: failing closed is the only answer that cannot leak one party's
## line to another.
@export var grouped: bool = false

## Whether the sender receives their own line back.
##
## On by default and worth leaving on: a client that draws its own line locally and
## does not wait for the server shows the player a message that may have been refused
## for flooding, and the player then repeats it.
@export var echo_to_sender: bool = true

@export_group("Permission")

## Only a peer the router's [code]is_admin_fn[/code] approves may send here.
@export var admin_only: bool = false

## Nobody may send here at all. For a channel the server writes to alone.
@export var server_only: bool = false

## A gag does not silence this channel.
##
## [b]Off for anything a player types.[/b] It exists for a channel carrying join and
## leave notices, where the "sender" is a person but the line is the server's.
@export var ignores_gag: bool = false

## What one line costs against the sender's rate budget. A channel that reaches
## everybody can be made more expensive than one that reaches four people.
@export_range(0.0, 16.0, 0.5) var rate_cost: float = 1.0

@export_group("History")

## Lines kept for this channel. 0 keeps none.
@export_range(0, 4096, 1) var history_limit: int = 200

## How many past lines a joining player is handed.
##
## [b]Capped separately from [member history_limit] and usually much smaller.[/b]
## Team chat backlog handed to somebody who has just joined the other team is a leak,
## which is why a channel that is not [constant Scope.EVERYONE] defaults to none.
@export_range(0, 256, 1) var backlog: int = 0


static func make(
	p_id: StringName, p_display_name: String, p_scope: Scope = Scope.EVERYONE
) -> DotChatChannel:
	var out := DotChatChannel.new()
	out.id = p_id
	out.display_name = p_display_name
	out.scope = p_scope
	if p_scope != Scope.EVERYONE:
		out.backlog = 0
	return out


## The channel every game has: everybody, no permission, a bit of backlog.
static func everyone() -> DotChatChannel:
	var out := make(&"all", "All")
	out.backlog = 20
	return out


## Team chat. No backlog, for the reason on [member backlog].
static func team() -> DotChatChannel:
	var out := make(&"team", "Team", Scope.TEAM)
	out.prefix = "(TEAM)"
	out.colour = Color(0.45, 0.85, 0.55)
	return out


## One conversation per group — a party, a squad — on one channel id. See [member grouped].
## No backlog, for the reason on [member backlog].
static func group(p_id: StringName, p_display_name: String) -> DotChatChannel:
	var out := make(p_id, p_display_name, Scope.MEMBERS)
	out.grouped = true
	out.prefix = "(%s)" % p_display_name.to_upper()
	out.colour = Color(0.55, 0.75, 1.0)
	return out


## Whispers. One channel serves every pair; the recipient is on the message.
static func direct() -> DotChatChannel:
	var out := make(&"whisper", "Whisper", Scope.DIRECT)
	out.prefix = "(WHISPER)"
	out.colour = Color(0.85, 0.6, 0.9)
	out.history_limit = 50
	return out


func validate() -> DotResult:
	if String(id).strip_edges() == "":
		return DotResult.fail(DotError.CODE_INVALID, "A channel needs an id.")

	# Not is_valid_identifier(): that answers "may this be a variable name", and one
	# may not begin with a digit — which is how dot-timer's records sanitiser turned
	# every digit in a map id into an underscore and merged two maps' leaderboards
	# into one file.
	for i in String(id).length():
		var c := String(id)[i]
		if not (c >= "a" and c <= "z") and not (c >= "0" and c <= "9") and c != "_":
			return DotResult.fail(
				DotError.CODE_INVALID,
				"A channel id may only contain a-z, 0-9 and underscores.",
				String(id)
			)

	if scope == Scope.RADIUS and radius <= 0.0:
		return DotResult.fail(
			DotError.CODE_INVALID, "A radius channel needs a positive radius.", String(id)
		)

	if grouped and scope != Scope.MEMBERS:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"Only a members channel can be grouped.",
			"%s: scope %s" % [String(id), scope_name()]
		)

	if backlog > history_limit:
		return DotResult.fail(
			DotError.CODE_INVALID,
			"A channel cannot hand out more backlog than it keeps.",
			"%s: backlog %d, history %d" % [String(id), backlog, history_limit]
		)

	return DotResult.success(self)


func scope_name() -> String:
	return ["everyone", "team", "radius", "direct", "members"][int(scope)]


func describe() -> String:
	return "%s (%s, scope %s%s, history %d)" % [
		String(id), display_name, scope_name(), ", grouped" if grouped else "", history_limit
	]


func _to_string() -> String:
	return "DotChatChannel(%s)" % String(id)
