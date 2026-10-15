# Make automatic capture intake the next organiser default

The user clarified after the initial handoff implementation that newly saved
Quick Capture entries should reach the organiser database automatically, without
manually selecting Send. This supersedes ADR-0007's explicit-send-only default
for the next product phase, while retaining durable local capture during outages
and independent append-to-file refiling. It changes the product from an optional
destination into the normal destination for new captures.

Accepted product direction on 15 October 2026. Automatic capture-box intake is
now implemented on `feat/home-organiser`; explicit snapshots remain a separate
legacy development workflow. Native record updates are the next milestone.
The user subsequently confirmed that edits, completion and deletion should update
the same organiser record. Each accepted change advances a revision. A change
based on an older revision must surface a conflict instead of overwriting either
version. Retry of the same operation must return its original acknowledgement.
Deletion retains a tombstone so delayed offline clients cannot recreate the item.
Archive and refile are moves, not deletion requests. Existing unmarked history
is not silently imported when automatic delivery is enabled.

The rollout is a useful home-Mac organiser first, then work Mac, then iPhone.
The user intends to host the backend and PostgreSQL on their Linux server, which
already runs Docker and is accessed through SSH; existing deployments are cloned
under `/app`. A Compose-managed PostgreSQL service and improvements to the pull/
update workflow are proposals to develop, not existing deployed infrastructure.
The initial organiser calendar holds user-entered events without external calendar
integration.
