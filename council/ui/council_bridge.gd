extends RefCounted

## The JavaScript Council injects into its own page.
##
## Council does not reuse the host's `window.minerva` bridge. That bridge serves
## the plugin webview broker, which only exists for kind:"html" panels, and it
## reaches the host's unauthenticated MCP HTTP port directly from the page —
## around the manifest allowlist and the capability policy. A godot_scene panel
## owns its CefTexture outright, so the page's IPC lands on the wrapper's
## ipc_message handler instead. Owning the bridge is also what lets the envelope
## carry `base_revision` and `request_id`, which the host bridge has no notion of.
##
## The page never holds authority. It sends a request, the wrapper answers with a
## reply carrying the snapshot revision the answer was produced against, and an
## event only ever says "the record moved" so the page re-reads.
##
## Insertion is textual because CefTexture loads a URL, not a DOM: the wrapper
## materialises the page to disk and the bridge has to already be in those bytes.

const BRIDGE_JS := """
<script>
(function () {
  var pending = {};
  var eventHandlers = [];
  var seq = 0;
  var announced = false;

  // Tell the wrapper the bridge exists. Until this lands the wrapper queues
  // everything it would push, so no event is evaluated into a document that has
  // no window.council yet. A page reload announces again and is re-primed.
  function announce() {
    if (announced || typeof window.sendIpcMessage !== 'function') { return; }
    announced = true;
    window.sendIpcMessage(JSON.stringify({ schema_version: 1, envelope: 'ready' }));
  }

  window.council = {
    // Send one request envelope and resolve with its reply envelope. A reply
    // always arrives — a refusal is a reply — so this never hangs on a
    // rejection the page has to guess at.
    call: function (command, payload, baseRevision) {
      return new Promise(function (resolve) {
        var id = 'p' + (++seq) + '-' + Date.now();
        pending[id] = resolve;
        var envelope = {
          schema_version: 1,
          envelope: 'request',
          request_id: id,
          command: command,
          payload: payload || {}
        };
        if (baseRevision !== undefined && baseRevision !== null) {
          envelope.base_revision = baseRevision;
        }
        window.sendIpcMessage(JSON.stringify(envelope));
      });
    },

    onEvent: function (cb) { eventHandlers.push(cb); },

    // Called from GDScript. A reply is matched by request_id; anything else is
    // an event and is broadcast.
    _deliver: function (envelope) {
      if (envelope.envelope === 'reply') {
        var resolve = pending[envelope.request_id];
        if (!resolve) { return; }
        delete pending[envelope.request_id];
        resolve(envelope);
        return;
      }
      for (var i = 0; i < eventHandlers.length; i++) {
        try { eventHandlers[i](envelope); } catch (e) { /* one bad handler must not stop the rest */ }
      }
    }
  };

  announce();
  document.addEventListener('DOMContentLoaded', announce);
})();
</script>
"""


## Place the bridge in the page before anything else runs.
static func inject(source: String) -> String:
	var head := source.find("</head>")
	if head != -1:
		return source.substr(0, head) + BRIDGE_JS + source.substr(head)
	var body := source.find("<body")
	if body != -1:
		return source.substr(0, body) + BRIDGE_JS + source.substr(body)
	return BRIDGE_JS + source
