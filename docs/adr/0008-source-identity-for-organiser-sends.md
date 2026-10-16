# Identify sent source items independently of their content

Items first sent to the organiser may acquire a stable HTML comment identifier
in the source Markdown, with delivery state kept separately. This deliberate
source-format addition enables recognition across edits and reordering; line
positions and content hashes cannot distinguish identical independent items.

Source identity is separate from handoff identity: Retry keeps the frozen
handoff, whereas Send as new item creates another handoff for the same source.
The former creation-time `<!--qc:…-->` tokens are not assumed to be item IDs.
Duplicate identifiers block ordinary sending and offer previous delivery history
or an explicit Send this copy as new action, which assigns the selected copy a
fresh source identity. Missing identifiers are treated as new source items;
matching text is never sufficient to recover identity, so removing an identifier
can result in another organiser item. Previous handoffs remain in delivery history.

The implementation plan specifies marker syntax and snapshot representation;
these must preserve user-authored Markdown and tolerate legacy creation tokens.

Accepted during integration planning on 15 October 2026; implementation pending.

## Amendment — 16 October 2026: identity lives beside the editor's text

The marker stays in the file exactly as specified, but the editor no longer
holds it in its buffer. Hiding real text inside the buffer broke vim: every
line-end motion and edit collided with characters the user could not see. On
load the editor strips markers, tracks which line owns each one through every
edit, and writes them back for every save, refile and send. Swift, sync and the
file format are unchanged. Syncing the inbox as one document, as projects and
Obsidian do, was rejected: it would lose per-item identity for reminders and
calendar events.

One narrow exception to "matching text is never sufficient to recover
identity": within one editor session, a line whose identity was deleted or
joined away gets it back if a line with exactly the same text reappears and no
other line holds that identity. Without it, moving an item with `dd`/`p`, or
undoing a deletion, would turn an edit into a delete plus a new organiser item
and drop its reminder. The exception never applies across reloads, and never
lets two lines share an identity.
