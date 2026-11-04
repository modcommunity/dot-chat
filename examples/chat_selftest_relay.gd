extends Node

## The website-relay sections of the dot-chat self-test, run by chat_selftest.gd.

const Fakes := preload("res://examples/chat_selftest_fakes.gd")
const FakeWorld := Fakes.FakeWorld
const FakeBackbone := Fakes.FakeBackbone
## Where the relay sections keep their cursor. Removed before every relay is built.
const RELAY_CURSOR := "user://relay_selftest_cursor.json"

var host: Node


func _section(title: String) -> void:
	host._section(title)


func _check(condition: bool, what: String) -> void:
	host._check(condition, what)


func _line(text: String) -> void:
	host._line(text)


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
	cfg.cursor_path = RELAY_CURSOR
	# The relay loads its cursor in `_ready`, so a stale file made each run begin where
	# the last stopped. See docs/testing.md.
	DirAccess.remove_absolute(ProjectSettings.globalize_path(RELAY_CURSOR))

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

	# A client told otherwise draws no chat box and then talks to nobody.
	_check(not relay.is_carrying(), "a relay that has not started carries nothing")

	add_child(relay)
	await get_tree().process_frame

	_check(
		str(relay.describe()["cursor"]) == "",
		"a relay starts from no cursor, not from where a previous run stopped (%s)"
			% str(relay.describe()["cursor"])
	)

	_check(relay.is_carrying(), "a started, enabled relay with a client carries chat")

	cfg.send_game_chat = false
	# `enabled` is only one of the four things that have to be true.
	_check(not relay.is_carrying(), "a receive-only relay does NOT carry what the game says")
	cfg.send_game_chat = true

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

	# A line arriving FROM the website must not be posted straight back TO it. Go through
	# the relay's delivery path: `announce_from` is a host's own line, which should post.
	relay._deliver({
		"id": "1", "author": "Ada", "authorId": "ada1",
		"body": "hi from the web", "muted": false,
	})
	await get_tree().process_frame
	_check(backbone.posted.size() == before,
		"nor is a line the relay itself just announced — that is the echo")

	await _test_relay_commands(relay, router, backbone)


func _test_relay_commands(
	relay: DotChatRelay, router: DotChatRouter, backbone: FakeBackbone
) -> void:
	# What this server ACCEPTS, published for the site composer. `commands_fn` is re-read
	# on every publish, since the table varies by game and installed modules.
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

	await _test_relay_in_commands(relay, router, backbone, cfg, ran, asked, heard)


func _test_relay_in_commands(
	relay: DotChatRelay, router: DotChatRouter, backbone: FakeBackbone,
	cfg: DotChatRelayConfig, ran: Array[Dictionary], asked: Array[Dictionary],
	heard: Array[Dictionary]
) -> void:
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
