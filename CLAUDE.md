# dot-chat

Text chat as a server-authoritative system: channels with an audience rule, sanitisation, rate and repetition limits, command prefixes, per-channel scrollback, a backlog for joining players, and a relay to the server's room on the website.

Read the family [CLAUDE.md](../../CLAUDE.md) first; this file is only what is specific to chat.

**The distributable is `addons/dot_chat/`.** It requires dot-core and nothing else (symlinked, `.gitignore`). dot-moderation, dot-auth's backbone client and dot-server are all reached by duck typing and named nowhere.

## Read before

| Read | Before |
| --- | --- |
| [docs/design.md](docs/design.md) | anything: the decision layer, server-stamped lines, escaping, the wire discriminator, gags, audience rules, what is not here |
| [docs/relay.md](docs/relay.md) | `DotChatRelay`, `DotChatRelayConfig` |
| [docs/history.md](docs/history.md) | the bugs, and how each looked |

## Layout

| Path | What |
| --- | --- |
| `addons/dot_chat/core/` | `DotChatMessage` (one line; short-keyed wire form, no peer ids), `DotChatChannel` (five scopes), `DotChatRules` (every policy, a `DotConfig`), `DotChatFilter` (control and invisible characters, markup, length, censoring), `DotChatRelayConfig` |
| `addons/dot_chat/runtime/` | `DotChatRouter` (the server half: accept, audience, keep, send), `DotChatHistory` (capped per channel and in total), `DotChatClient` (filing, gap detection, unread counts, the local pre-check) |
| `addons/dot_chat/net/` | `DotChatRelay`: the website relay |
| `addons/dot_chat/ui/` | `DotChatFormat`: a message to a BBCode line, or `plain()` |
| `examples/chat_selftest.tscn` | the suite; all offline, non-zero on failure, and it fails if fewer sections ran than it has |

## Running and testing

The family's two steps ([game-dev/CLAUDE.md](../../CLAUDE.md#validating-anything)), then `godot --headless --path . res://examples/chat_selftest.tscn`.

## Rules that bite

- The server stamps everything on a line but its text; the client's filter pass is feedback, never trusted. [design](docs/design.md#the-server-decides-everything-about-a-line-except-its-text)
- No transport, no art, no moderation records: `send_fn`, BBCode strings, and `dot_mute_source`. [design](docs/design.md#what-this-is-and-what-it-is-not)
- Escape in one pass; measure length before escaping, in `clean_name` too. [design](docs/design.md#escaping-and-length)
- `from_dictionary` requires the `m` key and must keep refusing anything without it. [design](docs/design.md#the-wire-form-must-refuse-what-is-not-its-own)
- Gags come from `dot_mute_source`, duck-typed; none is not an error. [design](docs/design.md#gags)
- Rosters are callables, `censor_words` ships empty, and a command handler calls `claim_command()` synchronously. [design](docs/design.md#things-that-look-like-they-should-be-settings-and-are-not)
- Audiences fail closed: no team reaches nobody on `TEAM`; `DIRECT` carries durable keys, never peer ids; backlog runs the live audience test. [design](docs/design.md#audience-rules)
- A party channel is `MEMBERS` plus `grouped` with `group_fn`, opt-in per channel. [design](docs/design.md#audience-rules)
- Walls are the level's: `can_hear_fn` on `RADIUS` channels, never a wall list here. `position_fn` returns a `Vector3`. [design](docs/design.md#audience-rules)
- Never name `DotBackboneClient`; the relay's client is an `Object` with `post_integration` / `get_integration`. [relay](docs/relay.md#the-backbone-client-is-an-object-and-is-never-named)
- Relayed commands go through the host's `permission_fn`; the uid mapping is `author_uid_prefix` / `uid_for_author`. [relay](docs/relay.md#nothing-here-decides-a-permission)
- `is_carrying()` needs all four: started, enabled, `send_game_chat`, a client. [relay](docs/relay.md#is_carrying-takes-four-things)
- A relayed line is `announce_from`, filtered in text and name, and never echoed back (a flag, not a sender match). [relay](docs/relay.md#announce_from-and-why-announce-was-not-enough)
- `publish_commands()` re-reads `commands_fn` every time and builds at the relay's own `command_source`; a refusal from the site is INFO. [relay](docs/relay.md#telling-the-site-what-this-server-accepts)

Deliberately not here: a chat window, translation, voice, persistence, cross-server channels. [design](docs/design.md#deliberately-not-here)
