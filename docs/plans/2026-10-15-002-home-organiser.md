# Home organiser implementation sequence

Branch: `feat/home-organiser`, based on the completed snapshot-handoff branch.

1. **Backend foundation (implemented and deployed).**
   PostgreSQL, transactional item/attachment/receipt storage, authenticated API,
   revision conflicts and tombstones, browser CRUD, Docker health checks,
   deployment and backup scripts. Browser date fields support user-entered
   calendar events and reminders; no notifications or external integrations.
2. **Automatic native capture delivery (implemented).** A saved capture must have a stable
   identity and recoverable local intent before network delivery. Persist a
   frozen operation before sending; reconcile interrupted saves on launch.
   Credentials belong in Keychain. Bind pending operations to their destination.
   Do not silently import existing unmarked history. Account for the API's
   request-size limits without dropping attachments.
3. **Native record updates and conflict resolution (implemented and tested).** Edits and completion update
   the same record. Explicit deletion creates a tombstone. Archive and refile
   remain moves. Preserve both versions on a revision conflict. Server edits
   must not overwrite dirty editor buffers. Test crash boundaries between the
   Markdown file, local outbox and server acknowledgement.
4. **Complete the home-Mac workflows (implemented and verified).** Calendar layout, reminder scheduling and
   delivery, notes and bookmark workflows, capture status, backup restore drill,
   offline/reconnect checks, and everyday use on the actual installed Mac app.
5. **Work Mac rollout.** Secure connectivity, separate device identity, shared
   records, concurrent edit tests, credentials and update installation.
6. **iPhone rollout.** Mobile capture and organiser UX, secure access, offline
   policy, and notification capability appropriate to the chosen client.

Steps 1–4 are implemented and verified; steps 5–6 are explicitly
deferred by the user. The home Mac now has bidirectional sync, incoming-item
import from a durable server change feed, a persistent launchd SSH tunnel, a
browser month calendar, and native reminder scheduling. Installed-app notification
permission, visible reminder delivery, offline recovery and backup restore are verified. The old explicit spool
receiver remains a development fixture and has not become the production API.

## Verified infrastructure

- SSH `remote` resolves to `fahad@192.168.0.50`.
- Server hostname `k3s-master`; Docker and Compose are installed.
- Existing deployments use `/home/fahad/apps`; `/app` does not exist.
- New deployment: `/home/fahad/apps/organiser`.
- API binds to server loopback port 8787; initial Mac access is through an SSH
  tunnel, avoiding cleartext token exposure on the LAN.
