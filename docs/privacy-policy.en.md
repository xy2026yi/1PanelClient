# 1PanelClient Privacy Policy

> This document is the single source of truth of the privacy policy: the in-app fallback page
> (Settings → About → Privacy Policy) is generated from this file at build time (bundled as
> `PrivacyPolicy.en.md`, rendered by `PrivacyPolicyView`); the online version is this page.
> Edit this file only — rebuilding the app picks up the change.
> Last updated: 2026-10-19

## Overview

1PanelClient is an iOS client for the open-source server management panel [1Panel](https://1panel.cn).
This app **does not collect or upload any user data** — no embedded analytics SDK, no ads, no tracking, no accounts.

## Data Storage & Usage

| Data | Storage | Purpose | Leaves device? |
|---|---|---|---|
| Panel address, name & API key | iOS Keychain | Connect to your own 1Panel panel | No (sent only to the panel address you configure) |
| App preferences | Local UserDefaults | Remember your settings | No |
| App-lock passcode | System Keychain / local | Local unlock verification | No |
| Local cache of panel data | Local app sandbox | Show the most recent snapshot offline | No |
| Diagnostic data (MetricKit) | Local Application Support | Crash & performance self-diagnostics, kept for 30 days | No (only when you explicitly share an export from the Diagnostics page) |

## Network Requests

Panel requests are sent only to the panel addresses **you add yourself**.
**Checking for updates** anonymously accesses the GitHub API (`api.github.com`) to fetch the latest version and release notes of this app; the request carries no identity or device identifier. Apart from this request, the app does not connect to any developer or third-party server.
If you configure an `http://` plain-text address, the UI will call out the risk, and you can enable "HTTPS only" in Settings.

## Permissions

- **Local Network**: used to reach panels on your LAN; the system permission prompt appears only when you actively test a connection.
- **Face ID / Touch ID**: used only to unlock the app lock (optional feature); no biometric data is uploaded.

## Data Deletion

Uninstalling the app removes all local data (Keychain entries are cleared with the uninstall); the panel-side API key can be disabled or regenerated at any time in the 1Panel panel under "Panel Settings → API".

## Contact

Feedback via repository issues: https://github.com/xy2026yi/1PanelClient/issues
