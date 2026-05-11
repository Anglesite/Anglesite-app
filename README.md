# Anglesite (Mac app)

A native macOS app that wraps the [Anglesite Claude plugin](https://github.com/Anglesite/anglesite) and gives non-technical site owners a click-to-edit experience for their website.

The app does not replace the plugin — it embeds it. Scaffolding, edits, deploys, and skills all flow through the same skills, hooks, and MCP server that Claude Code uses today; this app is a custom **host** for that machinery with native UI on top.

## Status

**Pre-release.** Phase 0 (repo + Xcode bootstrap) in progress. See [`docs/build-plan.md`](docs/build-plan.md).

## Documentation

- [Build plan](docs/build-plan.md) — phased implementation roadmap
- [High-level design](../anglesite/docs/dev/mac-app-design.md) — companion design doc in the plugin repo

## Requirements

- macOS 14+
- Xcode 16+
- A bundled Node.js runtime is shipped with the app — users do not need Node installed.

## Building

```sh
# Clone alongside the plugin repo
git clone https://github.com/Anglesite/Anglesite-app.git
cd Anglesite-app

# Open in Xcode
xed .
```

## Relationship to the plugin repo

This repo expects to live next to `Anglesite/anglesite` on disk (both checked out under the same parent directory). At build time the Xcode project copies the plugin into `Resources/plugin/`. For local plugin development, point **Settings → Advanced → Plugin path** at your working copy of the plugin.

## License

ISC. See [LICENSE](LICENSE).
