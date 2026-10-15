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
