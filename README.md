# MailMCP

A local macOS app and [MCP](https://modelcontextprotocol.io) server so agents can read and organize your mail from an encrypted vault on your Mac. There is no hosted backend.

Requires macOS 14 or later.

## Homebrew

```bash
brew tap whitesticker/mailmcp
brew install --cask mailmcp
```

Then open MailMCP, unlock the vault, add a mailbox, and use **Add to an agent**.

If Gatekeeper blocks the first launch:

```bash
xattr -dr com.apple.quarantine /Applications/MailMCP.app
```

## Build from source

```bash
brew install xcodegen
xcodegen generate
xcodebuild -project MailMCP.xcodeproj -scheme MailMCP -configuration Release \
  -derivedDataPath .derived CODE_SIGN_IDENTITY="-"
open .derived/Build/Products/Release/MailMCP.app
```

Agents should launch `mailmcp-mcp` (inside the app bundle), not the `MailMCP` GUI binary.
