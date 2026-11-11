# HyperVaultBar project guide

Keep this file current when the architecture, API handling, UI, build process, or release workflow changes. Update `README.md` alongside user-visible behavior changes.

## Project

- Native SwiftUI `MenuBarExtra` app targeting macOS 26 or later. The extra uses `.window` style; `SettingsWindowController` presents the Settings window.
- `LSUIElement` hides the Dock icon. The sandbox entitlement allows outgoing network requests.
- No third-party dependencies or Hyperliquid API key. The app is independent and is not affiliated with or endorsed by Hyperliquid.
- `BalanceService.swift` handles `/info` requests and defensive parsing with a shared URL session and time-split ledger queries. `BalanceViewModel.swift` owns refresh tasks and UI state. `NotificationService.swift` handles system notification permission and delivery. `Money.swift` handles formatting. `MovementHistoryStore.swift` persists movement samples and delivery state. `SnapshotStore.swift` persists wallet-and-vault-specific equity history. `VaultFlowStore.swift` persists verified ledger coverage per wallet and vault. `SettingsStore.swift` persists preferences and manages launch at login. `FlowAdjustedMetrics.swift` and `DrawdownAlertState.swift` hold calculation logic.

## Invariants

- Wallet edits use a draft. Change confirms the address in Settings, Cancel discards the draft, and Save persists confirmed changes. The three alert threshold fields share the same width.

- Wallet and vault addresses must match `0x` plus 40 hexadecimal characters. The default vault is shown as Hyperliquidity Provider (HLP) in Settings, which can also select a custom vault.
- A fresh install has no default wallet. Existing saved wallet addresses remain intact. When the API has no entry for the selected vault, show "No position" separately from a genuine zero equity entry.
- Settings shows a saved wallet read-only until Change is clicked; a fresh install opens an editable wallet field. The vault picker must show the full Hyperliquidity Provider (HLP) name, and the popover Settings action has no icon.
- Settings stretches the wallet, vault, and refresh rows to the same card width. The compact Change wallet button and intrinsically sized vault and refresh pickers align at the right edge of a 290-point control column; the Settings header shows the same locally bundled Hyperliquid logo as the popover.
- Settings offers Reduce transparency, persisted in UserDefaults on Save; the menu bar popup uses an opaque window background when enabled.
- Settings extends its scroll view 18 points toward the window's right edge and gives its content 30 points of trailing padding, keeping the scroll bar to the right of rounded cards.
- In Reduce transparency mode, popup action buttons have subtle outlines in their idle state; hover and press remain solid #307863.
- The refresh interval is configured only in Settings. Its default is 15 minutes, with a minimum of 15 seconds. Changing it cancels and replaces the timer; preserve an existing saved choice.
- On macOS wake, replace any in-flight refresh and restart the timer so data is requested immediately. Observe `NSWorkspace.didWakeNotification` through the workspace notification center.
- Whole-dollar balance displays truncate cents; the detailed personal balance keeps two decimals.
- `userVaultEquities` supplies personal equity. `vaultDetails` supplies the vault name, APR, and sampled vault-wide balance. Do not describe that value as an exact real-time quote. The popover does not show the sample timestamp.
- Keep the popover's 24-hour row compact: a short semantic label, a right-aligned signed value, and a tooltip explaining cash-flow adjustment. Summarize errors by their user-visible consequence and place raw messages in the collapsed Technical details disclosure rather than repeating them inline.
- Popover action buttons use #307863 for hover and press highlights with white text for contrast.
- The popover header has a small locally bundled Hyperliquid logo at the top right; its transparent #307863 image asset is derived from the source SVG linked in README.
- Omit the 24-hour percentage in the menu bar and popover when its absolute value is below 0.1%; retain the dollar change in the popover.
- A 24-hour value from equity snapshots is a balance change until vault deposits and withdrawals from `userNonFundingLedgerUpdates` have been subtracted. Do not treat cumulative `followerState.pnl` as 24-hour PnL. If ledger data is incomplete, keep the raw label and pause drawdown alerts.
- Do not treat undocumented follower-state fields as daily PnL. Reject unrecognizable vault detail objects. HTTP 429 pauses automatic retries for at least one minute; 5xx errors are reported distinctly.
- Decode optional APR from a JSON number or numeric string. A successful balance response must not clear an active rate-limit pause from another refresh branch. A matching vault ledger entry without a movement type invalidates coverage.
- History is stored separately for each wallet and vault. Regular snapshot writes are throttled to five minutes, but new raw or cash-flow-adjusted seven-day highs are saved immediately. Points older than eight days are pruned. Surface storage errors instead of silently losing history. Ledger ranges are split if the API returns 500 rows; each refresh replaces the most recent hour of cached data to capture late entries, preserving duplicate transactions. Never calculate adjusted change or alert from incomplete coverage.
- Show a warning when vault details cannot be refreshed. Settings explains local history and offers a test notification.
- Request notification permission when alerts are enabled. Record a threshold crossing as notified only after the local notification request is accepted. Rearm after recovery below half the threshold.
- Settings attempts notification authorization when enabling alerts without blocking preference saves on denial; login registration must succeed before preferences are committed.

## Build and verification

The Finder app icon uses `Assets.xcassets/AppIcon.appiconset` with macOS 1x and 2x sizes. The menu bar continues to display the balance label.

The Settings footer places the independence notice and version 16 points below the Save/Cancel row.

Settings reads the version from `CFBundleShortVersionString`. Update `MARKETING_VERSION` in both app build configurations for each release. Alert thresholds support direct entry and native steppers with a 0.1 increment.

Run `xcodebuild test -project HyperVaultBar.xcodeproj -scheme HyperVaultBarTests -configuration Debug -destination 'platform=macOS' -derivedDataPath /private/tmp/HyperVaultBarDerived CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO` for logic tests.

Run `xcodebuild -project HyperVaultBar.xcodeproj -scheme HyperVaultBar -configuration Release -sdk macosx -derivedDataPath /private/tmp/HyperVaultBarReleaseDerived CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build` for a release build. Verify its signature with `codesign --verify --deep --strict`.

When updating the installed copy, preserve existing snapshot files, close the running `/Applications/HyperVaultBar.app`, copy the verified release with `ditto`, launch it, and confirm the new process remains running. Check migrations preserve historical points. UI automation may not expose menu-bar-only apps; report that limitation rather than claiming visual verification.

Movement alerts are optional and configured separately for balance and APR in Settings. Defaults: balance ±0.1% over 15 minutes, APR ±1 percentage point over one hour, 30-minute cooldown. Users select direction, threshold, window, and cooldown. Comparisons require a full local history window; history and successful-delivery state persist per wallet/vault in UserDefaults. Balance comparisons subtract verified vault cash flows and pause if the ledger is unavailable. APR comparisons use reported APR fractions converted to percentage points. Rearm below half the threshold or on direction reversal, and enforce cooldown. Only accepted notifications consume a crossing. Detection follows the configured refresh interval. MovementAlertHistory and configuration live in DrawdownAlertState.swift for isolated logic tests.

Balance and vault-details refresh branches run independently: a failed personal-equity request must not block APR processing, and slow vault details must not delay balance movement checks. Movement comparisons select the nearest eligible historical point, allowing up to 30 seconds (or 5% of the window) of request jitter. Notification copy uses friendly rounded minutes or hours, puts the movement amount in the title, and omits internal cash-flow wording. Settings shows per-alert readiness, history collection, pauses, cooldown, and rearming status for saved settings.

Settings groups all alerts in one Notifications card with consistent labeled toggles. Disabled movement alerts show only a toggle; enabled alerts expose a threshold and concise summary. Direction, comparison window, cooldown, and detailed status live in a collapsed Advanced disclosure.

Settings explains disabled Save near the button, shows notification failures beside enabled toggles without expanding Advanced, and uses a vault-neutral subtitle.

Disabled movement alerts do not block Save because of invalid hidden parameters. Alert steppers sit directly after the number fields, followed by the units. Hovering over "%pt" in APR shows the inline tooltip "Percentage point".

Automatic/manual refreshes skip a running cycle; settings changes replace it. Completion of an older cancelled cycle cannot clear a newer cycle's running state. Notification authorization is requested only when enabling an alert, and denial is displayed without blocking preference saves. Corrupted ledger JSON is archived with a unique .corrupt suffix and refetched automatically. Corrupted balance history stays untouched until the user confirms Restart balance history in the popover; the file is archived and comparisons rebuild from new samples. I/O failures are still surfaced. RefreshTests exercises the view model with injected networking and notification permission responses.

Opening Settings dismisses the menu-bar popover before presenting the Settings window.

Refresh interval presets include 30 minutes (1800 seconds).

The menu bar label shows the balance followed by the signed percentage change without an up/down arrow.

Settings warns next to enabled movement alerts when the selected refresh interval exceeds their comparison window. The warning follows unsaved preset/custom interval edits and does not block saving or change the user's interval.

When balance visibility is disabled, the menu bar label is `••••`; do not expose the vault name or type there.
