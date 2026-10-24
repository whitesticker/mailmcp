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

