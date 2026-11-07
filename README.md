# FirewallaDock

A macOS Dock app that shows the status of your Firewalla network, reading data through the [Firewalla MSP API v2](https://docs.firewalla.net).

> Independent project, not affiliated with or endorsed by Firewalla Inc.

## Features

- **Dock icon badge** with the number of active alarms (optionally security alarms only); `!` when the connection fails
- **Dock menu** (right-click): box status, active alarms, devices online, recent alarms, manual refresh
- **Overview**: stats, box list, daily charts of alarms and blocked flows, alarms by type
- **Alarms**: search, filter by type, archive (requires a *Full Access* token)
- **Devices**: sortable table with IP, MAC, vendor, network, traffic
- **Flows**: all or blocked only, with advanced [search queries](https://docs.firewalla.net/api-reference/search/)
- Automatic refresh (1–60 min) and notifications for new alarms
- API token stored in the Keychain; sandboxed app with outgoing network access only

## Requirements

- macOS 14 or later
- Xcode 16 or later
- A [Firewalla MSP](https://firewalla.net) account with an API token

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

## Setup

1. In Firewalla MSP: **Settings → MSP API → Create New Token** (*Read Only* is enough for viewing).
2. Open the app → **Settings** (⌘,).
3. Enter the base URL (`https://<yourdomain>.firewalla.net` or `https://firewalla.net/api`) and the token, then click **Save and Test**.

## Project structure

| File | Contents |
|---|---|
| `FirewallaDock/FirewallaAPI.swift` | HTTP client for the `/v2/boxes`, `/v2/devices`, `/v2/alarms`, `/v2/flows`, `/v2/trends/*` endpoints |
| `FirewallaDock/Models.swift` | Data models with lenient decoding |
| `FirewallaDock/Store.swift` | State, periodic refresh, Dock badge, notifications |
| `FirewallaDock/App.swift` | Entry point and Dock menu |
| `FirewallaDock/Views.swift` | SwiftUI interface |
| `FirewallaDock/Keychain.swift` | Keychain storage for the token |

## License

Released under the [MIT](LICENSE) license.
