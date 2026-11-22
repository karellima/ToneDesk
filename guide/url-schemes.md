# URL Schemes

Control ToneDesk from Terminal, shell scripts, [Shortcuts](https://support.apple.com/guide/shortcuts-mac), [Raycast](https://raycast.com), or any app that can open URLs. This makes it easy to automate volume changes, build keyboard shortcuts, or integrate ToneDesk into your workflow.

## Actions

| Action | Format | Description |
|--------|--------|-------------|
| Set volume | `tonedesk://set-volumes?app=BUNDLE_ID&volume=PERCENT` | Set volume (`0–100`; per-app boost is configured separately) |
| Step volume | `tonedesk://step-volume?app=BUNDLE_ID&direction=up` | Nudge volume up or down by 5% (`up`/`+` or `down`/`-`) |
| Set mute | `tonedesk://set-mute?app=BUNDLE_ID&muted=true` | Mute or unmute one or more apps (`true`/`false`, `1`/`0`, `yes`/`no`) |
| Toggle mute | `tonedesk://toggle-mute?app=BUNDLE_ID` | Toggle mute state for one or more apps |
| Set device | `tonedesk://set-device?app=BUNDLE_ID&device=DEVICE_UID` | Route an active app to a specific output |
| Reset | `tonedesk://reset` | Reset all apps (or specific `?app=…` entries) to 100% and unmuted |

## Examples

```bash
# Set Spotify to 50% volume
open "tonedesk://set-volumes?app=com.spotify.client&volume=50"

# Set different volumes for different apps at once
open "tonedesk://set-volumes?app=com.spotify.client&volume=80&app=com.hnc.Discord&volume=40"

# Mute multiple apps at once
open "tonedesk://set-mute?app=com.spotify.client&muted=true&app=com.apple.Music&muted=true"

# Toggle mute for Discord
open "tonedesk://toggle-mute?app=com.hnc.Discord"

# Step Discord volume down
open "tonedesk://step-volume?app=com.hnc.Discord&direction=down"

# Route an app to a specific device
open "tonedesk://set-device?app=com.spotify.client&device=YOUR_DEVICE_UID"

# Reset a single app or everything
open "tonedesk://reset?app=com.spotify.client"
open "tonedesk://reset"
```

## Use Cases

**Meeting mode** — Mute music apps while keeping your video call active:

```bash
open "tonedesk://set-mute?app=com.spotify.client&muted=true&app=com.apple.Music&muted=true"
```

**Focus playlist** — Set music to a low background level and silence notifications:

```bash
open "tonedesk://set-volumes?app=com.spotify.client&volume=30&app=com.apple.systemuiserver&volume=0"
```

**Gaming setup** — Keep the game at full volume and lower Discord:

```bash
open "tonedesk://set-volumes?app=com.game.example&volume=100&app=com.hnc.Discord&volume=40"
```

These commands work in Terminal, shell scripts, Automator, Raycast script commands, macOS Shortcuts (using **Open URLs**), and any other tool that can open URLs.

## Finding Bundle IDs

App names shown in ToneDesk map to bundle IDs. Common ones:

| App | Bundle ID |
|-----|-----------|
| Spotify | `com.spotify.client` |
| Apple Music | `com.apple.Music` |
| Chrome | `com.google.Chrome` |
| Safari | `com.apple.Safari` |
| Discord | `com.hnc.Discord` |
| Slack | `com.tinyspeck.slackmacgap` |
| Zoom | `us.zoom.xos` |
| Firefox | `org.mozilla.firefox` |
| Arc | `company.thebrowser.Browser` |

To find any app's bundle ID:

```bash
osascript -e 'id of app "App Name"'
```

## Finding Device UIDs

In ToneDesk, click the **info button (`i`)** on any output device row to open the device inspector, then click the copy button next to the UID to put it on the clipboard.
