# Markdown Stickies

macOS sticky notes for plain `.md` files, plus a native iOS companion (same repo).

## Targets

| Target | Platform | Role |
|--------|----------|------|
| **MarkdownStickies** | macOS 14+ | Desktop stickies + overview |
| **MarkdownStickiesIOS** | iOS 17+ | Flat list / search / editor over a picked folder |
| **MarkdownStickiesCore** | SPM (macOS + iOS) | Shared note/filename/fuzzy/frontmatter/LAN sync |
| **MarkdownStickiesTests** | macOS | Unit tests for Core types |

Open `MarkdownStickies.xcodeproj` and pick the Mac or iOS scheme.

## LAN sync (v1)

1. **Mac:** Settings → enable **Sync** on a scan folder (becomes discoverable).
2. **iOS:** pick a notes folder; app advertises on the LAN.
3. Tap **Sync** (Mac overview toolbar or ⌘⇧S; iOS toolbar) while both apps are open on the same Wi‑Fi.
4. Notes match by frontmatter `id`; newer `mtime` wins. New notes land in the synced folder / iOS vault root.

No cloud or relay — Bonjour (`_mdstickies._tcp`) only.

## macOS install (Release)

Build Release, then copy `MarkdownStickies.app` to `/Applications/MarkdownStickies.app`.
