extends RefCounted

## The JavaScript Council injects into its own page.
##
## Council does not reuse the host's window.minerva bridge. That bridge talks to
## the plugin webview broker, which only exists for kind:"html" panels; a
## godot_scene panel owns its CefTexture outright, so the page's IPC lands on
## this wrapper's ipc_message handler instead. Owning the bridge also lets the
## envelope carry base_revision and request_id, which the host bridge has no
## notion of.
##
## The page never holds authority. It sends a request, the wrapper answers with
## a reply carrying the snapshot revision the answer was produced against, and
## an event only ever says "the snapshot moved" so the page re-reads.

const BRIDGE_JS := """
<script>
(function () {
  var pending = {};
  var eventHandlers = [];
  var seq = 0;

  window.council = {
    // Send one request envelope and resolve with its reply envelope.
    call: function (command, payload, baseRevision) {
      return new Promise(function (resolve, reject) {
        var id = 'p' + (++seq) + '-' + Date.now();
        pending[id] = { resolve: resolve, reject: reject };
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
        var slot = pending[envelope.request_id];
        if (!slot) { return; }
        delete pending[envelope.request_id];
        slot.resolve(envelope);
        return;
      }
      for (var i = 0; i < eventHandlers.length; i++) {
        try { eventHandlers[i](envelope); } catch (e) { /* a bad handler must not stop the rest */ }
      }
    }
  };
})();
</script>
"""


## Places the bridge in the page before anything else runs. Insertion is textual
## because CefTexture loads a URL, not a DOM: the wrapper materialises the page
## to disk and the bridge has to already be in those bytes.
static func inject(source: String) -> String:
	var head := source.find("</head>")
	if head != -1:
		return source.substr(0, head) + BRIDGE_JS + source.substr(head)
	var body := source.find("<body")
	if body != -1:
		return source.substr(0, body) + BRIDGE_JS + source.substr(body)
	return BRIDGE_JS + source
