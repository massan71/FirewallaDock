# FirewallaDock

A macOS Dock app that shows the status of your Firewalla network, reading data through the [Firewalla MSP API v2](https://docs.firewalla.net).

> Independent project, not affiliated with or endorsed by Firewalla Inc.

## Features

- **Dock icon badge** with the number of active alarms (optionally security alarms only); `!` when the connection fails
- **Dock menu** (right-click): box status, active alarms, devices online, recent alarms, manual refresh
- **Menu bar icon** (optional): shield with the alarm count and a panel with box status, alarm and device counts, recent alarms and quick actions; the Dock icon can be hidden to use the app only from the menu bar
- **Overview**: stats, box list, daily charts of alarms and blocked flows, alarms by type
- **Alarms**: search, filter by type, new/seen tracking, archive selected or all seen alarms; right-click to **mute** an alarm type, domain or IP (everywhere or for one device) or **block** the remote domain or IP with a new rule (requires a *Full Access* token)
- **Devices**: sortable table with IP, MAC, vendor, network, traffic
- **Rules**: every Firewalla rule with its target, scope and hit count, a switch to pause or resume it, and right-click to delete it (requires a *Full Access* token)
- **Flows**: all or blocked only, with advanced [search queries](https://docs.firewalla.net/api-reference/search/) (requires a paid MSP plan, see below)
- Automatic refresh (1–60 min, and right after the Mac wakes up or the network comes back) and notifications for new alarms
- Optional open at login
- API token stored in the Keychain and only ever sent over HTTPS; sandboxed app with outgoing network access only

> The MSP API has no endpoint to switch box services (ad block, family protection, VPN server…) on or off, so the app controls rules instead.

## Requirements

- macOS 14 or later
- Xcode 16 or later
- A [Firewalla MSP](https://firewalla.net) account with an API token

> **Note:** flow data (the Flows section and the "Blocked flows per day" chart) is a paid feature. It is only available on some Firewalla MSP plans and must be enabled there; otherwise the API returns no flows.

## Building

```bash
git clone https://github.com/massan71/FirewallaDock.git
cd FirewallaDock
open FirewallaDock.xcodeproj
```

Then press ⌘R in Xcode. From the command line:

```bash
xcodebuild -project FirewallaDock.xcodeproj -scheme FirewallaDock -configuration Release -derivedDataPath build/DerivedData build
cp -R build/DerivedData/Build/Products/Release/FirewallaDock.app /Applications/
```

The app is ad-hoc signed ("Sign to Run Locally"); to distribute it, set your development Team in Xcode.

### Publishing a release

```bash
scripts/release.sh 1.3 notes.md
```

Sets the version (and bumps the build number), builds a clean universal Release, zips and verifies it, then asks for confirmation before committing, tagging, pushing and creating the GitHub release. `notes.md` holds the "What's new" text; install steps and the zip's SHA-256 are added automatically. It stops before pushing anything if the working tree isn't clean, `main` isn't in sync with GitHub, the tag exists or a check fails.

## Setup

1. In Firewalla MSP: **Settings → MSP API → Create New Token**. *Read Only* is enough for viewing; *Full Access* is needed to archive or mute alarms and to create, pause, resume or delete rules.
2. Open the app → **Settings** (⌘,).
3. Enter the base URL (`https://<yourdomain>.firewalla.net` or `https://firewalla.net/api`) and the token, then click **Save and Test**.

## Troubleshooting

`scripts/probe.py` checks what the MSP API actually returns for your account. It asks for the base URL and token (the token is hidden and never stored) and saves the responses to `build/probe/`, which is ignored by git:

```bash
python3 scripts/probe.py                  # one request per endpoint, with the response structure
python3 scripts/probe.py --count-alarms   # count all active alarms by type, to compare with the Dock badge
```

The saved responses contain your device names and MAC addresses, so do not share them.

## Project structure

| File | Contents |
|---|---|
| `FirewallaDock/FirewallaAPI.swift` | HTTP client for the `/v2/boxes`, `/v2/devices`, `/v2/alarms`, `/v2/flows`, `/v2/rules`, `/v2/trends/*` endpoints, plus alarm archive/mute and rule create/pause/resume/delete |
| `FirewallaDock/Models.swift` | Data models with lenient decoding |
| `FirewallaDock/Store.swift` | State, periodic refresh, Dock badge, notifications |
| `FirewallaDock/App.swift` | Entry point and Dock menu |
| `FirewallaDock/Views.swift` | SwiftUI interface |
| `FirewallaDock/MenuBarView.swift` | Menu bar icon and panel |
| `FirewallaDock/AppPresence.swift` | Open at login and Dock icon visibility |
| `FirewallaDock/RulesView.swift` | Rules list with pause/resume and delete |
| `FirewallaDock/AlarmActions.swift` | Mute and block options offered for an alarm |
| `FirewallaDock/Keychain.swift` | Keychain storage for the token |

## License

Released under the [MIT](LICENSE) license.
