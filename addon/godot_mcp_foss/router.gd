@tool
extends RefCounted
## Method registry: name -> Callable. Command modules register themselves here.
## Handlers receive a single `params: Dictionary` and return a Dictionary
## (or {"__error": "...", "code": N} for a JSON-RPC error). Handlers may await.

var _methods: Dictionary = {}          # name -> Callable
var _descriptions: Dictionary = {}     # name -> one-line description


func register(name: String, handler: Callable, description: String = "") -> void:
	if _methods.has(name):
		push_error("[mcp-foss] duplicate method '%s'" % name)
		return
	_methods[name] = handler
	_descriptions[name] = description


func has_method_named(name: String) -> bool:
	return _methods.has(name)


func method_names() -> Array:
	var out := _methods.keys()
	out.sort()
	return out


func describe() -> Dictionary:
	var out := {}
	for k in _methods:
		out[k] = _descriptions.get(k, "")
	return out


func invoke(name: String, params: Dictionary):
	var cb: Callable = _methods[name]
	return await cb.call(params)
