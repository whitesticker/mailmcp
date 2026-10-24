# Sync and retention strategy

This is the source of truth for how MailMCP caches mail locally and how long it keeps it. Strategies are expected to change; when one does, update the sections below and add an entry to the experiment log at the bottom.

**Current strategy:** v2 (October 23, 2026)

## Principles

- **One cache for everyone.** Mail you open in the reader and mail an agent searches or reads go through the same cache. There is no separate "agent" or "user" access path.
- **Nothing is deleted automatically.** The cache only shrinks when you ask it to (free up space, clear a mailbox, or clear everything).
- **One global size limit.** Crossing it never deletes anything; it prompts you to free space.
- **Attachments are never stored.** They are fetched from the server each time they are needed.

## What is cached

| Data | Cached |
| --- | --- |
| Headers and metadata (from, to, cc, subject, date, flags, labels, folder) | Yes |
| Message bodies (plain text and HTML) | Yes |
| Folder list and unread/total counts | Yes |
| Attachments | No |

## Lazy sync (always on)

Every search and every opened message is written through to the cache, whether it came from the reader or an agent. Repeat requests are answered locally while the server watermark is unchanged; a short cooldown (default 60 seconds) limits how often the server is checked. A per-account daily download cap (default 1,500 MB, under Gmail's 2.5 GB/day limit) pauses background downloads for the rest of the day.

## Per-mailbox background sync

Each mailbox also has a background sync policy, chosen when you add the mailbox and editable later in **Mailbox Settings › Background Sync**.

| Option | What it keeps up to date |
| --- | --- |
| Off (lazy sync only) | Nothing in the background; only what you or an agent opens or searches |
| Recent X messages | The newest X Inbox messages, headers and bodies |
| Recent X days | Inbox messages from the past X days, headers and bodies |
| Everything | Every folder's headers; bodies optional (on by default) |

- **Default:** Recent 1,000 messages, every 30 minutes. Mailboxes that were on Off before v2 were moved to this default.
- **Windows don't trim.** When a message falls outside the recent window it stays in the cache; the window only decides what gets downloaded.
- **Schedules** skip the download entirely when the server watermark hasn't changed. "Manual only" syncs when you press Sync now.
- Auto-sync can pause on battery or in Low Power Mode (Settings › Cache).

## Global limit

- **Default:** 10 GB, adjustable in Settings › Cache (or no limit).
- **Measured as** the database pages in use, which includes the search index. It drops right after deletions, even before the file on disk shrinks.
- **Over the limit:** caching continues, and MailMCP shows a prompt. "Remind me later" hides it for 24 hours; it comes back while the cache is still over the limit.
- **Freeing space:** you choose an amount, and MailMCP removes the least recently used mail first (last opened, or last synced if never opened) until roughly that much is freed. "Free up space…" in Settings › Cache opens the same tool at any time.
- **After freeing space,** the affected mailboxes' sync state is reset, so searches go to the server until the next sync refills their windows.

## Attachments

Attachments are downloaded from the server when you save one from the reader (to a folder you choose) or when an agent calls `get_attachment`. MailMCP keeps no copy in its database or folders. Attachments cached under earlier strategies were removed when v2 shipped.

## Known gaps

- Messages moved or deleted on the server are not removed or re-filed locally, so an old local copy can still appear in its former folder until that mailbox's cache is cleared.

## Where it lives in code

- Policy model: `CacheSyncPolicy`, `AccountSyncScope`, `MailAccount` in `MailMCP/Models/Models.swift`
- Lazy write-through and cache reads: `CachedMailProvider` in `MailMCP/Mail/CachedMailProvider.swift`
- Background sync: `MailboxSyncCoordinator.performSync` in the same file
- Storage, size measurement, freeing space, migrations: `MailboxCacheStore` in `MailMCP/Mail/MailboxCacheStore.swift`
- Limit checks and the prompt: `AppState.checkCacheLimit` and `CacheLimitSheet`

## Experiment log

- **v1 (September–October 2026).** Lazy cache with its own switch and a 1 GB cap with automatic least-recently-used eviction. Background-synced mailboxes were exempt from eviction. "Most recent N" deleted messages beyond N from Inbox, Spam and Trash. Recent and days windows synced headers only. Attachments were cached on disk.
- **v2 (October 23, 2026).** Lazy sync always on and shared by the reader and agents. A 10 GB global limit with no automatic deletion; prompt to free space by size. Default policy Recent 1,000 Inbox messages with bodies, every 30 minutes. Recent and days windows cover Inbox only, download bodies, and never trim. Attachments are no longer cached.
