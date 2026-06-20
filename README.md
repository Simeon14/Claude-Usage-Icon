# Claude Usage Icon — Claude Code usage in your macOS menu bar

A tiny, native Swift + AppKit menu bar app that shows your Claude Code usage:

- **5hr: N%** — pie-chart icon (`chart.pie.fill`)
- **Week: N%** — calendar icon (`calendar`)
- **Open at Login** — toggle launch-at-login (on by default)
- separator → **Quit** (⌘Q)

The menu bar shows two compact numbers — **session (5hr) % on the left, weekly %
on the right** (e.g. `19%  81%`), no icon. It refreshes every 2 minutes and again
whenever you open the menu.

It is deliberately resilient: the usage API response is parsed **loosely** (only
`five_hour.utilization` and `seven_day.utilization` are read; everything else is
ignored), so Anthropic adding/renaming/nulling sibling fields will not break it —
which is exactly why the hardcoded-schema community apps stopped working.

## Build & run

Requires the Swift toolchain (Xcode or Command Line Tools: `xcode-select --install`).
Targets macOS 13+; `build.sh` compiles for your Mac's architecture (Apple Silicon or Intel).

```sh
# One-time: create a stable code-signing identity (see "Keychain prompts" below)
./setup-signing.sh

# Build and run from ./build/
./build.sh
open "build/Claude Usage Icon.app"

# …or build, install to /Applications, and launch (recommended)
./build.sh install
```

`build.sh` compiles `Sources/main.swift` with `swiftc`, assembles a proper
`Claude Usage Icon.app` bundle (with `LSUIElement` so there's no dock icon /
window), and code-signs it with the stable identity created by `setup-signing.sh`
(falling back to ad-hoc if that identity is missing). `./build.sh install`
additionally copies it to `/Applications` and launches it.

### Start at login

On first launch the app registers itself as a login item via `SMAppService`
(macOS 13+), so it starts automatically going forward. Toggle it anytime from the
menu (**Open at Login**) or in **System Settings → General → Login Items**.

For reliable launch-at-login, install it to a stable location first
(`./build.sh install` puts it in `/Applications`) — a login item that points at a
copy you later move or delete won't launch.

### First launch

- **Unsigned app warning:** because the app is only ad-hoc signed, the first time
  you may need to **right-click the app → Open** (or approve it in System Settings
  → Privacy & Security) to get past Gatekeeper.
- **Keychain prompt:** the first time it reads your token you'll see
  *"Claude Usage Icon wants to use information stored in 'Claude Code-credentials'
  in your keychain."* Click **Always Allow** (once). The token is then cached in
  memory and reused, so opening the menu or the periodic refresh won't prompt — it
  only re-reads the Keychain when the token expires and Claude Code refreshes it.

### Keychain prompts that keep coming back

If you click **Always Allow** but still get re-prompted multiple times a day, the
cause is **code signing**. macOS only persists "Always Allow" for apps with a
*stable* code identity. An **ad-hoc** signature (`codesign -s -`) has none, so each
time your OAuth token refreshes (a few times a day) and the app re-reads the
Keychain, macOS asks again.

The fix is `setup-signing.sh`: it creates a self-signed code-signing certificate,
and `build.sh` signs the app with it. With a stable identity, a single "Always
Allow" sticks across token refreshes and rebuilds. (The token lives **only** in the
Keychain on macOS — there's no plaintext file to read instead.)

You'll see one **`codesign` wants to access key** prompt the first time you build
after running `setup-signing.sh` — that's `codesign` using the new signing key (not
your token); click **Always Allow**.

## How it works

1. **Token** — reads the generic-password keychain item `Claude Code-credentials`
   via the Security framework (`SecItemCopyMatching`), parses its JSON payload, and
   takes `claudeAiOauth.accessToken`. Equivalent to
   `security find-generic-password -s "Claude Code-credentials" -w`.
2. **API** — `GET https://api.anthropic.com/api/oauth/usage` with headers
   `Authorization: Bearer <token>` and `anthropic-beta: oauth-2025-04-20`.
3. **Parse** — `JSONSerialization` into a dictionary; reads only the two
   `utilization` numbers, rounds them, and tolerates missing/`null`/extra fields.

### States & error handling

| Situation | What you see |
|---|---|
| Normal | `5hr: N%`, `Week: N%` |
| Keychain item missing | `Not logged in — open Claude Code` |
| HTTP 401 (token expired) | `Auth expired — restart Claude Code` |
| Network / decode error | keeps the **last good** numbers, or `—` if none yet |

### Extras

- Hover a usage row for a tooltip showing when that window **resets** (local time).
- When 5hr or Week utilization is high, the menu bar numbers turn
  **orange at ≥80%** and **red at ≥95%**.

## Project layout

```
Sources/main.swift        # the entire app
build.sh                  # compile + bundle + sign (+ optional install)
setup-signing.sh          # one-time: create the stable code-signing identity
menubar_agent_prompt.md   # original spec
```

## Verify the numbers

They should match a direct `curl` (run while Claude Code is logged in):

```sh
TOKEN=$(security find-generic-password -s "Claude Code-credentials" -w \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["claudeAiOauth"]["accessToken"])')
curl -s https://api.anthropic.com/api/oauth/usage \
  -H "Authorization: Bearer $TOKEN" \
  -H "anthropic-beta: oauth-2025-04-20" | python3 -m json.tool
```

`five_hour.utilization` → **5hr**, `seven_day.utilization` → **Week**.
