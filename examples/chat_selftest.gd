extends Node

## Exercises dot-chat with no transport and no other addon.
##
## The router is given callables that answer out of dictionaries, which is exactly
## the seam a real host fills with its session table — so every check here is about
## what this addon promises: that a line a player typed cannot draw markup in anybody
## else's window, that a channel's audience is the one it says, that a gag registered
## by something the addon never names is consulted, and that both ends of the wire
## form agree.
##
## [codeblock]
## godot --headless --path . res://examples/chat_selftest.tscn
## [/codeblock]

const SECTIONS := 16
const CHECKS := 149

## Built rather than typed. A source file containing a real zero-width space is one
## whose diff, review and grep all lie about what it says.
const ZERO_WIDTH := 0x200B
const RIGHT_TO_LEFT_OVERRIDE := 0x202E
const BELL := 0x07

var _passed := 0
var _failed := 0
var _section_count := 0


## A stand-in for dot-moderation's manager, which this addon never names.
##
## It answers one duck-typed method, which is the whole integration.
class FakeMuteSource extends Node:
	var gagged: Array[int] = []

	func is_chat_muted(peer: int) -> bool:
		return gagged.has(peer)


## The host's session table, in the smallest form that still has every field the
## router asks for.
## A backbone that records what it was sent and answers what it was told to.
##
## [b]Duck-typed on purpose, exactly as the real one is.[/b] `DotChatRelay.client` is an
## [Object] and is never named, because a script mentioning `DotBackboneClient` fails to
## compile in a project without dot-auth — which is this one. That the relay's own suite
## can substitute a plain RefCounted here is the proof that the seam is real.
class FakeBackbone extends RefCounted:
	var posted: Array[Dictionary] = []
	var outbound: Array[Dictionary] = []
	var newest: String = ""
	var queries: Array[Dictionary] = []
	var fail_post: bool = false

	func post_integration(path: String, body: Dictionary) -> DotResult:
		if fail_post:
			return DotResult.fail(DotError.CODE_NETWORK, "nope")
		posted.append({"path": path, "body": body})
		return DotResult.success({"ok": true, "id": str(posted.size())})

	func get_integration(path: String, query: Dictionary = {}) -> DotResult:
		queries.append({"path": path, "query": query.duplicate(true)})
		var rows := outbound.duplicate(true)
		outbound.clear()
		return DotResult.success({
			"ok": true, "messages": rows, "newest": newest,
		})


class FakeWorld extends RefCounted:
	var names: Dictionary = {}
	var keys: Dictionary = {}
	var teams: Dictionary = {}
	var places: Dictionary = {}
	var admins: Array[int] = []
	var sent: Array[Dictionary] = []

	func add(
		peer: int, name: String, team: StringName = &"", at: Vector3 = Vector3.ZERO
	) -> void:
		names[peer] = name
		keys[peer] = "u_%d" % peer
		teams[peer] = team
		places[peer] = at

	func peers() -> PackedInt32Array:
		var out := PackedInt32Array()
		var ids: Array = names.keys()
		ids.sort()
		for id in ids:
			out.append(int(id))
		return out

	func wire_up(router: DotChatRouter) -> void:
		router.peers_fn = peers
		router.name_fn = func(peer: int) -> String: return str(names.get(peer, ""))
		router.key_fn = func(peer: int) -> String: return str(keys.get(peer, ""))
		router.team_fn = func(peer: int) -> StringName:
			return StringName(str(teams.get(peer, &"")))
		router.position_fn = func(peer: int) -> Vector3:
			return places.get(peer, Vector3.ZERO)
		router.is_admin_fn = func(peer: int) -> bool: return admins.has(peer)
		router.send_fn = func(wire: Dictionary, to: PackedInt32Array) -> void:
			sent.append({"wire": wire.duplicate(true), "to": Array(to)})


func _ready() -> void:
	DotLog.set_level(DotLog.Level.ERROR)
	_run()


func _run() -> void:
	_line("dot-chat self-test")
	_line("")

	_test_message_wire()
	_test_channel_validation()
	_test_rules()
	_test_filter_text()
	_test_filter_censor()
	_test_history()
	_test_router_basics()
	_test_router_audience()
	_test_router_limits()
	_test_router_gag()
	_test_router_commands()
	_test_backlog()
	_test_client()
	_test_format()
	await _test_relay_out()
	await _test_relay_in()

	_line("")
	_line("%d sections, %d passed, %d failed" % [_section_count, _passed, _failed])

	# A script error inside a test aborts THAT test, not the run — a suite can report
	# "all passed" while quietly running fewer checks than it has. The section count
	# is what notices.
	if _section_count != SECTIONS:
		_line("ERROR: %d of %d sections ran." % [_section_count, SECTIONS])
		get_tree().quit(1)
		return

	# The total the section counter cannot be. A runtime error inside a section aborts
	# that function, and the counter is satisfied because the section had already
	# announced itself. See docs/testing.md.
	if _passed + _failed != CHECKS:
		print("ERROR: %d checks ran, %d expected. A section aborted part-way." % [
			_passed + _failed, CHECKS
		])
		get_tree().quit(1)
		return
	get_tree().quit(1 if _failed > 0 else 0)


# --- The wire form ---------------------------------------------------------

func _test_message_wire() -> void:
	_section("message wire form")

	var message := DotChatMessage.say(&"all", "u_1", "Ada", "hello")
	message.seq = 7
	message.meta = {"team": "red"}

	var wire := message.to_dictionary()
	_check(not wire.has("sender_peer"), "the peer id is not on the wire")

	var back := DotChatMessage.from_dictionary(wire)
	_check(back.ok, "a message round-trips")

	var restored: DotChatMessage = back.value
	_check(restored.seq == 7, "seq survives")
	_check(restored.channel == &"all", "channel survives")
	_check(restored.sender_name == "Ada", "name survives")
	_check(restored.text == "hello", "text survives")
	_check(str(restored.meta.get("team", "")) == "red", "meta survives")

	restored.meta["team"] = "blue"
	_check(
		str(message.meta.get("team", "")) == "red",
		"meta is copied, not shared with the original"
	)

	# Every value of the enum, both directions. dot-moderation stored a voice mute
	# under its player-facing name and read it back as a warning, which enforced
	# nothing and errored nowhere; one table used both ways is the fix and this is
	# the check that says the table is complete.
	var all_kinds := true
	for value in DotChatMessage.Kind.values():
		var probe := DotChatMessage.make(value, &"all", "u_1", "Ada", "x")
		if DotChatMessage.kind_from_name(probe.kind_name()) != value:
			all_kinds = false
	_check(all_kinds, "every Kind round-trips through its name")

	_check(
		DotChatMessage.kind_from_name("voice muted") == -1,
		"an unknown kind name is refused rather than defaulted to SAY"
	)

	var bad := DotChatMessage.from_dictionary({"k": "nonsense", "m": "hi"})
	_check(not bad.ok and bad.code() == DotError.CODE_PARSE, "a bad kind fails to parse")


func _test_channel_validation() -> void:
	_section("channel validation")

	_check(DotChatChannel.everyone().validate().ok, "the default channel validates")

	var bad := DotChatChannel.make(&"Team Chat", "Team")
	_check(not bad.validate().ok, "a channel id with a space is refused")

	# is_valid_identifier() would refuse this, because an identifier may not begin
	# with a digit. A channel id is not an identifier.
	var digits := DotChatChannel.make(&"2v2", "Duos")
	_check(digits.validate().ok, "a channel id may begin with a digit")

	var over := DotChatChannel.everyone()
	over.history_limit = 5
	over.backlog = 20
	_check(
		not over.validate().ok,
		"a channel cannot hand out more backlog than it keeps"
	)

	_check(
		DotChatChannel.team().backlog == 0,
		"a team channel hands out no backlog by default"
	)


func _test_rules() -> void:
	_section("rules")

	var rules := DotChatRules.new()
	_check(rules.validate().ok, "the defaults validate")
	_check(
		is_equal_approx(rules.rate_per_second(), 20.0 / 60.0),
		"the rate converts to seconds"
	)

	_check(rules.command_prefix_of("!rtv") == "!", "a bang is a command prefix")
	_check(rules.command_prefix_of("/me waves") == "/", "a slash is a command prefix")
	_check(rules.command_prefix_of("hello") == "", "an ordinary line is not a command")

	var empty := DotChatRules.new()
	empty.command_prefixes = PackedStringArray([""])
	_check(
		not empty.validate().ok,
		"an empty command prefix is refused: it would make every line a command"
	)

	var applied := rules.apply_dictionary({"max_length": 64, "rate_per_minute": 5})
	_check(applied.size() == 2 and rules.max_length == 64, "a layer applies")


func _test_filter_text() -> void:
	_section("filter: text")

	var rules := DotChatRules.new()

	var markup := DotChatFilter.sanitise("[color=red]red[/color]", rules)
	_check(markup.ok, "markup is accepted as text")
	_check(
		not str(markup.value).contains("[color"),
		"markup is escaped rather than passed through"
	)
	_check(
		str(markup.value) == "[lb]color=red[rb]red[lb]/color[rb]",
		"the escape is the engine's own, so a plain Label is still legible"
	)

	var controls := DotChatFilter.sanitise(
		"ab" + String.chr(BELL) + "c", rules
	)
	_check(controls.ok and str(controls.value) == "abc", "control characters are removed")

	var invisible := DotChatFilter.sanitise(
		"hi" + String.chr(ZERO_WIDTH).repeat(3) + "there", rules
	)
	_check(str(invisible.value) == "hithere", "zero-width characters are removed")

	var bidi := DotChatFilter.sanitise(
		"safe" + String.chr(RIGHT_TO_LEFT_OVERRIDE) + "txt.exe", rules
	)
	_check(
		not str(bidi.value).contains(String.chr(RIGHT_TO_LEFT_OVERRIDE)),
		"a direction override is removed"
	)

	var only_invisible := DotChatFilter.sanitise(
		String.chr(ZERO_WIDTH).repeat(4), rules
	)
	_check(
		not only_invisible.ok,
		"a message that is empty once cleaned is refused, not sent blank"
	)

	var spaces := DotChatFilter.sanitise("a          b", rules)
	_check(str(spaces.value) == "a b", "runs of spaces collapse")

	var newlines := DotChatFilter.sanitise("one\ntwo", rules)
	_check(
		not str(newlines.value).contains("\n"),
		"newlines become spaces when they are not allowed"
	)

	var long := DotChatFilter.sanitise("x".repeat(rules.max_length + 1), rules)
	_check(
		not long.ok and long.code() == DotError.CODE_INVALID,
		"an over-length message is refused rather than truncated"
	)

	# Escaping lengthens a string. Measuring afterwards would refuse a message the
	# player typed inside the limit for containing brackets.
	var bracketed := DotChatFilter.sanitise("[".repeat(rules.max_length), rules)
	_check(
		bracketed.ok,
		"length is measured before escaping, so brackets do not eat the limit"
	)

	_check(DotChatFilter.clean_name("") == "player", "an empty name is replaced")
	_check(
		not DotChatFilter.clean_name("[b]boss[/b]").contains("[b]"),
		"a name is escaped too"
	)
	_check(
		not DotChatFilter.clean_name("[".repeat(64), 8).ends_with("[l"),
		"a name is truncated before it is escaped, never after"
	)


func _test_filter_censor() -> void:
	_section("filter: censoring")

	var rules := DotChatRules.new()
	rules.censor_words = PackedStringArray(["freemoney"])

	var plain := DotChatFilter.sanitise("buy freemoney now", rules)
	_check(str(plain.value) == "buy *** now", "a listed word is replaced")

	var leet := DotChatFilter.sanitise("buy fr33m0n3y now", rules)
	_check(
		str(leet.value) == "buy *** now",
		"leet spelling normalises onto the same word"
	)

	var stretched := DotChatFilter.sanitise("buy freeeemoneyyy now", rules)
	_check(
		str(stretched.value) == "buy *** now",
		"repeated letters normalise onto the same word"
	)

	var innocent := DotChatFilter.sanitise("buy nothing now", rules)
	_check(str(innocent.value) == "buy nothing now", "everything else is untouched")

	_check(
		DotChatFilter.normalise("fr33-m0n3y") == "fremoney",
		"normalise collapses leet, punctuation and doubles"
	)


func _test_history() -> void:
	_section("history")

	var history := DotChatHistory.new(6)
	history.set_limit(&"all", 3)
	history.set_limit(&"team", 3)

	for i in 5:
		history.append(DotChatMessage.say(&"all", "u_1", "Ada", "line %d" % i))

	_check(history.channel_size(&"all") == 3, "a channel is capped")
	_check(
		str(history.recent(&"all", 3)[0].text) == "line 2",
		"the oldest lines are the ones dropped"
	)

	for i in 4:
		history.append(DotChatMessage.say(&"team", "u_2", "Bo", "team %d" % i))

	_check(history.size() <= 6, "the total cap holds across channels")

	var copies := history.recent(&"team", 2)
	copies[0].text = "rewritten"
	_check(
		str(history.recent(&"team", 2)[0].text) != "rewritten",
		"history hands out copies, not its own objects"
	)

	_check(history.by_sender("u_2").size() > 0, "history can be read by sender")

	var zero := DotChatHistory.new(10)
	zero.set_limit(&"nowhere", 0)
	zero.append(DotChatMessage.say(&"nowhere", "u_1", "Ada", "x"))
	_check(zero.size() == 0, "a channel with no history keeps none")


# --- The router ------------------------------------------------------------

func _make_router(world: FakeWorld) -> DotChatRouter:
	var router := DotChatRouter.new()
	router.register_as = &""
	router.rules = DotChatRules.new()

	# Generous on purpose. Every section other than the rate one is asking a question
	# about routing, and a router with the shipped limits refuses the fifth line a
	# test peer sends — which reads as "an admin cannot use the admin channel".
	router.rules.rate_per_minute = 600
	router.rules.burst = 60.0
	router.rules.duplicate_window_sec = 0.0

	world.wire_up(router)
	add_child(router)
	return router


func _test_router_basics() -> void:
	_section("router: the ordinary path")

	var world := FakeWorld.new()
	world.add(1, "Ada")
	world.add(2, "Bo")

	var router := _make_router(world)

	var res := router.submit(1, &"all", "hello")
	_check(res.ok, "an ordinary line is accepted")

	var message: DotChatMessage = res.value
	_check(message.sender_name == "Ada", "the name comes from the host, not the client")
	_check(message.sender_key == "u_1", "the durable key is stamped")
	_check(message.seq == 1, "sequence numbers start at one")

	_check(world.sent.size() == 1, "one send")
	var to: Array = world.sent[0]["to"]
	_check(to.size() == 2 and to.has(1) and to.has(2), "everybody received it")

	var wire: Dictionary = world.sent[0]["wire"]
	_check(not wire.has("sender_peer"), "the wire form carries no peer ids")

	_check(router.history.channel_size(&"all") == 1, "it is in history")

	var missing := router.submit(1, &"nowhere", "hello")
	_check(
		not missing.ok and missing.code() == DotError.CODE_STATE,
		"an unknown channel is a state failure"
	)

	var quiet := router.submit(1, &"all", "   ")
	_check(not quiet.ok, "whitespace is not a message")

	router.queue_free()


func _test_router_audience() -> void:
	_section("router: audience")

	var world := FakeWorld.new()
	world.add(1, "Ada", &"red", Vector3.ZERO)
	world.add(2, "Bo", &"red", Vector3(100, 0, 0))
	world.add(3, "Cy", &"blue", Vector3(5, 0, 0))
	world.add(4, "Di", &"", Vector3(1, 0, 0))

	var router := _make_router(world)

	var team := router.submit(1, &"team", "push B")
	_check(team.ok, "a team line is accepted")
	var team_to: Array = world.sent[-1]["to"]
	_check(
		team_to.size() == 2 and team_to.has(1) and team_to.has(2),
		"team chat reaches the team and nobody else"
	)

	var spectator := router.submit(4, &"team", "hello team")
	_check(spectator.ok, "a teamless sender is not refused")
	var spec_to: Array = world.sent[-1]["to"]
	_check(
		spec_to.size() == 1 and spec_to.has(4),
		"a sender with no team reaches nobody but themselves"
	)

	var proximity := DotChatChannel.make(&"near", "Nearby", DotChatChannel.Scope.RADIUS)
	proximity.radius = 10.0
	router.add_channel(proximity)

	var close := router.submit(1, &"near", "over here")
	_check(close.ok, "a radius line is accepted")
	var near_to: Array = world.sent[-1]["to"]
	_check(
		near_to.has(3) and near_to.has(4) and not near_to.has(2),
		"a radius channel reaches only what is inside it"
	)

	var whispered := router.whisper(1, 3, "just you")
	_check(whispered.ok, "a whisper is accepted")
	var whisper_to: Array = world.sent[-1]["to"]
	_check(
		whisper_to.size() == 2 and whisper_to.has(1) and whisper_to.has(3),
		"a whisper reaches exactly two peers"
	)
	var whisper_wire: Dictionary = world.sent[-1]["wire"]
	_check(
		str(whisper_wire.get("w", "")) == "u_3" and not whisper_wire.has("target_peer"),
		"a whisper carries the target's key and not their peer id"
	)

	_check(not router.whisper(1, 1, "hi").ok, "you cannot whisper to yourself")

	var no_echo := DotChatChannel.make(&"silent", "Silent")
	no_echo.echo_to_sender = false
	router.add_channel(no_echo)
	router.submit(1, &"silent", "not to me")
	var silent_to: Array = world.sent[-1]["to"]
	_check(not silent_to.has(1), "a channel that does not echo does not echo")

	var admin_only := DotChatChannel.make(&"admins", "Admins")
	admin_only.admin_only = true
	router.add_channel(admin_only)
	_check(
		not router.submit(1, &"admins", "hi").ok,
		"a non-admin cannot use an admin channel"
	)
	world.admins.append(1)
	_check(router.submit(1, &"admins", "hi").ok, "an admin can")

	var server_only := DotChatChannel.make(&"news", "News")
	server_only.server_only = true
	router.add_channel(server_only)
	_check(
		not router.submit(1, &"news", "hi").ok,
		"nobody may type into a server-only channel"
	)
	_check(router.announce("the map is changing", &"news").ok, "the server may")

	router.queue_free()


func _test_router_limits() -> void:
	_section("router: rate and repetition")

	var world := FakeWorld.new()
	world.add(1, "Ada")

	var router := DotChatRouter.new()
	router.register_as = &""
	router.rules = DotChatRules.new()
	router.rules.rate_per_minute = 60
	router.rules.burst = 3.0
	router.rules.duplicate_window_sec = 30.0
	world.wire_up(router)
	add_child(router)

	var accepted := 0
	var limited := 0
	for i in 10:
		var res := router.submit(1, &"all", "line %d" % i)
		if res.ok:
			accepted += 1
		elif res.code() == DotError.CODE_RATE_LIMITED:
			limited += 1

	_check(accepted <= 4, "the burst is the ceiling on back-to-back lines")
	_check(limited > 0, "the rest are refused as rate limited")

	var fresh := FakeWorld.new()
	fresh.add(1, "Ada")
	var repeater := _make_router(fresh)
	repeater.rules.duplicate_window_sec = 30.0

	_check(repeater.submit(1, &"all", "same").ok, "the first one is fine")
	var again := repeater.submit(1, &"all", "same")
	_check(
		not again.ok and again.code() == DotError.CODE_RATE_LIMITED,
		"the same line twice inside the window is refused"
	)
	_check(repeater.submit(1, &"all", "different").ok, "a different line is not")

	repeater.forget(1)
	_check(
		repeater.submit(1, &"all", "same").ok,
		"forgetting a peer forgets what they said"
	)

	router.queue_free()
	repeater.queue_free()


func _test_router_gag() -> void:
	_section("router: gags")

	var world := FakeWorld.new()
	world.add(1, "Ada")
	world.add(2, "Bo")

	var router := _make_router(world)
	_check(not router.is_gagged(1), "nobody is gagged with no source registered")

	var source := FakeMuteSource.new()
	add_child(source)
	DotRegistry.register(DotChatRouter.MUTE_SERVICE, source)

	source.gagged.append(1)
	_check(router.is_gagged(1), "a registered mute source is consulted")

	var refused := router.submit(1, &"all", "hello")
	_check(
		not refused.ok and refused.code() == DotError.CODE_FORBIDDEN,
		"a gagged player cannot speak"
	)
	_check(router.submit(2, &"all", "hello").ok, "everybody else still can")

	var announced := router.announce("round over")
	_check(announced.ok, "a gag does not silence the server")

	var notices := DotChatChannel.make(&"notices", "Notices")
	notices.ignores_gag = true
	router.add_channel(notices)
	_check(
		router.join_notice(1, &"notices").ok,
		"a channel that ignores gags carries a gagged player's join notice"
	)

	DotRegistry.unregister(DotChatRouter.MUTE_SERVICE)
	source.queue_free()
	router.queue_free()


func _test_router_commands() -> void:
	_section("router: commands")

	var world := FakeWorld.new()
	world.add(1, "Ada")

	var router := _make_router(world)

	var seen: Array[Dictionary] = []
	router.command_entered.connect(
		func(peer: int, command: String, args: PackedStringArray, raw: String) -> void:
			# A lambda captures locals by value, so a counter incremented in here stays
			# zero outside it. Append to a captured Array instead.
			seen.append({
				"peer": peer, "command": command, "args": Array(args), "raw": raw
			})
	)

	var before := world.sent.size()
	var res := router.submit(1, &"all", "!ban 3 spamming")
	_check(res.ok, "a command is not a failure")
	_check(res.value == null, "a command produces no message")
	_check(world.sent.size() == before, "and is not broadcast to anybody")
	_check(seen.size() == 1, "the host is told about it")
	_check(str(seen[0]["command"]) == "ban", "the command name is lowercased and split")
	_check((seen[0]["args"] as Array).size() == 2, "the arguments are split")

	var action := router.submit(1, &"all", "/me waves")
	_check(action.ok and action.value != null, "/me is handled by the router")
	var message: DotChatMessage = action.value
	_check(message.kind == DotChatMessage.Kind.ACTION, "and produces an ACTION")
	_check(message.text == "waves", "with the prefix removed")

	_check(router.is_command("!rtv"), "is_command answers before submitting")
	_check(not router.is_command("rtv"), "and says no to an ordinary line")

	router.queue_free()


func _test_backlog() -> void:
	_section("backlog")

	var world := FakeWorld.new()
	world.add(1, "Ada", &"red")
	world.add(2, "Bo", &"blue")

	var router := _make_router(world)

	for i in 5:
		router.submit(1, &"all", "public %d" % i)
	router.submit(1, &"team", "secret")

	var joining := router.backlog_for(2)
	_check(joining.size() > 0, "a joining player is handed something")

	var any_team := false
	for entry in joining:
		if str(entry.get("c", "")) == "team":
			any_team = true
	_check(
		not any_team,
		"and it is not the other team's chat: backlog runs the same audience test"
	)

	var ordered := true
	for i in range(1, joining.size()):
		if int(joining[i].get("n", 0)) < int(joining[i - 1].get("n", 0)):
			ordered = false
	_check(ordered, "the backlog is in sequence order")

	router.queue_free()


func _test_client() -> void:
	_section("client")

	var world := FakeWorld.new()
	world.add(1, "Ada")
	var router := _make_router(world)

	var client := DotChatClient.new()
	client.register_as = &""
	client.rules = DotChatRules.new()
	client.channels = [DotChatChannel.everyone(), DotChatChannel.team()]
	client.active_channel = &"all"
	add_child(client)

	var outgoing: Array[String] = []
	client.send_fn = func(text: String, channel_id: StringName) -> void:
		outgoing.append(text)

	var composed := client.compose(&"all", "[b]hello[/b]")
	_check(composed.ok, "an ordinary line composes")
	_check(outgoing.size() == 1, "and reaches the server unformatted")
	_check(
		str(outgoing[0]) == "[b]hello[/b]",
		"the client sends what was typed: escaping is the server's job"
	)

	var too_long := client.compose(&"all", "x".repeat(4000))
	_check(
		not too_long.ok,
		"the client refuses locally what the server would refuse"
	)
	_check(outgoing.size() == 1, "and does not send it")

	var command := client.compose(&"all", "!rtv")
	_check(
		command.ok and outgoing.size() == 2,
		"a command is passed through: the server owns the command table"
	)

	router.submit(1, &"all", "from the server")
	var wire: Dictionary = world.sent[-1]["wire"]

	var received: Array[DotChatMessage] = []
	client.message_received.connect(
		func(message: DotChatMessage, _channel: StringName) -> void:
			received.append(message)
	)

	_check(client.receive(wire).ok, "a wire message is filed")
	_check(received.size() == 1, "and announced")
	_check(client.history.size() == 1, "and kept")

	_check(client.receive(wire).ok, "a repeat is accepted")
	_check(client.history.size() == 1, "and dropped rather than drawn twice")

	var gaps: Array[Dictionary] = []
	client.gap_detected.connect(func(expected: int, got: int) -> void:
		gaps.append({"expected": expected, "got": got}))

	var future := wire.duplicate(true)
	future["n"] = int(wire.get("n", 0)) + 5
	client.receive(future)
	_check(gaps.size() == 1, "a gap in the sequence is reported")

	client.set_active_channel(&"team")
	var later := wire.duplicate(true)
	later["n"] = 900
	client.receive(later)
	_check(client.unread(&"all") == 1, "a line on another channel counts as unread")
	client.set_active_channel(&"all")
	_check(client.unread(&"all") == 0, "and is cleared when the channel is opened")

	var lines := client.lines(&"all", 10)
	_check(lines.size() > 0, "formatted lines come out")

	client.queue_free()
	router.queue_free()


func _test_format() -> void:
	_section("formatting")

	var chan := DotChatChannel.team()
	var message := DotChatMessage.say(&"team", "u_1", "Ada", "push [lb]B[rb]")

	var line := DotChatFormat.line(message, chan)
	_check(line.contains("(TEAM)"), "the channel prefix is drawn")
	_check(line.contains("Ada:"), "the name is drawn")
	_check(
		line.contains("push [lb]B[rb]"),
		"the escaped text stays escaped on the way to a RichTextLabel"
	)

	var system := DotChatFormat.line(DotChatMessage.system(&"all", "map changing"))
	_check(not system.contains("Ada"), "a system line is not attributed to anybody")

	var action := DotChatMessage.make(
		DotChatMessage.Kind.ACTION, &"all", "u_1", "Ada", "waves"
	)
	_check(DotChatFormat.line(action).contains("* Ada waves"), "an action reads as one")

	_check(
		DotChatFormat.plain(message).contains("push [B]"),
		"the plain form puts the brackets back for a destination with no parser"
	)


# --- The website relay -----------------------------------------------------

func _relay_world() -> Array:
	var world := FakeWorld.new()
	world.add(1, "Ada")
	world.add(2, "Bo")

	var router := DotChatRouter.new()
	router.rules = DotChatRules.new()
	world.wire_up(router)
	add_child(router)

	var backbone := FakeBackbone.new()
	var cfg := DotChatRelayConfig.new()
	cfg.enabled = true
	cfg.cursor_path = "user://relay_selftest_cursor.json"

	var relay := DotChatRelay.new()
	relay.router = router
	relay.config = cfg
	relay.client = backbone
	relay.register_as = &""

	return [world, router, backbone, cfg, relay]


func _test_relay_out() -> void:
	_section("relay: what the game says reaches the site")

	var bits := _relay_world()
	var world: FakeWorld = bits[0]
	var router: DotChatRouter = bits[1]
	var backbone: FakeBackbone = bits[2]
	var cfg: DotChatRelayConfig = bits[3]
	var relay: DotChatRelay = bits[4]

	# No poll timer for this half — receive_site_chat off keeps the test to one direction.
	cfg.receive_site_chat = false
	add_child(relay)
	await get_tree().process_frame

	var said := router.submit(1, router.default_channel(), "hello from the match")
	_check(said.ok, "a player says something")
	await get_tree().process_frame

	_check(backbone.posted.size() == 1,
		"and exactly one line was posted (%d)" % backbone.posted.size())

	if backbone.posted.size() > 0:
		var body: Dictionary = backbone.posted[0]["body"]
		_check(str(backbone.posted[0]["path"]) == "chat", "to the chat endpoint")
		_check(str(body.get("body", "")) == "hello from the match", "with the text")
		var player: Dictionary = body.get("player", {})
		_check(str(player.get("name", "")) == "Ada", "and the player's name")
		_check(player.has("gameId"), "and a game id the site can key on")

	# The server's own announcements must NOT go out: they are the join notices, the
	# vote prompts and the relayed lines themselves, which would be a loop.
	var before := backbone.posted.size()
	var _a := router.announce("the map is changing")
	await get_tree().process_frame
	_check(backbone.posted.size() == before,
		"a SYSTEM announcement is not relayed, because that is the loop")

	# And a line arriving FROM the website must not be posted straight back TO it.
	#
	# Through the relay's own delivery path, which is the one that happens: calling
	# `announce_from` directly is a host announcing something of its own, and that is a
	# line the website should see. The loop is specifically the relay's own echo.
	relay._deliver({
		"id": "1", "author": "Ada", "authorId": "ada1",
		"body": "hi from the web", "muted": false,
	})
	await get_tree().process_frame
	_check(backbone.posted.size() == before,
		"nor is a line the relay itself just announced — that is the echo")

	# What this server ACCEPTS, published so a site composer can offer it.
	#
	# The list is the server's because only the server has it: the command table depends on
	# which game is loaded and which modules an operator installed, so a list held by the
	# website is stale the first time either changes. `commands_fn` is re-read on every
	# publish for exactly that reason, and the check below is what says so — a callable
	# that closed over a list would answer the same thing twice.
	var commands := [
		{"name": "map", "usage": "<id>", "description": "Change the map",
		 "chat_allowed": true, "permission": "changemap"},
	]
	relay.commands_fn = func() -> Array[Dictionary]:
		var out: Array[Dictionary] = []
		for c: Variant in commands:
			out.append(c as Dictionary)
		return out

	var posted_before := backbone.posted.size()
	await relay.publish_commands()
	_check(
		backbone.posted.size() == posted_before + 1,
		"the command list is published"
	)
	var published: Dictionary = backbone.posted.back()
	_check(str(published["path"]) == "chat/commands", "to the commands endpoint")
	var listed: Array = (published["body"] as Dictionary).get("commands", [])
	_check(listed.size() == 1 and str((listed[0] as Dictionary)["name"]) == "map",
		"naming what the server accepts")

	commands.append({"name": "maps", "usage": "", "description": "List them",
		"chat_allowed": true, "permission": ""})
	await relay.publish_commands()
	var second: Array = (backbone.posted.back()["body"] as Dictionary).get("commands", [])
	_check(
		second.size() == 2,
		"and a module loading changes it, because the callable is re-read rather than captured"
	)

	# A backbone that refuses must not take the relay down with it. An older site with no
	# such endpoint is a menu that is empty, not a server whose chat has stopped.
	backbone.fail_post = true
	await relay.publish_commands()
	backbone.fail_post = false
	var still := router.submit(1, router.default_channel(), "still talking")
	await get_tree().process_frame
	_check(still.ok, "a site that will not take the list does not stop the chat")

	relay.queue_free()
	router.queue_free()


func _test_relay_in() -> void:
	_section("relay: what the site says reaches the game, and commands")

	var bits := _relay_world()
	var world: FakeWorld = bits[0]
	var router: DotChatRouter = bits[1]
	var backbone: FakeBackbone = bits[2]
	var cfg: DotChatRelayConfig = bits[3]
	var relay: DotChatRelay = bits[4]

	cfg.send_game_chat = false
	cfg.allow_commands = true

	var ran: Array[Dictionary] = []
	relay.command_fn = func(
		uid: String, command: String, args: PackedStringArray, source: int
	) -> void:
		ran.append({
			"uid": uid, "command": command, "args": Array(args), "source": source,
		})

	var asked: Array[Dictionary] = []
	relay.permission_fn = func(uid: String, flag: String) -> bool:
		asked.append({"uid": uid, "flag": flag})
		return uid == "backbone:boss"

	add_child(relay)
	await get_tree().process_frame

	# An ordinary line from the website.
	backbone.outbound = [{
		"id": "10", "author": "Cy", "authorId": "cy1",
		"body": "anybody on?", "muted": false,
	}]
	backbone.newest = "10"

	var heard: Array[Dictionary] = []
	router.message_accepted.connect(
		func(m: DotChatMessage, _r: PackedInt32Array) -> void:
			heard.append({"name": m.sender_name, "text": m.text, "key": m.sender_key})
	)

	relay._poll()
	await get_tree().process_frame

	_check(heard.size() == 1,
		"a site line is announced in game (%d)" % heard.size())

	if heard.size() > 0:
		_check(str(heard[0]["text"]) == "anybody on?", "with its text")
		_check(str(heard[0]["name"]).contains("Cy"), "attributed to its author")
		_check(str(heard[0]["name"]).contains("WEB"),
			"and tagged so a player can tell it is not somebody standing there")
		_check(str(heard[0]["key"]) == "backbone:cy1",
			"keyed by the uid the site id maps to, which is what a permission needs")

	# The cursor moved, which is what stops an hour of history arriving on the next poll.
	_check(relay.describe()["cursor"] == "10", "and the cursor advanced")

	# A command from somebody without the flag.
	backbone.outbound = [{
		"id": "11", "author": "Cy", "authorId": "cy1",
		"body": "/arena_map dm_box", "muted": false,
	}]
	backbone.newest = "11"
	relay._poll()
	await get_tree().process_frame

	_check(asked.size() == 1, "a relayed command asks the SERVER for permission")
	_check(ran.is_empty(), "and is refused when the server says no")

	# And from somebody with it.
	backbone.outbound = [{
		"id": "12", "author": "Boss", "authorId": "boss",
		"body": "/arena_map dm_atrium", "muted": false,
	}]
	backbone.newest = "12"
	relay._poll()
	await get_tree().process_frame

	_check(ran.size() == 1, "and runs when the server says yes")
	if ran.size() > 0:
		_check(str(ran[0]["command"]) == "arena_map", "with the command")
		_check(Array(ran[0]["args"]) == ["dm_atrium"], "and its arguments")
		_check(str(ran[0]["uid"]) == "backbone:boss", "as the site author's uid")
		# 3 is CHAT — the conservative default, which several games deliberately
		# withhold from their map commands. A relay that shipped anything looser would
		# overrule a policy each game made on purpose.
		_check(int(ran[0]["source"]) == 3, "and at the configured trust level")

	# With commands off, the same line is text and nothing else.
	cfg.allow_commands = false
	var before_ran := ran.size()
	backbone.outbound = [{
		"id": "13", "author": "Boss", "authorId": "boss",
		"body": "/arena_map dm_box", "muted": false,
	}]
	backbone.newest = "13"
	relay._poll()
	await get_tree().process_frame
	_check(ran.size() == before_ran,
		"with allow_commands off a relayed command runs nothing")

	# A muted line is dropped, and the cursor still moves past it — otherwise every
	# poll from here on re-fetches and re-skips the same row for ever.
	cfg.skip_muted = true
	var heard_before := heard.size()
	backbone.outbound = [{
		"id": "14", "author": "Cy", "authorId": "cy1",
		"body": "muted line", "muted": true,
	}]
	backbone.newest = "14"
	relay._poll()
	await get_tree().process_frame
	_check(heard.size() == heard_before, "a muted site line is dropped")
	_check(relay.describe()["cursor"] == "14",
		"and the cursor still moves past it, or it is re-fetched for ever")

	relay.queue_free()
	router.queue_free()


# --- Harness ---------------------------------------------------------------

func _section(title: String) -> void:
	_section_count += 1
	_line("")
	_line("-- %s" % title)


func _check(condition: bool, what: String) -> void:
	if condition:
		_passed += 1
		_line("   ok   %s" % what)
	else:
		_failed += 1
		_line("  FAIL  %s" % what)


func _line(text: String) -> void:
	print(text)
