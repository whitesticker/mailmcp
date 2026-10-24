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
