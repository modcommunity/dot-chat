extends Node

## First half of the self-test: shared helpers, counters and the core (wire, rules, filter, history) sections.

const Fakes := preload("res://examples/chat_selftest_fakes.gd")
const Relay := preload("res://examples/chat_selftest_relay.gd")
const FakeWorld := Fakes.FakeWorld
const FakeMuteSource := Fakes.FakeMuteSource

## Built rather than typed. A source file containing a real zero-width space is one
## whose diff, review and grep all lie about what it says.
const ZERO_WIDTH := 0x200B
const RIGHT_TO_LEFT_OVERRIDE := 0x202E
const BELL := 0x07

var _passed := 0
var _failed := 0
var _section_count := 0


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

	# Every enum value, both directions: one table used both ways, and this checks it is
	# complete (a voice mute once read back as a warning).
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

	# Every key has a default, so any dictionary parsed; dot-server's own payload then
	# filed an empty message and games drew every line as ": ". It must be refused.
	var foreign := DotChatMessage.from_dictionary({
		"kind": "all", "userid": 3, "name": "Alice", "text": "hello everyone",
	})
	_check(
		not foreign.ok and foreign.code() == DotError.CODE_PARSE,
		"a dictionary that is not this wire form is refused, rather than parsing as a"
			+ " message with no text, no sender and no channel"
	)
	# The discriminator is the KEY, not the value: a system line can legitimately be empty.
	_check(
		DotChatMessage.from_dictionary({"m": ""}).ok,
		"while an empty line that IS this wire form still parses"
	)


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
