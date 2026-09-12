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

## `from_dictionary` accepted any dictionary at all, and two games drew every line blank

Every field on the wire has a default — `n`, `t`, `c`, `k`, `m` all fall back — so a `Dictionary` that was not this wire form parsed into a *valid* message whose text, sender and channel were all empty.

dot-server's own chat manager sends a payload of its own shape: `{kind, userid, name, text, admin}`. A client handed one called `DotChatClient.receive`, got `ok`, filed a message with no text, and drew it. Two games in this family put every line a player typed on screen as `": "`, and the code doing it was *correct* — it was being handed a message that had parsed. Both had a fallback for exactly that payload and **neither fallback was reachable**, because `receive` never failed.

`m` is the discriminator, because `to_dictionary` always writes it — empty text included — and nothing else that reaches a chat client has it. The key is what is checked, never the value: a system line is legitimately empty.

That is the whole class of bug this family keeps finding, in its purest form: **a parser with a default for every field cannot refuse anything**, so "it parsed" stops meaning "it was ours".

## Whether anything else is carrying the conversation

`DotChatRelay.is_carrying()` answers "does a line typed in game actually reach the site right now", and **four things have to be true**: started, enabled, `send_game_chat`, and a backbone client. A relay that is enabled with no client refused to start; one configured to receive only carries the site's lines inward and none of the game's outward. Answering "enabled" to either tells a client the conversation is carried when it is not, and what that looks like is a room full of people talking to a page that never hears them.

It exists because the client wants the answer. dot-server hands it to a joining player — see its `DotChatManager.chat_state` — and a client decides from it whether to draw a chat box in front of the game at all. Nothing here knows that; this only answers honestly.

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

## The website relay

`DotChatRelay` joins this server's chat to its room on the website. The site has had
both halves of the contract since before this addon existed — `LiveChatScope.GAME`,
which its own model calls *"relayed in-game chat"*, `POST /api/integration/v1/chat`
inbound and `GET /api/integration/v1/chat/outbound` outbound — and **nothing in any of
the thirty-four projects here had ever called either.** The website half was finished
and talking to nobody.

**The backbone client is an `Object` and is never named.** dot-chat depends on dot-core
and nothing else; a script that so much as *mentions* `DotBackboneClient` fails to
compile in a project without dot-auth, which is most of them. The contract is two
methods, `post_integration` and `get_integration`, and that the suite substitutes a
plain `RefCounted` for both is the proof the seam is real. Same shape as
`DotStatsReporter`.

**Nothing here decides a permission.** A relayed command is resolved to a uid and handed
to the host's `permission_fn` — dot-server's admin manager, the same file, the same
flags, as that person typing it in game. A relay with its own permission model would be
a second answer to "may this person do this" and the two would drift.

**The uid mapping is a seam, not a constant.** dot-auth namespaces every identity by its
provider — `backbone:clx8f2k0`, `steam:7656…`, `local:admin` — so which namespace an
admin file is keyed by depends on who authenticated them. `author_uid_prefix` covers the
prefix case and `uid_for_author` replaces the whole mapping for a server running its own
auth back-end.

### The bug the suite found on the first run

**A line from the website was posted straight back to the website.** `announce_from`
dispatches a relayed line as an ordinary `SAY` — which is right, it is something a person
said and should read like one — and `message_accepted` fires *synchronously* inside it,
so the outbound filter saw it and sent it.

It would not have looped for ever, which is exactly what makes it worth writing down: the
site's outbound half returns only `USER`-kind rows and what the relay posts becomes
`GAME`-kind, so the second copy would have stopped there. Every web line would simply have
appeared twice, the second attributed to the game. **A loop is obvious and this is not** —
it reads as a display bug on the website, which is the half nobody debugging a game
server would look at.

The guard is a flag rather than a match on the sender key, because a person signed into
the website *and* playing on the server has the same uid in both places: keying on that
would have silently stopped relaying the in-game lines of every admin who left a tab open.

### Telling the site what this server accepts

`DotChatRelay.publish_commands()` posts the command table to
`POST /api/integration/v1/chat/commands`, and the site's chat composer offers it when a
member types `/`.

**The list has to come from here because only here has it.** A member typing `/` on a web
page is typing at a machine the site does not control, whose command table depends on which
game is loaded and which modules an operator installed — so a list held by the website is
stale the first time either changes. `commands_fn` is re-read on every publish rather than
captured, for the same reason: a callable that closed over a list would publish the table as
it was at boot, for ever. Call it again after loading or unloading a module.

**Nothing published is a permission**, which is what makes accepting the list safe at the
other end. Whether a particular person may run a particular command is decided here, per
line, by `permission_fn` against this server's own admin file. The list decides only what is
worth *offering* — and offering something that will always be refused teaches people the
site is broken, which is why the source gate travels with it.

That gate is the part worth reading twice. `DotConsole.command_document(source)` applies
**the same source check `_run_command` applies**, so the menu is built at the relay's own
`command_source`: a relay running as CHAT offers what that server takes from chat — with `sv_chat_commands` on, the default, everything that has not called `no_chat()` — and a relay running as RCON offers everything RCON reaches. A menu built from a per-command flag alone would hide an operator's whole toolbox from a deployment that deliberately made its site admins remote administrators, and, on a server that closed chat commands, offer a table where every entry is refused.

A backbone that refuses the list does not take the relay down with it: an older site with no
such endpoint is a menu that is empty, not a server whose chat has stopped. It logs at info
for the reason this family always gives — a red line about a condition that is normal is how
a real one stops being read.

### `announce_from`, and why `announce` was not enough

`submit` takes a peer, because a line normally comes from somebody connected.
`announce` takes none, because the server speaking is nobody. **A relayed line is
neither** — it has an author, a name and a uid, and no peer at all. Without it the only
options were announcing anonymously or baking the author into the text, which puts a
user-controlled string where a sender name belongs and loses it for anything reading the
message rather than drawing it.

Both the text *and* the sender name go through `DotChatFilter`, for a stronger reason
than an ordinary announcement: both were typed on a web page by somebody who is not on
this server.

## Validating changes

```bash
godot --headless --path . --import
find . -name '*.gd' -not -path './.godot/*' | while read f; do
    godot --headless --path . --check-only --script "res://${f#./}"
done
godot --headless --path . res://examples/chat_selftest.tscn
# 16 sections, 154 checks, all offline. Exits non-zero on any failure.
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
  and nothing about the design refuses it. `DotChatRelay` is the first thing to take
  that door: it does not add a channel, it announces into an existing one.
