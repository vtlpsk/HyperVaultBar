# HyperVaultBar

SwiftUI menu bar app for macOS 26+. An AppKit `NSStatusItem` handles clicks and anchors a borderless `NSPanel` with SwiftUI content. Uses `LSUIElement` and sandboxed outgoing network access. No dependencies or API key. Keep this guide current and update README when behavior changes.

## Code map

- `BalanceService` calls Hyperliquid’s `/info` API. `BalanceViewModel` coordinates refreshes, display state, and alerts.
- `SnapshotStore` stores equity samples, `VaultFlowStore` caches verified ledger coverage, and `MovementHistoryStore` stores alert samples and delivery state. Scope history to the wallet and vault.
- `FlowAdjustedMetrics` and `DrawdownAlertState` handle calculations. `SettingsStore` manages preferences and launch at login. `NotificationService` handles permission and delivery. `Money` formats values.

## Refresh and data

- Refresh defaults to 15 minutes and has a 15-second minimum. Configure it in Settings only, with a 30-minute preset. Settings saves and macOS wake replace any running cycle and restart the timer. Scheduled and manual refreshes skip an active cycle. A cancelled cycle must not clear its replacement’s state.
- Fetch personal equity and vault details independently. Treat a missing vault entry as “No position” and preserve actual zero equity. Vault balance is sampled. Accept APR as a number or numeric string, reject unrecognizable details, and report HTTP 5xx distinctly.
- HTTP 429 pauses scheduled and manual refreshes for 60 seconds. Wake and settings replacements bypass the pause. Success in another request must not clear it.
- Treat the difference between equity snapshots as balance change until verified ledger flows are subtracted. Cumulative `followerState.pnl` is not daily PnL. Incomplete ledger coverage keeps the raw label and pauses balance alerts. A matching row without a movement type invalidates coverage.
- Split ledger queries that return 500 rows. Refetch the most recent hour to catch late entries and preserve duplicate transactions.
- Save equity samples at most every five minutes, except new raw or adjusted seven-day highs. Prune samples older than eight days. Report storage failures. Archive corrupt ledger files as `.corrupt-<UUID>` and refetch. Archive corrupt equity history only after the user confirms a reset.

## Alerts

- Request permission when enabling alerts or sending a test notification. Denial must not block saving. Record a crossing only after the notification request is accepted.
- Drawdown re-arms after recovery below half the threshold. Balance and APR movement alerts default to ±0.1% over 15 minutes and ±1 percentage point over one hour, respectively, with a 30-minute cooldown. Movement alerts re-arm below half the threshold or on direction reversal.
- Use the nearest sample to the full comparison window, with tolerance capped at the smaller of 30 seconds and 5% of the window. Balance alerts use verified cash flows. APR alerts compare percentage points. Detection follows the refresh interval. Notification titles show the amount and body text uses rounded minutes or hours.

## Interface

- Center the arrowless popup below the status button when opening it. Shift it inward near the screen edge to keep it visible. Keep its position when the balance label changes width. Close it on outside left clicks without consuming the click.

- A fresh install has no wallet. Validate wallet and vault addresses as `0x` plus 40 hex characters. Show saved addresses as read-only until **Change wallet**. **Change** confirms the draft, **Cancel** discards it, and **Save** persists it. A launch-at-login registration failure blocks saving.
- The menu bar shows whole dollars with cents truncated, plus a signed 24-hour percentage without arrows. Hide the percentage below 0.1% in magnitude. The popup keeps the dollar change and shows personal equity to two decimals. Hide Balance displays `eye.slash` in the menu bar with a tooltip identifying the app and hidden state.
- Keep the popup’s 24-hour row compact and explain cash-flow adjustment in its tooltip. Show the consequence of a data error, with raw messages under **Technical details**. Warn when vault details are stale. Omit the vault sample timestamp.
- A left click opens the popup. A right click opens a native menu with Refresh, Hide Balance or Show Balance, Settings, and Quit. Opening **Settings** from the popup dismisses it. Keep that action icon-free. Show the full **Hyperliquidity Provider (HLP)** name in the picker and allow a custom vault.
- Align wallet, vault, and refresh controls at the right edge of the 290-point column. Keep the scrollbar outside the cards. Use the bundled Hyperliquid logo in the popup and Settings. Reduce transparency takes effect on Save and gives the popup a solid background with subtle outlines on idle buttons. Hover and press use `#307863` with white text.
- Group alerts under **Notifications**. Show only the toggle for disabled movement alerts and ignore hidden values during Save validation. Enabled alerts show a threshold and summary, with direction, window, cooldown, and status under **Advanced**. Show permission errors beside enabled toggles and explain a disabled Save near the button. Warn when the pending refresh interval exceeds the comparison window without blocking Save.
- Use equal-width threshold fields with direct entry and 0.1-step controls. The `%pt` tooltip reads “Percentage point”. Keep the independence notice and version below the Save/Cancel row. Read the version from `CFBundleShortVersionString`. The Finder icon is in `Assets.xcassets/AppIcon.appiconset`.

## Build and verify

The app bundle uses `HyperVaultBar/AppIconFallback.icns` via `CFBundleIconFile`. Regenerate all sizes from the same 860×860 crop of the 1024×1024 master in `Assets.xcassets/AppIcon.appiconset`. Fill transparent corners with dark teal so Apps and Spotlight receive artwork without transparent padding. Verify the bundle icon includes small and Retina sizes.

Run logic tests on macOS:

```sh
xcodebuild test -project HyperVaultBar.xcodeproj -scheme HyperVaultBarTests \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/HyperVaultBarDerived CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO
```

Build and verify a local release:

```sh
xcodebuild -project HyperVaultBar.xcodeproj -scheme HyperVaultBar \
  -configuration Release -sdk macosx \
  -derivedDataPath /private/tmp/HyperVaultBarReleaseDerived CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build
codesign --verify --deep --strict /private/tmp/HyperVaultBarReleaseDerived/Build/Products/Release/HyperVaultBar.app
```

To update the installed copy, quit the running app, copy the verified build to `/Applications/HyperVaultBar.app` with `ditto`, and confirm it stays running. Preserve snapshots and verify migrations when they change. Report when UI verification is unavailable.

## Publish

Check the diff against `origin/main` before publishing to `vtlpsk/HyperVaultBar`. Keep real wallet addresses, personal balances, and local history out of public files and Git history. Use sample data in screenshots. For a downloadable GitHub Release, update `MARKETING_VERSION` in both app build configurations.
