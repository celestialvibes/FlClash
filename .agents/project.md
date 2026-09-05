# Project Context

FlClash is a multi-platform proxy client based on ClashMeta (mihomo), built with Flutter. It supports Android, Windows, macOS, and Linux, using a Material You design with Surfboard-like UI.

## Version Notes

- Release CI pins Flutter 3.44.4. Local SDK may diverge, so trust the CI
  version as the source of truth for release builds.
- Dart SDK constraint: `>=3.8.0 <4.0.0`.

## Build Dependencies

Linux:

```bash
sudo apt-get install libayatana-appindicator3-dev libkeybinder-3.0-dev
```

Windows:

- GCC and Inno Setup.
- `ANDROID_NDK` env var for Android builds.

macOS:

```bash
npm install -g appdmg
```

## LOOM Fork Maintenance

The local baseline immediately before the first LOOM-specific commit is
`62addf738a76b1a492e19af2dbabdb6d572b9e72` (parent of `9984034`). This is a
comparison point in this checkout, not a claim about the latest upstream release.
At review on 2026-09-05, `core/Clash.Meta` still points to the same commit as that
baseline: `0f7f05adff5e2c49775a112dcfe05a6aa36fda0c`.

Keep account, subscription, support, push, and presentation behavior in the
existing `lib/common/loom_*` helpers and `lib/views/loom.dart`. Shared profile
storage, HTTP downloads, and listener arbitration belong in their existing
shared implementations; do not copy these into a second LOOM runtime.

The Go-wrapper changes since the baseline serve two client requirements:
`parseProfileConfig` accepts legacy URI subscriptions using Mihomo's converter,
and `getVersion` exposes the actual engine version. Preserve both contracts when
merging upstream. Neither requires editing the Mihomo submodule. Native changes
also include branding, platform configuration, and platform integration; inspect
them separately from the subscription UI.

Before an upstream update, inspect the maintained boundary with:

```bash
git diff 62addf738a76b1a492e19af2dbabdb6d572b9e72 HEAD -- core/ lib/core/ android/ services/ macos/ windows/
git diff 62addf738a76b1a492e19af2dbabdb6d572b9e72 HEAD -- lib/common/loom_auth.dart lib/common/loom_support.dart lib/views/loom.dart
```

Use the existing protocol, desktop lifecycle, service, and provider checks listed
in `commands.md` after an upstream merge. Keep connectivity monitoring inside
Mihomo and native platform owners; an app-resume or network callback must not
invent a new start request. Wi-Fi auto-pause/resume uses
`SetupAction.syncListenerState()` so a later disconnect wins.

Subscription HTTP 404/410 means an invalid or revoked link, not expiry. LOOM Next
can return HTTP 200 with a deliberately unusable profile carrying a plan/access
message. Preserve that response; show expiry from `subscription-userinfo` when
available rather than guessing it from transport failures.
