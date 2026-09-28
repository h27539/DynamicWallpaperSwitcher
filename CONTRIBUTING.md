# Contributing

Open an issue before large changes. Describe the macOS version, CPU architecture, source video properties, and the separate lock-screen and post-unlock results. Use small synthetic media in reproducible tests.

- Do not submit Apple proprietary wallpaper videos, copied Apple localization bundles, system manifest snapshots, or personal media.
- Do not propose SIP bypasses or writes to `/System`.
- Keep manifest and localization changes backed up, validated, and atomically committed. Limit removal to assets the App owns.
- Run the compatibility checker for conversion changes. Changes to the temporal hierarchy or sample-group structure need per-sample validation data and real-host lock/unlock results.
- Run `swift test --disable-sandbox` and the Release Xcode build. Note any skipped local-only tests.
- Redact user names, home paths, Apple IDs, device identifiers, and private logs from reports and pull requests.

See [development](docs/development.md) and the [pull request template](.github/pull_request_template.md).
