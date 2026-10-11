# Design

What dot-chat decides, who hears a line, and what it deliberately leaves to others. The website relay is [relay.md](relay.md); the bugs are [history.md](history.md).

## What this is, and what it is not

It is **the decision layer**: what a line may contain, who receives it, how fast somebody may send them, and what is kept. It is not a transport and not a window.

- **No transport.** The router hands a `Dictionary` and a `PackedInt32Array` to a `send_fn` the host supplies. That is what lets one router serve a dot-net game, a dot-server module, a loopback test and a single-player game where `send_fn` draws straight into the window.
- **No art.** `DotChatFormat` returns a BBCode string. dot-ui's rule, for dot-ui's reason: an addon that draws its own chat window is an addon every game fights.
- **No moderation records.** A gag is dot-moderation's, and lives past a reconnect because it is a stored punishment rather than a boolean on a session. This asks.

There is no socket, no file and no thread here: it is text and dictionaries, so the family's browser constraints do not reach it. The one platform note is that `DotChatFormat` produces BBCode, which a `Label` draws literally; use `plain()` there.

## The server decides everything about a line except its text

A client sends a string and a channel id. Everything else on a `DotChatMessage` (the sequence number, the timestamp, the name, the durable key, the kind) is stamped here. A client that sent a pre-formatted line would be deciding the colour, the name and the prefix on the one machine in the exchange under the control of the person whose input is the problem, and could impersonate the server by typing its prefix.

That is also why sanitisation is server-side and its output is what everybody receives. A client may run the same `DotChatFilter` pass to give the player immediate feedback (`DotChatClient.compose` does) and must not be believed.

## Escaping and length

`escape_bbcode` is one pass over the characters, never two chained replaces: the first replace inserts a bracket the second rewrites ([history](history.md#escaping)).

**Length is measured before escaping.** Escaping lengthens a string, so measuring afterwards refuses a message the player typed inside the limit for containing brackets, and the limit they were told about is the one they can count. The same ordering applies in `clean_name`, where truncating an escaped string can cut `[lb]` in half and leave `[l` in the middle of a name, which is markup again.

## The wire form must refuse what is not its own

`DotChatMessage.from_dictionary` requires the `m` key. Every other field on the wire has a default, so without a discriminator any dictionary parses into a valid, empty message. `m` is the one `to_dictionary` always writes (empty text included) and nothing else that reaches a chat client has. The key is what is checked, never the value: a system line is legitimately empty. Why: [history](history.md#from_dictionary-accepted-any-dictionary-at-all).

## Gags

`DotChatRouter.is_gagged` resolves `dot_mute_source` from `DotRegistry` and duck-types `is_chat_muted(peer)` on it. Neither addon names the other: a project with only dot-chat has nobody gagged (the correct answer, not an error), and a project with only dot-moderation is unchanged. dot-moderation published that method long before anything called it; dot-voice consumes the voice half of the same source.

## Things that look like they should be settings and are not

- **Who counts as an admin, a team-mate, or nearby.** Callables, because all three change every round and a channel holding its own roster holds a stale one.
- **What is censored.** `censor_words` ships empty. What a community censors is that community's decision, and a default list is one imposed by whoever wrote the addon.
- **Whether a command was handled.** The router recognises no commands at all, so "unknown" cannot mean "not in the table". A handler calls `claim_command()` during the synchronously emitted signal and `broadcast_unknown_commands` reads that.

## Audience rules

- **A sender with no team reaches nobody** on a `TEAM` channel. Returning everybody instead is how a spectator's line is broadcast to the team they are watching.
- **A `DIRECT` line reaches exactly two peers** and carries the target's durable key, never their peer id. The wire form has no peer ids at all, so a broadcast channel cannot leak who is talking to whom.
- **Backlog runs the same audience test as a live message.** A player joining a team is not handed the other team's last twenty lines. Non-`EVERYONE` channels default to no backlog for the same reason.
- **A party channel is `MEMBERS` plus `grouped`.** `membership_fn(peer, channel)` is asked about the receiver and never hears who is talking, so on its own a "party" channel reaches every party member on the server. `DotChatChannel.grouped` with `DotChatRouter.group_fn(peer, channel) -> StringName` is sender-aware: a line reaches only the sender's group; a sender with no group reaches nobody but themselves; a server line reaches everybody with *a* group; a grouped channel with no `group_fn` reaches nobody. Every ambiguous case fails closed, because the failure that matters is one party reading another's line. **It is opt-in per channel rather than per router** because game-g2gfast carries a plain members channel (the players on a run) and a router-wide switch would have made it reach nobody the day a host set `group_fn`, which dot-server-deploy does for every game. `membership_fn` still applies on a grouped channel when set, as "who may be in the channel at all".
- **A radius is not a room, and `can_hear_fn` is the seam for the difference.** `can_hear_fn(listener, speaker, listener_at, speaker_at) -> bool` is asked on a `RADIUS` channel after the distance test, only about listeners already inside the radius, and is handed the two positions `position_fn` produced. It exists because a room behind a thin partition, inside the radius, put two people either side of the wall in one conversation. **This addon does not know what a wall is and must not**: what blocks sound is a level's decision, and a wall list here would be a second copy of the level. Unset, the radius is the whole answer.
- **`position_fn` returns a `Vector3`.** A 2D game returns `Vector3(x, y, 0)`. Measuring a 2D distance in a 3D world is how dot-npc-ai once called two NPCs standing on each other 1.8 metres apart.

## The player's own block list (`sm`)

`DotChatSelfMute` is the one piece of dot-chat that is the player's rather than the server's: the people whose chat this client does not draw and whose voice it does not play. Typed as `sm` in the console, `!sm` or `/sm` in chat; `sm` lists who is here, numbered, with who is muted; `sm <number>`, `sm <name>` (whole first, then a unique part, any case) or `sm #userid` toggles.

- **Never on the wire.** The chat box (dot-ui's `DotChatWindow`) consumes `!sm` / `/sm` before `submitted`, so the server never sees the line, nobody is told, and there is no server-side list to leak. A moderator's gag is a different feature and stays `dot_mute_source`'s.
- **One list per process, `dot_self_mute` in the registry** (`DotChatSelfMute.shared()`). dot-ui, dot-game, dot-console and dot-voice reach it by path (`SCRIPT_PATH`) and duck typing, so none of them depends on dot-chat. Inside the shell every delivered game shares the shell's `user://`, so the file (`user://dot_self_mute.json`) is named for the list, not a game, and a pack switch finds the same list.
- **Keyed by dot-server's scoreboard `key`, the name as fallback.** `sender_key` is the userid, which a reconnect changes. dot-server's rows carry `key` (a per-server salted digest of the account) and `peer`; the list asks for a roster every `refresh_sec` with `request_scoreboard()` (one board, a held one stays held). An entry made by name learns the key when a roster shows it; a keyed row with the same name and another key is somebody else and is not muted.
- **Dropped before drawing, before decoding.** `DotChatClient` drops a muted player's `say`, `action` and `whisper` after the sequence bookkeeping (no false gap) and before the history (not unread, not in scrollback), backlog included; join and leave notices are the server's lines and stay. `DotChatWindow.add_said` drops them too, for games that draw without `DotChatClient`. Voice: the player's own manager is bound by registry name as dot-voice publishes it (`dot_voice_client`, `publish_as_client()`; `service_registered` covers either order), or handed over with `attach_voice(manager)`; each muted roster row's `peer` is muted with `set_local_mute`, and only what the list did is undone. dot-voice does not load dot-chat and dot-chat does not name dot-voice.
- **What it cannot do:** mute the voice of a player whose peer it has not seen in a roster (a server before dot-server API 9 sends no `peer`, and a reconnect plays until the next roster, at most `refresh_sec`).

## Deliberately not here

- **A chat window.** No scene, no theme, no `RichTextLabel`. `DotChatFormat` gives you the line; dot-game's `DotGameChatClient` and dot-ui draw it.
- **Translation.** A message is text a player typed; translating it is a per-game decision and dot-chat has no string table.
- **Voice.** dot-voice; the two meet only at dot-moderation, which publishes one source both consult.
- **Persistence of chat.** History is in memory and capped, per channel *and* in total. A community that wants chat logs on disk connects `message_accepted` to a log sink, which is a log, and belongs in one.
- **Cross-server chat.** A router is one server's. A backbone-relayed channel would be a `DotChatChannel` with a `MEMBERS` scope and a source that is not this process, and nothing about the design refuses it. `DotChatRelay` is the first thing to take that door: it does not add a channel, it announces into an existing one.
