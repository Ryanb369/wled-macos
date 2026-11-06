# WLED Control for macOS

A native macOS menu bar app for discovering and controlling WLED lights on your local network, with optional Codex completion and attention alerts.

> **Early build — version 0.1.0.** Expect rough edges and changes as the project develops.

## Features

- Discover WLED fixtures on the local network using Bonjour.
- Control power, brightness, color, and presets from the menu bar or detailed fixture window.
- Save the current state as a named WLED preset and open the fixture's web interface for advanced settings.
- Customize click and hold actions, use keyboard shortcuts, and assign icons to fixtures.
- Optionally configure per-fixture Codex completion and attention alerts using WLED presets.

## Requirements

- macOS 13 or later
- Xcode or the Xcode Command Line Tools, including Swift
- One or more WLED devices reachable on the same local network, advertising the `_wled._tcp` Bonjour service

## Build and run

Clone this repository, then run:

```sh
./build.sh
open "build/WLED Control.app"
```

The build script creates an ad-hoc signed app locally. Allow local network access when prompted so the app can find and control your lights. If a fixture is missing, check its network connection and Bonjour availability, then refresh the fixture list.

## Getting started

Open the menu bar icon to see discovered fixtures. Click a fixture to use its configured action, or right-click to choose an icon or open detailed controls. Open Settings to customize actions and configure integrations. The Fixture menu also provides keyboard shortcuts for common controls.

For Codex alerts, open Settings, install the Codex connection, and select completion and attention presets for each fixture. This modifies local Codex hook and notification configuration; the settings screen also provides repair and removal controls.

The app communicates with WLED through its local JSON API (`/json/info`, `/json/state`, and `/presets.json`).

## Contributing

Issues and pull requests are welcome. Fork the repository, make your changes, and describe how you tested them. This is an early project, so feedback and bug reports are especially helpful.
