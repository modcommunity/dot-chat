# History

Bugs worth recognising if they come back. All parsed clean.

## Escaping

`escape_bbcode` was written as the obvious two chained replaces:

```gdscript
text.replace("[", "[lb]").replace("]", "[rb]")
```

The first pass inserts a `]` inside `[lb]`, which the second pass then rewrites, so `[a]` came out as `[lb[rb]a[rb]`: not what was typed, and not balanced. Wrong for exactly the input the escape exists for, and correct for everything else, which is why it looks right. Found by the suite on its first run.

## `from_dictionary` accepted any dictionary at all

Every field on the wire had a default (`n`, `t`, `c`, `k`, `m` all fell back), so a `Dictionary` that was not this wire form parsed into a *valid* message whose text, sender and channel were all empty.

dot-server's own chat manager sends a payload of its own shape: `{kind, userid, name, text, admin}`. A client handed one called `DotChatClient.receive`, got `ok`, filed a message with no text, and drew it. Two games put every line a player typed on screen as `": "`, and the code doing it was *correct*: it was being handed a message that had parsed. Both had a fallback for exactly that payload and **neither fallback was reachable**, because `receive` never failed.

**A parser with a default for every field cannot refuse anything**, so "it parsed" stops meaning "it was ours". The fix is the `m` discriminator ([design](design.md#the-wire-form-must-refuse-what-is-not-its-own)).

## A line from the website was posted straight back

`announce_from` dispatches a relayed line as an ordinary `SAY` (right: it is something a person said and should read like one), and `message_accepted` fires *synchronously* inside it, so the outbound filter saw it and sent it.

It would not have looped for ever, which is exactly what makes it worth writing down: the site's outbound half returns only `USER`-kind rows and what the relay posts becomes `GAME`-kind, so the second copy would have stopped there. Every web line would simply have appeared twice, the second attributed to the game. **A loop is obvious and this is not**: it reads as a display bug on the website, which is the half nobody debugging a game server would look at. Found by the suite on its first run.

## A party channel reached every party

`membership_fn` is asked about the receiver and never hears who is talking, so a "party" channel built on it reached every party member on the server. dot-party's own notes named it as the thing dot-chat could not do. Fixed by `grouped` and `group_fn` ([design](design.md#audience-rules)).

## Two people either side of a wall in one conversation

A room behind a partition, inside a `RADIUS` channel's radius, put two people either side of the wall in one conversation. Fixed by the `can_hear_fn` seam, not by teaching dot-chat about walls ([design](design.md#audience-rules)).
