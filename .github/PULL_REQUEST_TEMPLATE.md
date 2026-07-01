## Summary

<!-- 1–3 bullets. What changed, and why. -->

## Paired PR check

- [ ] This change is **self-contained** to `Anglesite-app`.
- [ ] This change **needs a paired PR** in [`Anglesite/anglesite`](https://github.com/Anglesite/anglesite) (plugin / MCP server / template / hooks). Link it here: <!-- e.g. Anglesite/anglesite#123 -->

> Cross-cutting work (extending MCP messages, changing the plugin's hook contract, adjusting the site template the app scaffolds, etc.) lands as paired PRs. The plugin PR ships first in a tagged release; the app PR consumes it and bumps `Resources/plugin/`'s source-of-truth pointer. See `CLAUDE.md` ▸ "Two-repo coordination".

## Test plan

- [ ] `swift test --package-path .`
- [ ] `xcodebuild -project Anglesite.xcodeproj -scheme Anglesite -configuration Debug build`
- [ ] Manual smoke (if UI-touching): <!-- describe -->
