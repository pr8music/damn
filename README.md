# Clicky

Clicky is a macOS voice and screen assistant.

## Repository layout

- `leanring-buddy/` — macOS app source and bundled resources
- `leanring-buddyTests/` — unit tests
- `leanring-buddyUITests/` — UI tests
- `src/` — Cloudflare Worker proxy
- `scripts/` — release and packaging scripts
- `assets/` — screenshots, demo media, and release artwork

## Development

Open `leanring-buddy.xcodeproj` in Xcode to build the macOS app. The worker can be run locally with:

```bash
npm install
npm run dev
```

Deploy it with `npm run deploy` after configuring the required Cloudflare secrets.

## Releases

The release script archives, signs, notarizes, packages, and publishes the app:

```bash
./scripts/release.sh
```

It requires Xcode, `create-dmg`, an authenticated `gh`, Apple notarization credentials, and Sparkle's signing tools.
