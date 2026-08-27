extends RefCounted
## ONE undo step out of N model mutations.
##
## PCBData mutators do not snapshot history themselves — the caller decides
## where a step begins and ends. begin_batch() defers the per-mutation
## board_revision bumps and end_batch() takes the single snapshot, so a whole
## gesture reverts on one Ctrl+Z. This wrapper is that pair with the closing
## half guaranteed: `body` may return at any point and the batch is still
## closed, where a hand-written begin_batch/…/end_batch leaks an open batch on
## any path that returns in the middle — and an open batch swallows every later
## revision bump, so the leak is silent until something downstream reads a
## revision that never moved.
##
## Off-tree module — NO class_name, reached by relative preload.


## Run `body` with a batch open, then close it under `action_name` (the label
## undo/redo report for the resulting step), and return whatever `body`
## returned. A body that mutates nothing leaves no history step behind —
## end_batch()'s own no-mutation gate, not a check here.
##
## `body` must be synchronous: a coroutine would return its state object here
## and the batch would close before the mutations ran.
static func compose(data, action_name: String, body: Callable) -> Variant:
	if data == null:
		return body.call()
	data.begin_batch()
	var out: Variant = body.call()
	data.end_batch(action_name)
	return out
