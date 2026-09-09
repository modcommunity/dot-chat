# dot-chat

Text chat as a server-authoritative system: channels with an audience rule,
sanitisation, rate and repetition limits, command prefixes, per-channel scrollback
and a backlog for joining players.

**The distributable is `addons/dot_chat/`.** It requires [dot-core](../dot-core), a
separate repository, and nothing else.

```bash
# Local development setup — the symlink is gitignored on purpose.
ln -s ../../dot-core/addons/dot_core addons/dot_core
```

## What this is, and what it is not

It is **the decision layer**: what a line may contain, who receives it, how fast
somebody may send them, and what is kept. It is not a transport and not a window.

- **No transport.** The router hands a `Dictionary` and a `PackedInt32Array` to a
  `send_fn` the host supplies. That is what lets one router serve a dot-net game, a
  dot-server module, a loopback test and a single-player game where `send_fn` draws
  straight into the window.
- **No art.** `DotChatFormat` returns a BBCode string. dot-ui's rule, for dot-ui's
  reason: an addon that draws its own chat window is an addon every game fights.
- **No moderation records.** A gag is dot-moderation's, and lives past a reconnect
  because it is a stored punishment rather than a boolean on a session. This asks.

## The one idea: the server decides everything about a line except its text

A client sends a string and a channel id. Everything else on a `DotChatMessage` —
the sequence number, the timestamp, the name, the durable key, the kind — is stamped
here. A client that sent a pre-formatted line would be deciding the colour, the name
and the prefix on the one machine in the exchange under the control of the person
whose input is the problem, and could impersonate the server by typing its prefix.

That is also why sanitisation is server-side and its output is what everybody
receives. A client may run the same `DotChatFilter` pass to give the player immediate
feedback — `DotChatClient.compose` does — and must not be believed.

## The pieces

| | |
| --- | --- |
| `DotChatMessage` | One line as a document. Short-keyed wire form; peer ids deliberately absent from it. |
| `DotChatChannel` | Where people talk and how the audience is worked out. Five scopes. |
| `DotChatRules` | Every policy, layered like every `DotConfig` here. |
| `DotChatFilter` | Control characters, invisible characters, markup, length, censoring. |
| `DotChatRouter` | The server half: accept, decide the audience, keep, send. |
| `DotChatHistory` | Scrollback, capped per channel *and* in total. |
| `DotChatClient` | The receiving half: filing, gap detection, unread counts, the local pre-check. |
| `DotChatFormat` | A message to a BBCode line, or a plain one. |

## Escaping, and the bug the self-test found on the first run

`escape_bbcode` was written as the obvious two chained replaces:

```gdscript
text.replace("[", "[lb]").replace("]", "[rb]")
```

The first pass inserts a `]` — inside `[lb]` — which the second pass then rewrites,
so `[a]` came out as `[lb[rb]a[rb]`: not what was typed, and not balanced. It is
wrong for exactly the input the escape exists for, and correct for everything else,
which is why it looks right. It is one pass over the characters now.

**Length is measured before escaping**, for a related reason: escaping lengthens a
string, so measuring afterwards refuses a message the player typed inside the limit
for containing brackets — and the limit they were told about is the one they can
count. The same ordering applies in `clean_name`, where truncating an escaped string
can cut `[lb]` in half and leave `[l` in the middle of a name, which is markup again.

## Gags: the method nothing was calling

`DotModerationManager` has published `is_chat_muted(peer)` since it was written, and
until this addon existed **nothing in the family called it**. dot-voice consumes the
voice half of the same manager; the text half was the family's most repeated shape —
a value produced correctly and consumed by nobody.

`DotChatRouter.is_gagged` resolves `dot_mute_source` from `DotRegistry` and
duck-types the call. Neither addon names the other, a project with only dot-chat has
nobody gagged (which is the correct answer, not an error), and a project with only
dot-moderation is unchanged.

## Things that look like they should be settings and are not

- **Who counts as an admin, a team-mate, or nearby.** Callables, because all three
  change every round and a channel holding its own roster holds a stale one.
- **What is censored.** `censor_words` ships empty. What a community censors is that
  community's decision and a default list is one imposed by whoever wrote the addon.
- **Whether a command was handled.** The router recognises no commands at all, so
  "unknown" cannot mean "not in the table". A handler calls `claim_command()` during
  the synchronously-emitted signal and `broadcast_unknown_commands` reads that.

## Audience rules worth knowing

- **A sender with no team reaches nobody** on a `TEAM` channel. Returning everybody
  instead is how a spectator's line is broadcast to the team they are watching.
- **A `DIRECT` line reaches exactly two peers** and carries the target's durable key,
  never their peer id — the wire form has no peer ids at all, so a broadcast channel
  cannot leak who is talking to whom.
- **Backlog runs the same audience test as a live message.** A player joining a team
  is not handed the other team's last twenty lines. Non-`EVERYONE` channels default
  to no backlog for the same reason.
- **`position_fn` returns a `Vector3`.** A 2D game returns `Vector3(x, y, 0)`.
  Measuring a 2D distance in a 3D world is how dot-npc-ai called two NPCs standing on
  each other 1.8 metres apart.

## Where it runs

Everywhere. There is no socket, no file and no thread in this addon: it is text and
dictionaries, so the browser constraints in the family CLAUDE.md do not reach it.
The one platform note is that `DotChatFormat` produces BBCode, which a `Label` will
draw literally — use `plain()` there.

## Validating changes

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
godot --headless --path . res://examples/chat_selftest.tscn
# 14 sections, 120 checks, all offline. Exits non-zero on any failure.
```

The suite counts its sections and fails if fewer ran than it has, because a script
error inside a test aborts **that test** and not the run — a suite can otherwise
report "all passed" while quietly running fewer checks than it contains.

## Things deliberately not here

- **A chat window.** No scene, no theme, no `RichTextLabel`. `DotChatFormat` gives
  you the line.
- **Translation.** A message is text a player typed; translating it is a per-game
  decision and dot-chat has no string table.
- **Voice.** dot-voice, and the two meet only at dot-moderation, which publishes one
  source both consult.
- **Persistence.** History is in memory and capped. A community that wants chat logs
  on disk connects `message_accepted` to a `DotLogSink` — which is a log, and belongs
  in one.
- **Cross-server chat.** A router is one server's. A backbone-relayed channel would
  be a `DotChatChannel` with a `MEMBERS` scope and a source that is not this process,
  and nothing about the design refuses it.
