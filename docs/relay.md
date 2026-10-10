# The website relay

`DotChatRelay` joins this server's chat to its room on the website: the site's `LiveChatScope.GAME` ("relayed in-game chat"), `POST /api/integration/v1/chat` inbound and `GET /api/integration/v1/chat/outbound` outbound. The site had both halves before anything in the game tree called either.

## The backbone client is an `Object` and is never named

dot-chat depends on dot-core and nothing else; a script that so much as *mentions* `DotBackboneClient` fails to compile in a project without dot-auth, which is most of them. The contract is two methods, `post_integration` and `get_integration`, and that the suite substitutes a plain `RefCounted` for both is the proof the seam is real. Same shape as `DotStatsReporter`.

## Nothing here decides a permission

A relayed command is resolved to a uid and handed to the host's `permission_fn`: dot-server's admin manager, the same file, the same flags, as that person typing it in game. A relay with its own permission model would be a second answer to "may this person do this" and the two would drift.

**The uid mapping is a seam, not a constant.** dot-auth namespaces every identity by its provider (`backbone:clx8f2k0`, `local:admin`, a third-party platform's own prefix), so which namespace an admin file is keyed by depends on who authenticated them. `author_uid_prefix` covers the prefix case and `uid_for_author` replaces the whole mapping for a server running its own auth back-end.

## `is_carrying()` takes four things

`DotChatRelay.is_carrying()` answers "does a line typed in game actually reach the site right now", and **four things have to be true**: started, enabled, `send_game_chat`, and a backbone client. A relay that is enabled with no client refused to start; one configured to receive only carries the site's lines inward and none of the game's outward. Answering "enabled" to either tells a client the conversation is carried when it is not, and what that looks like is a room full of people talking to a page that never hears them.

dot-server hands the answer to a joining player (its `DotChatManager.chat_state`), and a client decides from it whether to draw a chat box in front of the game at all. Nothing here knows that; this only answers honestly.

## `announce_from`, and why `announce` was not enough

`submit` takes a peer, because a line normally comes from somebody connected. `announce` takes none, because the server speaking is nobody. **A relayed line is neither**: it has an author, a name and a uid, and no peer at all. Without `announce_from` the only options were announcing anonymously or baking the author into the text, which puts a user-controlled string where a sender name belongs and loses it for anything reading the message rather than drawing it.

Both the text *and* the sender name go through `DotChatFilter`, for a stronger reason than an ordinary announcement: both were typed on a web page by somebody who is not on this server.

**The echo guard is a flag, not a match on the sender key.** `announce_from` dispatches as an ordinary `SAY` and `message_accepted` fires synchronously inside it, so the outbound filter must know the line came from the site ([history](history.md#a-line-from-the-website-was-posted-straight-back)). Keying on the sender would be wrong because a person signed into the website *and* playing on the server has the same uid in both places: it would silently stop relaying the in-game lines of every admin who left a tab open.

## Telling the site what this server accepts

`DotChatRelay.publish_commands()` posts the command table to `POST /api/integration/v1/chat/commands`, and the site's chat composer offers it when a member types `/`.

**The list has to come from here because only here has it.** A member typing `/` on a web page is typing at a machine the site does not control, whose command table depends on which game is loaded and which modules an operator installed, so a list held by the website is stale the first time either changes. `commands_fn` is re-read on every publish rather than captured, for the same reason: a callable that closed over a list would publish the table as it was at boot, for ever. Call it again after loading or unloading a module.

**Nothing published is a permission**, which is what makes accepting the list safe at the other end. Whether a particular person may run a particular command is decided here, per line, by `permission_fn` against this server's own admin file. The list decides only what is worth *offering*, and offering something that will always be refused teaches people the site is broken, which is why the source gate travels with it.

That gate is the part worth reading twice. dot-server's `DotConsole.command_document(source)` applies **the same source check `_run_command` applies**, so the menu is built at the relay's own `command_source`: a relay running as CHAT offers what that server takes from chat (with `sv_chat_commands` on, the default, everything that has not called `no_chat()`), and a relay running as RCON offers everything RCON reaches. A menu built from a per-command flag alone would hide an operator's whole toolbox from a deployment that deliberately made its site admins remote administrators, and, on a server that closed chat commands, offer a table where every entry is refused.

A backbone that refuses the list does not take the relay down with it: an older site with no such endpoint is a menu that is empty, not a server whose chat has stopped. It logs at INFO, because a red line about a condition that is normal is how a real one stops being read.
