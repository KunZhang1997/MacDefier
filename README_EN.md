<p align="right"><a href="README.md">中文</a> · <strong>English</strong></p>

<div align="center">
  <img src="docs/images/showcase/app-icon.png" width="112" alt="MacDefier">
  <h1>MacDefier for macOS</h1>
  <p><strong>Understand why your Mac is slow, where junk lives, and what is eating your disk — and clean up safely.</strong></p>
  <p>Built natively for macOS · Preview first, unchecked by default, reversible via Trash · Native system manager & diagnostics, not antivirus</p>
  <p>
    <a href="https://kun97.tech/dl/macdefier"><strong>⬇️ Download MacDefier 0.21 (Official Notarized DMG · 19 MB)</strong></a>
    &nbsp;·&nbsp;
    <a href="https://github.com/KunZhang1997/MacDefier/releases/download/v0.21/MacDefier-0.21.dmg">GitHub Mirror</a>
    &nbsp;·&nbsp;
    <a href="https://github.com/KunZhang1997/MacDefier/releases/latest">Release Notes & SHA-256</a>
    &nbsp;·&nbsp;
    <a href="#build-from-source">Build from Source</a>
    &nbsp;·&nbsp;
    <a href="#quick-start">Quick Start</a>
    &nbsp;·&nbsp;
    <a href="README.md">中文</a>
  </p>
</div>

![MacDefier Overview](docs/images/showcase/hero-macdefier.png)

> **Core Principle**: Deterministic rules run in parallel with an optional AI advisor — **turning AI off leaves every diagnostic, cleanup, uninstall, and monitoring feature 100% intact**. All UI screenshots use anonymized sample data.

---

## Why MacDefier?

When your Mac suddenly slows down, Activity Monitor shows walls of cryptic process names. When storage runs low, closed-source cleaners often push "one-click" black-box sweeps that risk wiping active browser sessions or build caches.

| Dimension | Activity Monitor / Geek Sensor Walls | Closed-Source Subscription Cleaners | MacDefier (MIT Open Source) |
| --- | --- | --- | --- |
| **Slowdown Diagnostics** | Shows live spikes only; misses brief freezes | Often relies on scare scores & vague warnings | **10-minute slowdown replay** + 30–60s post-action re-check |
| **Cleanup Safety** | Manual `~/Library` digging, error-prone | Pre-checked bulk sweeps, opaque rules | **Unchecked by default**, path previews, active-browser protection, Trash-reversible |
| **AI Tools & Models** | No dedicated visibility | Blind to local LLMs and CLI bloat | **Dedicated scanner for Ollama models, AI app caches & CLI leftovers** |
| **Transparency & Cost** | Free but high learning curve | Recurring subscriptions, closed source | **Free notarized DMG + MIT open-source**, no account required |

---

## Five Core Experiences

### 1. Slowdown Diagnostics & 10-Minute Timeline Replay

Mac slowdowns often pass before you even open Activity Monitor. MacDefier retains synchronized 10-minute timelines around sustained load events—aligning CPU, memory swap rate, physical disk I/O, GPU, and thermal/fan readings on one scrubbable cursor so you can pinpoint the exact culprit process and verify recovery 30–60 seconds after quitting it cleanly.

![Slowdown Diagnostics and 10-Minute Replay](docs/images/showcase/showcase-01-diagnostic.png)

---

### 2. Transparent Preview Cleanup: Unchecked by Default & Trash-Reversible

No scare scores and no one-click black-box wipes. Every scanned item starts **unchecked**, showing its exact path and size. Running browsers and apps (such as Safari or Chrome) are automatically protected and skipped with a clear reason. Confirmed items move to the Trash so you can restore anything from Finder.

![Transparent Preview Cleanup](docs/images/showcase/showcase-02-safe-cleanup.png)

---

### 3. Dedicated Governance for AI Tools & Local Models

Desktop AI clients, CLI assistants, and local Ollama models can silently consume tens of gigabytes. MacDefier audits your Ollama model sizes, recent usage, and tool references alongside caches and logs from tools like Claude Desktop and Cursor—skipping active tools and letting you safely reclaim idle models.

![AI Tools and Local Model Cleanup](docs/images/showcase/showcase-03-ai-tools-models.png)

---

### 4. Disk Treemap + Clean App & Multi-Prefix CLI Uninstaller

Inspect what is taking up storage with an interactive **allocated-bytes Treemap** and drill down into large directories. When uninstalling software, MacDefier handles both standard `.app` bundles (with container leftovers) and CLI tools installed via npm, Homebrew, or uv—previewing L0 background services, L1 binaries, and L2 user data (unchecked by default), using an on-demand `UninstallHelper` only when elevated removal is required.

![Disk Treemap and Uninstaller](docs/images/showcase/showcase-04-diskmap-uninstaller.png)

---

### 5. Optional AI Advisor + Native Hardware Monitor + MIT Open Source

MacDefier includes a full local hardware monitor (per-core CPU, GPU, memory pressure & swap, disk I/O, read-only temperatures & fan RPM) and a two-column menu bar popover. The built-in `Mr. Defier` assistant is completely optional—connect your own cloud API key (stored in macOS Keychain) or local Ollama:

- **Plain-language explanations, zero silent deletions**: AI reads only your local scan snapshot and offers safe whitelist navigation buttons.
- **Independent rule engine**: Disabling AI never affects diagnostics, cleanup, uninstalling, or monitoring.

![Optional AI Advisor and MIT Open Source](docs/images/showcase/showcase-05-optional-ai-open-source.png)

---

## Free, Notarized & MIT Open Source

MacDefier is licensed under the **MIT License** with zero subscriptions or telemetry. Download the Apple-notarized installer directly, or audit and compile the SwiftUI source yourself.

| Distribution / Roadmap | Details |
| --- | --- |
| **Official Notarized DMG (Recommended)** | Download `MacDefier-0.21.dmg` (~19 MB). Apple Developer ID signed and notarized with full local cleanup and on-demand `UninstallHelper` support—completely free. |
| **Build from MIT Source** | Full SwiftUI app, unit tests, and build/CI scripts are open on GitHub for review and custom builds. |
| **Upcoming Roadmap (P1)** | **Defence · AI File-Access Alerting** is planned for a future release (alerting users when legitimate AI tools read sensitive directories due to overly broad workspace permissions—transparent notify-only alerts, **not** an antivirus engine; not included in `v0.21`). |

---

## Quick Start

1. **Download**: Grab **MacDefier-0.21.dmg** from the [Official Website](https://kun97.tech/macdefier/) or [GitHub Releases](https://github.com/KunZhang1997/MacDefier/releases/download/v0.21/MacDefier-0.21.dmg) (~`19 MB`, requires **macOS 14.0 Sonoma or later**, Universal binary for **Apple Silicon & Intel**).
2. **Install**: Open the `.dmg`, drag `MacDefier.app` into `/Applications`, and launch it.
3. **Grant Permissions on Demand**: When scanning or cleaning macOS-protected directories, allow MacDefier in **System Settings → Privacy & Security → Full Disk Access** as prompted.

`v0.21` Release Checksum (`dist/release/SHA256SUMS`):

```text
470622826fcebb1c3e9b7890f21d49cb2974c6fdf3f2855252f7261e8505f867  MacDefier-0.21.dmg
```

### Data & Permission Transparency

| Area | Behavior & Boundaries |
| --- | --- |
| **Scanning & Cleanup** | Runs 100% locally. No file lists or directory trees are uploaded. Most removals go to the Trash; see the confirmation sheet for exact details. |
| **AI Advisor (Optional)** | Disabled unless configured. Cloud API requests send only your current diagnostic/scan summary to your chosen provider (API keys stored in macOS Keychain). Local Ollama keeps all traffic on-device or on your LAN. |
| **Public IP Lookup** | The Network monitor pane queries a third-party service for your public IP; this can be turned off anytime in Settings. |

---

## FAQ

<details>
<summary><strong>Can I use all cleanup and uninstall features without configuring AI?</strong></summary>

Yes. MacDefier runs deterministic rules and system APIs independently from AI. Diagnostics, cleanup previews, Disk Treemap, App/CLI uninstalling, and hardware monitoring all work at 100% capacity with AI turned off.

</details>

<details>
<summary><strong>Could cleanup delete active browser data or remove files permanently?</strong></summary>

No black-box deletions occur. All scan results start unchecked so you review exact paths first; active browsers and AI tools are automatically skipped; and standard cleanups move items to the Trash so they can be restored from Finder.

</details>

<details>
<summary><strong>How is MacDefier different from Stats or CleanMyMac?</strong></summary>

Stats focuses on dense geek-oriented sensor menus, while CleanMyMac is a closed-source subscription cleaner. MacDefier brings slowdown replay diagnostics, transparent Trash-reversible cleanup, AI tool/model storage governance, and MIT open-source auditability into one native workbench for everyday Mac users and developers.

</details>

<details>
<summary><strong>Does it run on Intel Macs? What macOS version is required?</strong></summary>

Yes. `MacDefier-0.21.dmg` is a Universal build supporting both **Apple Silicon and Intel Macs** running **macOS 14.0 Sonoma or later**. Availability of certain hardware sensors (such as read-only temperature and fan RPM) varies by Mac model and permissions.

</details>

---

## Build from Source

Requires macOS 14.0 or later, Xcode (verified with Xcode 27.1), and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
git clone https://github.com/KunZhang1997/MacDefier.git
cd MacDefier/app
./rebuild_and_launch.sh
```

Routine rebuilds use Release configuration with the `com.macdefier.app` bundle ID and update `/Applications/MacDefier.app` in place. You can also install a signed bundle or local Release build via `bash app/scripts/install-app.sh /path/to/MacDefier.app`. Run `bash app/rebuild_and_launch.sh --self-test` to validate script boundaries and rollback behavior in isolation without touching the running app.

### Checks & Tests

Run all unit tests and Debug / Release builds from the repository root:

```bash
bash app/scripts/ci.sh
```

The CI script uses isolated cache directories and runs unique-build-lock & Sparkle feed checks, `UninstallHelperKit` / `CleanupKit` / `PetArchiveKit` / `MonitorKit` unit tests, `MacDefierTests`, and validates both Debug and Universal Release builds.

### Project Structure

| Path | Contents |
| --- | --- |
| `app/MacDefier/` | SwiftUI application, diagnostics, AI advisor, and assets |
| `app/MacDefierTests/` | Main app unit tests (AI, diagnostics, layout, updates, onboarding, localization) |
| `app/CleanupKit/` | Scanning, cleanup, uninstalling, and protection rules |
| `app/MonitorKit/` | System resource sampling |
| `app/PetArchiveKit/` | Window-pet archive import and validation |
| `app/UninstallHelperKit/` | Uninstall helper protocol, privilege boundaries, client, and tests |
| `app/UninstallHelper/` | On-demand privileged uninstall helper |
| `app/Vendor/ZIPFoundation/` | Pinned ZIPFoundation dependency |
| `app/scripts/` | Build, verification, and packaging scripts |

---

## License & Acknowledgments

MacDefier source code is licensed under the [MIT License](LICENSE). Use, modification, distribution, and commercial use are permitted provided the license and copyright notice are preserved.

Third-party components retain their respective licenses and attributions (see [app/NOTICE](app/NOTICE)): [Stats](https://github.com/exelban/stats), [PureMac](https://github.com/momenbasel/PureMac), [ZIPFoundation](https://github.com/weichsel/ZIPFoundation), and [Sparkle](https://github.com/sparkle-project/Sparkle) (MIT); sample pet sprite [The Robot - Free Sprite](https://opengameart.org/content/the-robot-free-sprite) (CC0).

Issues and Pull Requests are welcome via [GitHub Issues](https://github.com/KunZhang1997/MacDefier/issues). Please strip API keys and personal paths from any logs before submitting.
