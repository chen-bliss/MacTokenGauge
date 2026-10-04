# Contributing

Use macOS 14 or later and Xcode 16 or later. There are no third-party package dependencies.

1. Fork the repository and create a branch.
2. Run `swift test` for the offline regression suite.
3. Run `scripts/package.sh dist` to build both Apple silicon and Intel versions and verify packaging.
4. Optionally run `scripts/preview.sh` to render the actual panel with synthetic data on a Mac graphical session.
5. Describe the problem, changed behavior and validation in your pull request.

Provider parsing changes need a synthetic or sanitized fixture and a regression test. Never commit login tokens, credential files, email addresses, raw local logs or real response bodies containing account identifiers. Use the app's whitelist-based diagnostic export when reporting an issue. State your app version, macOS version and enabled provider separately.

Manual checks should cover first launch, unavailable and paused states, stale readings, a battery graphic slot without the separate battery display, small screens, keyboard access and VoiceOver. Check Arabic layout direction as well as Chinese and English. Do not query real accounts in automated tests.

Contributions are under the repository's MIT license.
