This is the **chat** asset for TMC's **Dot** collection. Every multiplayer game writes text chat, and every one of them writes the same four bugs into it.

This collection of assets provides modular building blocks for creating games and applications within the TMC ecosystem, ensuring consistency and interoperability across all `dot-*` assets. This includes core functionality, networking, authentication, cloud integration, and more.

**These assets are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This asset, along with all the others, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** Every asset has its own headless test suite and those suites pass, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## Text Chat
**Channels with an audience rule, sanitisation that survives markup and invisible
characters, rate and repetition limits, command prefixes, scrollback, and a backlog
for joining players.** The server decides who hears a line, what it may contain, and
what name is drawn beside it — because every one of those is a decision a player must
not be making about other players.

## Why

Chat is the only subsystem in a game where one player puts arbitrary text in front of
every other player. The four things that go wrong are always the same:

- **Markup.** A client draws chat in a `RichTextLabel` with BBCode on, and now anybody
  can put a colour, a size, an image or a link in everybody else's window.
- **Invisible text.** Zero-width characters and direction overrides make a message
  that is empty, or that reads as something other than what it is.
- **Attribution.** A client that sends a pre-formatted line has decided the name and
  the prefix on the one machine that must not decide either, and can impersonate the
  server by typing its prefix.
- **The audience.** Team chat that reaches the other team is a bug you ship once.

dot-chat handles all four on the server, and hands your game a line to draw.

## Installing

Copy `addons/dot_chat/` and [`dot-core`](https://github.com/modcommunity/dot-core)'s
`addons/dot_core/` into your project and enable dot-chat in
*Project → Project Settings → Plugins*.

[dot-moderation](https://github.com/modcommunity/dot-moderation) is optional. When it
is present, its gags apply here with no wiring at all: the router asks whatever is
registered as `dot_mute_source` and neither addon names the other.

Requires Godot 4.7 or newer.

## Five minutes

On the server:

```gdscript
var router := DotChatRouter.new()

router.peers_fn = func() -> PackedInt32Array: return server.peer_ids()
router.name_fn  = func(peer: int) -> String: return server.session_of(peer).name
router.key_fn   = func(peer: int) -> String: return server.session_of(peer).uid
router.team_fn  = func(peer: int) -> StringName: return game.team_of(peer)
router.send_fn  = func(wire: Dictionary, to: PackedInt32Array) -> void:
    for peer in to:
        link.rpc_id(peer, "chat_line", wire)

add_child(router)

# When a client says something:
var res := router.submit(peer, &"all", text_they_typed)
if not res.ok:
    link.rpc_id(peer, "chat_notice", res.error.message)
```

On the client:

```gdscript
var chat := DotChatClient.new()
chat.channels = [DotChatChannel.everyone(), DotChatChannel.team()]
chat.send_fn = func(text: String, channel: StringName) -> void:
    link.rpc_id(1, "chat_say", String(channel), text)
chat.message_received.connect(func(m: DotChatMessage, _c: StringName) -> void:
    log_label.append_text(DotChatFormat.line(m, chat.channel(m.channel)) + "\n"))
add_child(chat)

# From your input box:
var res := chat.compose(chat.active_channel, entry.text)
if not res.ok:
    hud.flash(res.error.message)
```

That is a working chat system: everybody, team, whispers, `/me`, rate limits,
repetition limits, escaping, scrollback and a backlog for whoever joins next.

## Channels

A channel is a `Resource` with an audience rule. `EVERYONE`, `TEAM`, `RADIUS` (proximity
chat), `DIRECT` (whispers) and `MEMBERS` (a party, a clan, the dead, the admins — the
host answers `membership_fn`).

```gdscript
var proximity := DotChatChannel.make(&"near", "Nearby", DotChatChannel.Scope.RADIUS)
proximity.radius = 20.0
router.add_channel(proximity)
```

Membership is asked, never stored: which team a peer is on is a fact your game owns
and changes every round, and a second copy of it is the copy that goes stale.

## Commands

A line starting with `!` or `/` is never broadcast. It arrives as a signal:

```gdscript
router.command_entered.connect(func(peer, command, args, raw):
    if command == "rtv":
        router.claim_command()
        vote.rock_the_vote(peer))
```

Which is how dot-server's chat commands and dot-vote's `!rtv` reach a player without
either addon knowing this one exists.

## Validating

```bash
godot --headless --path . --import
godot --headless --path . res://examples/chat_selftest.tscn
# 120 checks, all offline. Exits non-zero on any failure.
```
