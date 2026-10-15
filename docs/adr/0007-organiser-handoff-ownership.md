# Preserve source ownership through one-way organiser handoffs

Quick Capture retains its Markdown capture file and editor; explicit organiser
sends create independent immutable handoff snapshots, while the organiser owns
accepted inbox records. Refile continues moving subtrees into independently
managed target inbox files: neither handoff creates bidirectional synchronisation
or grants Quick Capture ownership of another application's records.

This preserves the existing agent-inbox workflow and editable local source while
allowing durable asynchronous organiser delivery. The first Send action selects
the saved item subtree in editor mode; capture-box sending is deferred until
that path is reliable. Ordinary capture dismissal remains unchanged under
ADR-0004, with recovery required for failed saves and interrupted imports/sends.

Accepted during integration planning on 15 October 2026; implementation pending.
