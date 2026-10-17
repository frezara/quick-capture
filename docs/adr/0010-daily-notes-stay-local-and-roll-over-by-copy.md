# Daily notes stay local and roll over by copying

Daily notes (`daily/YYYY-MM-DD.md`) are not delivered to the organiser, unlike
capture-box entries under ADR-0009. That lets rollover **copy** unfinished items
from the most recent earlier note into the new day's `## Tasks` once, when the
note is created, and leave the earlier note untouched, so each day's file stays
an accurate record of what was open when that day ended. Moving the items
instead (org-journal's default) would rewrite history and need refile's
two-file write order; copying a synchronised item would duplicate its source
marker, which ADR-0008 blocks. Keeping daily notes local removes that conflict.

Accepted in the Today-view planning session on 17 October 2026.

## Consequences

- "Plan for today" moves an inbox item into today's note, so an item already
  delivered to the organiser becomes local. Items reach the organiser only via
  the capture box or by being moved back into the inbox.
- Making daily notes sync later means revisiting this: rollover would have to
  become a move.
