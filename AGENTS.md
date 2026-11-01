# AGENTS.md - Clicky

## Repository layout

- `leanring-buddy/` contains the macOS app target and its bundled resources.
- `leanring-buddyTests/` and `leanring-buddyUITests/` contain test targets.
- `src/` contains the Cloudflare Worker proxy.
- `scripts/` contains release automation.
- `assets/` contains non-bundled documentation and release media.

The Xcode project uses synchronized filesystem groups, so new app source files must
be added under `leanring-buddy/` and tests under their matching test directory.
