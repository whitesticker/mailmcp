# Roadmap

## Gmail OAuth

Try connecting a Gmail mailbox with Google OAuth instead of an IMAP app password. Current scopes are `gmail.modify` and `gmail.send`.

- [ ] **Per-account profile & metadata display (after OAuth setup):**
  - Request `https://www.googleapis.com/auth/userinfo.profile` alongside `userinfo.email` on Google OAuth sign-in.
  - Fetch and display per-account profile info in the sidebar and `AccountDetailView`:
    - Profile picture / avatar (`userinfo.picture` on Google, `/me/photo/$value` on Microsoft Graph)
    - Full name & given/family name (`userinfo.name`, plus `users/me/settings/sendAs` `displayName`)
    - Send-as aliases and signature (`users/me/settings/sendAs`)
    - Total account message & thread counts (`users/me/profile`) and Workspace domain (`hd`)
    - Fallback for IMAP-only accounts: infer display name from `[Gmail]/Sent Mail` `From:` or `INBOX` `To:` headers.

## Mailbox Export

Per-mailbox export in Mailbox Settings, written to a folder the user picks. Exports are unencrypted (unlike the vault), so the UI should say so. App-only, not an MCP tool. Format not decided yet; options and trade-offs below.

- [ ] **Export cache data** (local only, no network): what MailMCP has cached, meaning headers, metadata, folder, labels, flags, and text/HTML bodies. No attachments or original raw headers, so it can't be rebuilt into a faithful .eml/mbox.
- [ ] **Export all data** (from the server, lossless, attachments included): original RFC 822 messages streamed straight to the chosen folder, never stored in the cache.
  - IMAP already fetches raw messages; Gmail API needs `format=raw`; Microsoft Graph uses `/messages/{id}/$value`.
  - Gmail labels: export All Mail once (plus Spam and Trash) with an `X-Gmail-Labels` header like Google Takeout, or one file per label (duplicates messages with several labels).
  - Large mailboxes can hit Gmail's 2.5 GB/day download limit (background sync caps at 1,500 MB/day): decide whether export respects the cap, ignores it, and/or is resumable.
- [ ] **Packaging:** plain folder, single .zip, or password-protected .zip.

### Format options

Full export (original messages):

- **mbox, one file per folder.** Pros: standard archive format (Google Takeout), imports into Apple Mail (File › Import Mailboxes…) and Thunderbird, few files, lossless. Cons: not browsable in Finder (Quick Look shows raw text), multi-GB single files, slightly incompatible variants, Gmail can't import it.
- **Folder of .eml files** (`Inbox/2026/2026-10-23 Sender – Subject.eml`). Pros: double-click opens in Apple Mail without importing, Quick Look renders it with attachments, Spotlight indexes the contents, lossless. Cons: tens of thousands of small files (slow in Finder, slow to copy), Gmail messages with several labels need duplicates or store-once.
- **Maildir.** Lossless but meant for mutt/Dovecot; not useful on a Mac.

Cache export (snapshot, no attachments):

- **JSON Lines + summary file.** Pros: easy for scripts and agents, every field kept, streamable, diff-friendly. Cons: not readable by people. Open with a text editor or `jq`.
- **SQLite.** Pros: exact copy of the cache tables, queryable, one compact file. Cons: needs an app (DB Browser for SQLite, TablePlus) or `sqlite3`; schema is internal and may change.
- **CSV (headers only, bodies as separate files).** Pros: opens in Numbers/Excel, sortable, Quick Look preview. Cons: bodies don't fit in cells (Excel cuts them at ~32k characters), encoding issues in Excel.
- **HTML archive** (listing page plus one page per message). Pros: friendliest to read in any browser, portable. Cons: read-only, can't be re-imported, large mailboxes need paging, remote images must stay blocked.

Current leaning: full export as .eml folder with optional mbox; cache export as JSON Lines plus an HTML archive.


## Automated UI Testing (bug discovery)

Random "monkey" testing to discover crashes, hangs and broken state, plus faster model-level random tests. Build in this order:

- [ ] **UI test mode** (launch flag, e.g. `--ui-testing`): throwaway vault with fake accounts, a mock mail provider serving a few hundred synthetic messages (HTML, attachments, long subjects, odd charsets), a separate cache directory, and no network. The monkey must never touch real mailboxes.
- [ ] **Model-level random tests** in `MailMCPTests`: random sequences of select, archive, trash, move, refresh, background-sync cache change, load more and search against `MailboxReaderModel`. After each step check invariants: no duplicate rows, list sorted newest first, the selection still exists, held-back new mail never also in the list. Seeded, runs on every build.
- [ ] **UI monkey** (new XCUITest target and its own scheme, run on demand): a seeded random walk over visible controls (click, type, shortcuts like ⌘R ⌘⌫ ⌘, Escape, column drags, window resizes). After each step assert the app is running, responsive within a few seconds, and shows no unexpected error alert. On failure save a screenshot, the action log and the seed (rerun with the same seed to replay), and collect new crash reports from `~/Library/Logs/DiagnosticReports`.
- [ ] **Sanitizer runs** for the monkey scheme: Thread Sanitizer, Main Thread Checker, Address Sanitizer, plus scanning the console for SwiftUI runtime warnings.

Catches: crashes like the Free up space slider trap, layout-loop crashes from resizing and column drags, threading bugs. Doesn't catch: visual-only problems (review saved screenshots) or real-server behavior (Gmail rate limits, unusual IMAP responses).

## IMAP Connection Reuse

Every IMAP operation (opening an uncached message, listing a folder, marking read, archiving) currently opens a new connection, logs in, selects the folder and disconnects. That costs several network round trips per click, which is most of the remaining delay when a message isn't cached yet.

- [ ] Keep one logged-in connection per account, reused across operations and serialized so commands don't interleave.
- [ ] Remember the selected folder and skip `SELECT` when it hasn't changed.
- [ ] Close idle connections after a minute or two, and reconnect transparently when the server drops one (timeouts, sleep / wake, network change).
- [ ] A separate connection for background sync so a long sync never queues the reader's fetches behind it.
- [ ] Measure before / after: time from click to message shown for an uncached message.

## Several agents at once

The socket accepts many agents, and each agent can have many tool calls in flight. They all land on one app, and that app treats them like one user.

- Every tool runs through `MailMCPTools.call` on the main actor, the same actor as the window. Network waits leave it, but account lookup, building a provider, encoding the result, and writing tool history all queue there. Two busy agents hitch the UI and each other.
- `provider(for:)` builds a new Gmail or Graph client per call, each with its own copy of the OAuth tokens. When the access token is expired, every in-flight call refreshes and writes the vault. A provider that rotates the refresh token invalidates the other refresh.
- IMAP holds one lock per account for the whole connect, login, command, and disconnect (`IMAPAccountGate`). The reader, background sync, and every agent wait on it. Each waiter still opens a new connection, so a burst logs in over and over and can hit Gmail's simultaneous-connection cap. A long search blocks a short `get_message` from the other agent. Connection reuse (above) is part of this; it is not enough on its own.
- The cache cooldown, watermark, and daily download cap are per account. One agent's search arms the cooldown and can start a background sync that changes what the other agent and the reader see. Cache writes share one SQLite writer.
- Nothing limits how many calls are in flight. Two agents each firing parallel tools means unbounded IMAP logins and Gmail requests until the server starts failing them.
- File, trash, and send from two agents on the same mailbox are not ordered. One agent's `file_matching` clears the cooldown and starts a sync under the other agent's reads.

- [ ] **Move tool work off the main actor.** Keep vault and UI updates on the main actor. Run search, fetch, and file on a mail executor so a busy agent does not stall the window or the other agent.
- [ ] **One mail client per account**, shared by the reader, sync, and every agent. One token refresh at a time; other callers wait for that result instead of refreshing again.
- [ ] **Lanes per account.** A short read (`get_message`, a small search) is not stuck behind a long search, a body sync, or another agent's `file_matching`. Cap in-flight server calls per account (IMAP connections and Gmail requests) and queue the rest. The reader and a single-message read go first.
- [ ] **Say when an account is busy.** A tool that is waiting returns quickly with a clear "account busy, retry" or waits with a bounded timeout, instead of hanging until the server drops the connection. Tool history keeps which agent was waiting.
- [ ] **Cache stays shared**, with one rule: a call that only reads does not reset another caller's cooldown or start a sync. Sync starts from the scheduler and from an explicit miss, not from every overlapping search.
- [ ] **Order writes per account** so two agents filing or trashing the same mailbox cannot interleave a move with a read of that message. The second write sees the first write's result.

## UI Polish (from the October UI review)

- [ ] **Responsive Tool History dashboard:** at narrow widths "Calls by Tool" and its description wrap into single letters beside the By Tool / By Mailbox picker, and By Mailbox's fixed label widths push charts and agent stats past the window edge. Stack the header above the picker and let the side column move below the breakdown when narrow.
- [ ] **OAuth setup help:** step-by-step instructions for creating the Google client ID / secret (and Microsoft), plus a saved / not saved indicator on the OAuth fields.
- [ ] **Effective permissions summary:** one line under the safety preset listing what agents can actually do once individual MCP tool switches are applied (for example "Agents can read, draft and file; sending is off").
- [ ] **Failure reasons in tool history:** failed calls show their arguments but not why they failed. Check whether the call log keeps the error text; store it if not, and show it on the failed entry.
- [ ] **Account filter in the sidebar:** a filter field above the mailbox list (match name or address) for vaults with many accounts.

## Open a message by link

`onOpenURL` only handles `mailmcp://oauth/…`. There is no way to open one message from another app, a note, or an agent reply.

- [ ] **Message URL** `mailmcp://message?account=<uuid>&id=<message id>`, using the same location-aware id `search_messages` returns.
- [ ] **Copy link** on the open message in the reader, and include the link in agent tool results when a single message is returned.
- [ ] **Open path:** if the vault is locked, hold the URL and open it after unlock. If the body is cached, select it locally. If not, fetch it, write it through, then select it. Unknown account or id shows an error in the reader instead of failing silently.

## Sync settings in one place

Background sync (Off / Recent / Days / Everything, schedule, body download) is edited one mailbox at a time in Mailbox Settings. Settings › Cache only has the global limit, cooldown, daily cap, and "Sync all mailboxes".

- [ ] **Settings › Sync:** one list of every mailbox with scope, schedule, body download, last synced, and progress. Edit a row in place. "Apply to all" sets the same scope and schedule on every mailbox.
- [ ] **Sync now / Pause** on the row, and one "Sync all" that is the same action as today's button.
- [ ] Leave the per-mailbox section in place, reading and writing the same fields, so either screen stays truthful.

## Mail vault (cache across devices)

The credential vault already mirrors one encrypted file into a folder the user picks (iCloud Drive, Dropbox, or anything else). If only one side changed it pushes or pulls; if both changed, Settings › Vault opens a merge preview. That file is accounts, tokens, and settings. It is not the mail cache.

The mail cache is a local SQLite database that can be many gigabytes, and those folder-sync services are not a database. They upload partial files, invent "conflicted copy" duplicates, and report a file as missing while it is still transferring. Putting `mail.sqlite` in that folder will corrupt it. Do not sync the live database.

Sync a replica of cached messages beside the credential vault, in a second folder (or a subdirectory of the same one). The mail server stays the source of truth. The vault is only so a second Mac can fill its cache without re-downloading. A later mailbox sync corrects anything the vault got wrong.

- [ ] **Per-message files, not one database.** One file per account + message id (headers, text/HTML body, flags, folder, labels), content-hashed. A small manifest per account lists ids and hashes. Attachments stay out of the first version.
- [ ] **Conflict rules for an unreliable folder:**
  - A file that is missing, truncated, or fails its hash is skipped and retried. Absence is never a delete.
  - A new id on either side is a union. No prompt.
  - Bodies are immutable. Same hash means the same message. A hash mismatch keeps the local copy and records the other hash for the next server sync to settle.
  - Flags, folder, and labels merge per field: newest `updated_at` wins, with a device id so equal timestamps do not bounce.
  - Deletes are tombstone records. A tombstone loses to a newer copy of the same message. The next server sync resurrects a message that still exists on the server and drops one that does not.
- [ ] **No merge dialog for mail.** The credential vault still asks, because it holds secrets and a wrong choice locks the user out. Mail is a cache of the server, so the rules above run unattended. Surface a one-line "imported N, skipped N unreadable" in Settings, not a per-message picker.
- [ ] **When it runs:** after a mailbox sync finishes, and on launch once the vault is unlocked. Manual "Sync mail vault now" next to the existing vault sync. Pause while a mailbox sync is writing the same messages.
- [ ] **Encryption:** same passphrase as the credential vault, so a cloud folder does not hold readable mail. Decrypt only into the local cache.

## Attachments

Attachment metadata is stored with the message. Bytes are not: the reader chip only saves to a folder the user picks, and `get_attachment` fetches from the server every time. v2 removed the on-disk attachment cache on purpose.

- [ ] **Preview in the reader:** Quick Look for the types AppKit previews (PDF, images, text, common office). Download on first preview, then open the local file. Other types keep today's save action.
- [ ] **Attachments browser:** one list across mailboxes (filename, type, size, sender, date, which message). Open the message, preview, or save. Search by filename. This is the "one place" view; the chip in the reader stays.
- [ ] **Optional auto-download,** off by default, separate from body sync. Settings: max size per file, allowed types, and whether it follows the mailbox's sync window (recent / days / everything). Daily cap counts these bytes. Never auto-download while the cap is hit.
- [ ] **Keep bytes on disk** under the cache directory, keyed by account + message + attachment id, so a second preview or `get_attachment` does not fetch again. Evict only when the user frees space or clears that mailbox, same rule as messages. Do not put attachment files in the mail vault until the vault itself exists; then make "include attachments" its own switch, off by default, because of size.
- [ ] **Agent path:** `get_attachment` returns the cached bytes when present and still writes through when it had to fetch. Preview and the browser are app-only.
- [ ] **OCR for agent search.** `search_messages` only matches the FTS index of subject and body. Text inside attachments is invisible, including scans, photos of receipts, and PDF pages that are images. After the bytes are on disk, extract text locally with Vision (no upload) from images and from PDF pages that have no text layer. PDFs and office files that already have a text layer are extracted without OCR. Store that text next to the message and add it to `messages_fts`, tagged with the filename, so an agent search hits it the same way it hits a body. Re-run only when the attachment bytes change. Skip files over the auto-download size cap. The extracted text follows the message when the user frees space or clears the mailbox. It is not a separate thing agents have to request.
