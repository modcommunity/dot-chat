extends Node

## Shared stand-ins for the dot-chat self-test: no transport, no other addon.

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
