# Markdown Stickies — Sync & Merge Rewrite Spec

Status: revision 3 · 2026-10-11. Revision 2 included the independent review (`docs/rewrite-spec-review.md`). Revision 3 splits the work into **Core v1** and **later cases** (§0, "Scope"). The change log is in §11.

This spec covers every change agreed so far:

- the new sync
- the new merge
- what gets removed
- what gets added
- side effects
- smaller changes in the macOS and iOS apps

It is written to stand on its own. A reviewer or implementer should not need any earlier conversation.

---

## 0. Context

Markdown Stickies is a note app for macOS and iOS.

- **On the Mac,** notes are plain `.md` files that live **inside the user's real project folders**, next to the project they belong to. The app gathers them in one place: a control window to find notes, plus floating sticky windows.
- **On iOS,** there is a companion app that works on a user-picked folder of plain `.md` files.

Sync runs **only over the local network (LAN)**. There is no cloud and no server.

### Why the rewrite

A review of the current sync found that it can delete or overwrite user data. The main cases:

- **Deletion during renames:** a two-phase rename deletes whatever file sits at the destination.
- **A stamp that silently wins:** a `conflict_resolved` frontmatter stamp makes one side win forever and drops newer edits.
- **Hard deletes after a merge:** the app permanently deletes (`removeItem`) the sibling copy, plus any note whose content equals the peer's body.
- **Merges overwrite later typing:** a merge writes an old snapshot over edits made after the sync.
- **Image collisions:** images are keyed by file name only and swapped in both directions.
- **Sync hangs:** some network receives have no timeout, so a sync can hang forever.
- **Writes into project files:** sync writes an `id:` into every `.md` file under a synced root, including README files in git repositories, and ignores EXCLUDE rules while applying changes.
- **Stale iOS saves:** the iOS editor never reloads after a sync and saves its old buffer back.
- **Overwrite on a failed read:** opening a note whose file can't be read as UTF-8 overwrites it with an empty template (`StickyWindowManager.open`, catch branch).

The design also has no common ancestor (no base version), so it can't tell "edited on one side" apart from "edited on both". Sync and merge are tangled into one code path.

The sync and merge layer is therefore rewritten from scratch. The rest of the app stays: stickies, the native editor, the control window, scanning, scan.conf, the HTML→Markdown converter and the iOS UI.

### Decisions already made

- The app **stays native** (Swift, AppKit/SwiftUI, UIKit/SwiftUI). There is no cross-platform UI framework and no WebView. Moving the sync core to Rust is only discussed if Linux or Android support ever starts.
- **Plain `.md` files on both devices.** There is no database (SQLite or otherwise).
- **The Mac is the hub.** It plans every sync and is the only device that stores sync state.
- **Deletes sync**, as "move to trash" on the other device.
- **iOS copies the Mac's folder structure** (one folder per synced root, with subfolders). The flat iOS folder goes away.
- **Only notes carrying the app's frontmatter key sync.** A note gets the key when it is created or first opened in the app. The app never adds it automatically to files it hasn't opened.
- **The key is namespaced:** `stickies-id`. Old `id:` lines stay in the files as they are and mean nothing to the new sync.
- **Sticky color syncs** and is stored in frontmatter. Window position and size stay on each device.
- **Sync and merge are separate features.** Sync never merges text. Merging is a Mac-only editing feature used after sync.
- **No pairing or encryption for now.** The app is used locally and is low-risk. QR-code pairing with TLS is noted for later (§9.2).
- **One iOS device** is the supported setup. The sync state is still kept per device, so more devices could be added later without changing the format.
- **iOS starts with a fresh, empty vault folder "On My iPhone"**, chosen by the user. Old iOS notes are moved over by hand.
- **iOS shows sticky colors but can't change them.** The `stickies-*` keys are read-only in the iOS frontmatter view.
- **iOS can't add images** in this rewrite. Pasting images on iOS is later work (§9.2).

### Scope: Core v1 and later cases

The rewrite is delivered as **Core v1** first: a small, very solid core. Individual edge cases are added on top later.

**The fallback rule for everything not in Core v1:**

> A case that Core v1 doesn't handle yet is **skipped and reported**, never guessed. No step is planned for it, its base stays unchanged, and the sync summary names it ("Skipped 'Idea': …").

A missing case therefore costs a line in the summary, never data. Sections marked **Later** below describe the full behavior; until it's built, the v1 behavior in this table applies.

**In Core v1, from the start:**

- the invariants of §3.1:
  - no hard deletes
  - no overwrite without a copy
  - conditional steps
  - one serialized writer per device
  - "can't read" never means "deleted"
  - the base updated per note only on confirmed equal hashes
- the base on the Mac, with `base-text/`
- the same-hash shortcut and the "unknown" state (§3.2)
- the basic decision table (§3.3):
  - unchanged / modified / created / deleted
  - edit beats delete
  - a conflict copy when both sides changed
  - the Mac's path wins when both changed it
- conflict copies with a deterministic id, written on the Mac before the iOS original is overwritten (`dependsOn`, §3.4)
- the guards (§3.8):
  - an unknown vault means a first sync
  - a missing or unreadable folder aborts
  - the bulk-delete prompt
- path validation, including the scan.conf check for iOS paths (§3.7)
- the transport (§3.6): one file per message, chunking, keepalive, timeouts, cancel, one sync at a time
- editors (§3.10): sync skips notes with unsaved edits; clean editors reload, follow moves, and close on trash
- Mac app: `stickies-id` on first open, saved window state by id, read-only open (§2.2, §2.3, §6.3)
- iOS app: vault layout with root folders and the Inbox, read-only `stickies-*` lines, `.stickies-trash/` (§2.5, §6.6)
- images: changed on one side, Mac wins when both changed, unreferenced copies trashed on iOS (§3.5)
- MergeView as a **two-way** view (§4)
- removing the old sync code and the WebView (§5)

**Later cases (v1 behavior in the meantime):**

| Case | Section | Core v1 behavior |
|---|---|---|
| Duplicate ids (Finder copy, Files → Duplicate) | §2.3 | Every file sharing the id is skipped on both devices. Summary: "Duplicate id: 'A.md', 'A 2.md'". No automatic new id. |
| A note left the sync set and was edited on iOS | §3.3 | Skipped while the iOS edit exists. Summary: "'Idea' was edited on <device> but is no longer synced on the Mac". A left note that iOS didn't edit is trashed on iOS as specified. |
| Field merge (text and color changed on different devices) | §3.3 | Treated as text changed on both sides, which gives a conflict copy. Rare, because iOS can't change colors. |
| A move or create whose target is taken (including swaps A↔B) | §3.3 | Skipped. Summary: "Couldn't move 'Idea': 'Plan.md' already exists". No suffixes, no two-phase moves. |
| Capitalization-only rename coming from iOS, applied on the Mac | §3.3 | Skipped and reported. The other direction (Mac → iOS) is a plain move and is in v1. |
| Generation counter for restored vault copies | §2.7 | Not built. A restored old copy can overwrite newer Mac text, but the overwritten file is kept in `Backups/` (rule 3). |
| Images added on iOS through Files | §3.5 | Skipped. Summary: "Images added on <device> aren't synced yet". |
| Three-way merge | §4.2, §6.2 | MergeView shows two ways. `conflict-base/` snapshots are already stored, so the three-way view can come later without a format change. |

---

## 1. Concepts and terms

| Term | Meaning |
|---|---|
| **Root** | A folder added in the Mac app (scan.conf INCLUDE). |
| **Synced root** | A root with "Sync" turned on (`syncedScanRootPaths`). |
| **Candidate** | A `.md` file under a root that scan.conf allows: the INCLUDE/EXCLUDE rules plus the built-in skipped folders (`node_modules`, `.git`, `build`, `vendor`, …). |
| **Note** | A candidate shown in the app. That is any candidate, with or without frontmatter (unchanged from today). |
| **Tracked note** | A note that has a `stickies-id` in its frontmatter. |
| **Sync set** | Tracked notes under synced roots, plus the images they reference (§2.4). |
| **Peer** | The iOS device the Mac syncs with (iPhone or iPad), identified by its device id. |
| **Vault** | The folder the user picked on iOS ("On My iPhone"). |
| **Root folder** | A folder in the vault that stands for one synced Mac root (§2.5). |
| **Inbox** | The top level of the vault. New iOS notes are created here and placed into a root folder at the next sync (§2.5). |
| **Base** | Per peer and per note: the state both devices were last *confirmed* to have. It's stored on the Mac only. |
| **Conflict copy** | A new note that sync creates when both sides changed the same text. |

User-facing strings never say "peer". They use the device's name.

---

## 2. Data model

### 2.1 Frontmatter keys (namespaced)

```yaml
---
stickies-id: 3F2A9C1E-7B4D-4E0A-9C55-1D2E3F4A5B6C
stickies-color: blue                                   # written for every opened note, yellow included
stickies-conflict-of: 9A8B7C6D-...                     # only on conflict copies
created_on: MacBook Pro                                # existing key, kept unchanged
---
```

**What counts as a frontmatter block:**

- **Line 1** (after an optional UTF-8 BOM) is exactly `---`.
- The block ends at the next line that is exactly `---`.
- The first non-empty line inside looks like `key: value`.

Anything else, such as a note starting with blank lines or with a horizontal rule, has **no** frontmatter block. Writing a key then creates a new block at the very top.

**Writing rules (all code paths):**

1. **Add keys to an existing block, never in front of it.**
   - New keys are added at the end of the block.
   - Other tools' keys (Obsidian, Jekyll, …) and their order stay unchanged.
   - There is no preferred key order and no forced `id:` key.
2. **Keep the file's line endings** (LF or CRLF) and any BOM.
3. **Write only when a value really changes.** Opening a note that already has `stickies-id` writes nothing.
4. **Never touch old keys.** The app doesn't modify or remove `id:`, `conflict_resolved:`, `conflict_sibling:` or `folder:` in existing files. The new code ignores them.
5. **Write safely.** Every write goes to a temp file in the same directory, which is then moved into place in one step.
6. **Color values:** a preset name (`yellow | blue | green | pink | purple | gray`, matching `StickyColor`'s raw values) or a custom color as `#rrggbb` (lowercase hex). An unknown value is shown as the default and preserved, not rewritten.

### 2.2 When a note gets `stickies-id` ("touched")

| Action | Writes `stickies-id`? |
|---|---|
| Creating a note in the app (Mac or iOS) | yes, as part of the initial document |
| Opening a note as a sticky (Mac) or in the editor (iOS) | yes, once, if missing |
| Hover preview in the control window | **no**, never writes |
| Scanning, search, sync | **no**, never (the only exception is the duplicate fix-up, §2.3) |
| HTML→Markdown "Apply" | only if the note is open, which means it already has one |

On the **first open**, the same write also adds `stickies-color` if it is missing: the color the Mac kept in its local window state before this change, otherwise yellow. Yellow is written explicitly. After that the frontmatter is the **only** place a color is stored; the Mac's `note-state.json` no longer holds colors (decided 2026-10-11).

**If the file can't be read or written** (not valid UTF-8, read-only, no permission), the note opens **read-only** with a notice. Nothing is written, so the note stays untracked. This replaces today's catch branch, which overwrites the file with a template.

There is no per-note "sync" toggle and, for now, no "remove frontmatter" action. Tracked notes are allowed to pile up over time.

### 2.3 Identity

- **Sync identity** is `stickies-id`. Paths are a property of the note, so renames and moves are tracked exactly.
- **Saved per-note state on the Mac** is keyed by `stickies-id`. It moves from a path key to an id key on the first open (§6.3):
  - window frame, float-on-top, text size, column count
  - last-opened time, removed-from-recents
  - set layouts (`setOpenPaths`)
- **Runtime window maps** in `StickyWindowManager` (`controllers`, `openPaths`, `parkedBySet`) **stay keyed by path**. Two files can briefly share an id (a Finder copy before the next fix-up), and a path-keyed runtime map can't confuse them. A rename updates the path key and the window title.
- **Untracked notes** (never opened) have no saved window state. The control window list keeps using the path as its SwiftUI identity.
- **Duplicate ids** happen when a file is copied (Finder copy on the Mac, Files → Duplicate on iOS). **Later** (v1: skipped and reported, see Scope):
  - **On the Mac,** the sync-set build detects them before the manifest is built.
  - **On iOS,** the manifest lists every file, including duplicates, and the Mac decides (§3.6 step 4).
  - **Which file keeps the id:** the one whose path equals the base path. Without a base, the one whose path sorts first (NFC, byte order).
  - **The others get a new `stickies-id`.** That's a `reassignId` step on iOS, and a direct write on the Mac. This is the only time anything writes an id into a note that wasn't opened, and it only affects files that already carry the key.
  - A file with unsaved edits in an open editor is fixed at a later sync, never while dirty.
  - The sync summary reports every fix-up.

### 2.4 Sync set

**Notes:** tracked notes under a synced root, after scan.conf is applied, excluding:

- hidden paths (any component starting with `.`)
- the legacy trash folder: a folder named exactly `Trash` **directly under a root**, nowhere else

**Overlapping roots:** if roots overlap (`~/Desktop` and `~/Desktop/notes`), a note belongs to the **deepest** root.

**Images:** only images referenced by notes in the set, through `![…](path)` or `<img src="path">`.

- References can have a link title (`![a](img.png "title")`), angle brackets, or percent-encoding (`%20`). They are resolved relative to the note.
- An image counts only if:
  - its path stays **inside the note's synced root** after resolving `..` and symlinks
  - it is an image type: `png jpg jpeg gif webp heic tif tiff bmp`
  - it is at most 20 MB
  - it is not a remote URL (`http:`, `https:`, `data:`)
- There is **no fallback by file name.** A reference that doesn't resolve to a file is broken and isn't synced.
- All other files in a project, such as unreferenced PNGs, are never read.
- An image referenced by several notes is one entry. Images are identified by **root + relative path** (full path, not file name).
- **The image set is computed after the note decisions**, from the note versions both sides will have once the plan is applied, not from the Mac's notes alone (§3.5).

**Only the Mac evaluates scan.conf.** iOS never reads scan.conf. It receives the sync set as the Mac defines it, and the Mac checks every iOS path against scan.conf (§3.7).

### 2.5 iOS vault layout

```
<Vault>/                           # chosen by the user, "On My iPhone"
  .stickies-vault                  # JSON: vaultId, generation, macDeviceId, roots {rootId → folderName}
  .stickies-trash/<date>/<root>/…  # trash, kept 30 days
  New idea.md                      # Inbox: new iOS note, placed at the next sync
  ProjectA/                        # one root folder per synced Mac root
    docs/idea.md
    docs/idea-img-20261011-101500.png
  Notes/
  Notes (2)/                       # second Mac root that is also named "Notes"
```

**Root folders:**

- Each synced root has a stable `rootId`. It's a UUID stored in the Mac's config next to `syncedScanRootPaths`, plus a copy in the sync state (`roots.json`, §2.6), so a root that is later removed can still be resolved.
- Each root has a **folder name on iOS**: the root folder's name, with ` (2)`, ` (3)` added on collisions. The Mac assigns the name once. **A name, once given, is never reassigned to another root,** even after that root is removed.
- The mapping `rootId → folderName` is written into `.stickies-vault` at every commit. iOS uses only this file to find root folders.
- **A root folder missing on iOS** (renamed, moved or deleted in Files) **aborts the sync,** naming the folder (§3.8). It never turns into "all notes deleted".

**Inbox (top level of the vault):**

- **The iOS app creates every new note at the top level of the vault,** before and after the first sync. The user doesn't pick a folder.
- At the next sync, a tracked note in the Inbox is created on the Mac in the "Default for New Notes" root (or the first synced root). The suffix rule applies (§3.3). The Mac then sends a move step that puts the iOS file into the matching root folder.
- If the Mac has no synced root, Inbox notes stay where they are. The summary says "Not synced: no synced folder on the Mac".
- Untracked `.md` files anywhere in the vault (dropped in through Files, no `stickies-id`) are ignored until they're opened in the app. The iOS list marks them "Not synced".
- Files in unknown folders (not a root folder, not the Inbox) are local to iOS and marked "Not synced".

**Moving notes:**

- **On the Mac** (Finder), within or between synced roots: a path change, applied on iOS at the next sync (§3.3). Out of all synced roots: the note leaves the sync set (§3.3).
- **On iOS** (Files), within or between root folders: a path change, applied on the Mac if the path is allowed there (§3.7).

### 2.6 Sync state on the Mac

The state lives in Application Support, never in project folders:

```
SyncState/<peerDeviceId>/<vaultId>/
  base.json          # generation, previousGeneration,
                     # notes: [stickies-id → { rootId, path, fileHash, restHash, color }]
  images.json        # [rootId/path → { hash }]
  roots.json         # [rootId → { macPath, iosFolderName }], including removed roots
  base-text/<stickies-id>.md        # file content at the base, for every note in base.json
  conflict-base/<conflict-copy-id>.md  # base snapshot for an unresolved conflict copy
Backups/<yyyy-mm-dd>/<root name>/<relative path>   # Mac files overwritten by sync or merge, kept 30 days
```

- **`fileHash`:** SHA-256 of the raw file bytes.
- **`restHash`:** SHA-256 of the raw bytes after removing exactly one line: the line inside the frontmatter block whose key is exactly `stickies-color` (case-sensitive), including its line terminator. If there is no such line, `restHash == fileHash`.
- **`base-text/`** is written at commit (§3.6 step 9) for every note whose base changed. When the hashes match, the Mac's file *is* the base, so it can simply be copied. Notes are small. This makes three-way merges possible (§4).
- **`Backups/`:** before the Mac overwrites the content of an existing file during sync, the old file is copied here. That covers a write from iOS, a field merge, and an image from iOS. Saving a merge does the same. Backups older than 30 days are removed.
- **iOS stores no base.** It only keeps `.stickies-vault` and its trash.

### 2.7 Device and vault identity (no pairing for now)

- Each app creates a random `deviceId` once and keeps it in UserDefaults. The device name is shown in the UI.
- The Mac keeps sync state per `deviceId` + `vaultId` (§2.6).
- **Generation counter** (**Later**; v1: not built, `Backups/` covers it, see Scope). At each commit, the Mac increments `generation` and stores it in `base.json`, keeping the previous value as `previousGeneration`. It sends the new value to iOS, which stores it in `.stickies-vault`.
  - At the next sync, iOS's value must equal the stored `generation` or `previousGeneration`. `previousGeneration` covers the case where iOS never received the last update.
  - Anything else means the vault is a stale copy (restored, duplicated, an old backup). The session then runs as a **first sync** (§3.8): no deletes, and differences become conflict copies, never overwrites.
- A device or vault the Mac hasn't seen before is always synced as a first sync.
- If the Mac finds more than one iOS device, it asks which one to sync with. One device is the expected setup.
- There is no authentication or encryption. This is accepted for local, low-risk use. See §9.2 for the planned upgrade.

---

## 3. The sync

### 3.1 Rules that always hold

1. **The Mac plans.** Whichever device starts the sync, the Mac computes the plan and the iOS device carries it out.
2. **Nothing is ever hard-deleted.**
   - A delete means: macOS Trash (`FileManager.trashItem`) on the Mac, `.stickies-trash/` on iOS.
   - If moving to the Trash fails, that step is skipped and reported. Sync never falls back to `removeItem`.
3. **Nothing is overwritten without a copy.**
   - On iOS, the previous file goes to `.stickies-trash/` before an overwrite.
   - On the Mac, the previous file goes to `Backups/` (§2.6).
4. **Every step is conditional.** Every write, move, trash and `reassignId` names the hash it expects to find (or "must not exist"). If the file differs, the step is skipped and gets picked up at the next sync.
5. **Sync never touches a note with unsaved edits in an open editor.** This is checked by the writer **when each step runs**, for writes, moves, trash and `reassignId`. The step is skipped and picked up at the next sync.
6. **Sync only touches files in the sync set,** plus conflict copies it creates. Every path from the other device is validated (§3.7).
7. **The base is updated per note,** and only where both devices are confirmed to have identical content. A base entry is removed only when both sides are confirmed to no longer have the note.
8. **No modification times are used anywhere** for decisions. Only hashes are compared. The app also stops faking modification times (`writePreservingModifiedDate`, `touchForSync`).
9. **"Can't read" never means "deleted".** A note is never classified as deleted while a file still exists at its base path, whether that file is readable or not (§3.2).
10. **No sync output goes into user folders.** There are no `debug-*.md` logs. Logging uses `os_log`.

### 3.2 Change detection

For each `stickies-id` that is in the base, in the Mac's sync set, or in the iOS manifest, each side gets one state:

| State | Condition |
|---|---|
| unchanged | present, `fileHash == base.fileHash` |
| modified | present, `fileHash != base.fileHash` |
| created | present, no base entry |
| **unknown** | not present by id, but the base path holds a file that is unreadable, a cloud placeholder, or has no `stickies-id` |
| **left** (Mac only) | not in the sync set, but the base path holds a readable file with that id, or with no id. The note is still on disk but no longer synced (excluded, Sync turned off, root removed, file moved out of the synced roots, or key removed). |
| deleted | base entry exists, and nothing at the base path |

**Probing the base path:**

- **On the Mac,** the planner checks the base path directly, using `roots.json` for removed roots.
- **On iOS,** the manifest lists files under root folders that couldn't be read, are `.icloud` placeholders, or have no `stickies-id`, by path (`unknown` list). The planner matches base paths against that list.

**Two shortcuts run before the decision table:**

1. **Same hash:** if both sides are present with the same `fileHash`, the planner records the base and does nothing else. The path is recorded only if both paths are equal; otherwise the path rules in §3.3 apply. This makes interrupted syncs safe to run again.
2. **Unknown on either side:** the note is skipped entirely this sync. No steps are planned, the base is unchanged, and the summary lists it ("Couldn't read 'Idea' on <device>").

### 3.3 Decision table (notes)

Rows are the Mac's state, columns the iOS device's state.

| Mac \ iOS | unchanged | modified | created | deleted | absent (no base) |
|---|---|---|---|---|---|
| **unchanged** | nothing | iOS → Mac | — | trash on Mac | — |
| **modified** | Mac → iOS | **field merge** (below) | — | **edit wins:** restore on iOS from the Mac | — |
| **created** | — | — | same hash: record base; different: conflict copy | — | Mac → iOS |
| **deleted** | trash on iOS | **edit wins:** restore on the Mac from iOS | — | forget base (after confirmation, rule 7) | — |
| **left** | trash on iOS | conflict copy next to the Mac file (§3.4), then trash on iOS | — | forget base | — |
| **absent (no base)** | — | — | iOS → Mac | — | — |

**Field merge (both modified)** (**Later**; v1: a conflict copy). Compare `restHash` and `color` separately against the base. A field counts as changed on one side only if the other side left it at the base value, **or changed it to the same value**.

- If each field changed on at most one side, combine them automatically: take the changed text and the changed color into one file and write it to both devices.
- If `restHash` changed on both sides, and differently, create a **conflict copy** (§3.4).
- If the color changed on both sides, and differently, the **Mac's color wins**, because the information lost is trivial. This is rare, since iOS can't change the color (§6.6).

**"Left the set"** notes are not deleted notes. If iOS didn't edit the note, its copy just goes to `.stickies-trash/`. If iOS edited it (**Later**; v1: skipped and reported), the edit is kept as a conflict copy next to the Mac file. That copy may be outside the sync set, and then it stays on the Mac only. **The Mac file is never overwritten.**

**Path changes** are decided separately from content. Compare each side's path (NFC, exact) with `base.path`:

| Path changed on | Result |
|---|---|
| neither | keep |
| one side | apply that path on the other side, if it's allowed there (§3.7); otherwise skip with a reason |
| both, to the same path | record it |
| both, differently | the Mac's path wins |

- **Collisions** (**Later**; v1: skipped and reported): a move or create never overwrites an existing file. If the target exists (with another id, or untracked), add ` (2)`, ` (3)`, … to the file name. The next sync then sees the suffixed path as a path change on the Mac and moves the iOS copy to match.
- **Swaps and chains** (**Later**; v1: skipped as a collision): if a target is occupied by another note that also moves in the same plan (A↔B), the moves run in two phases through temp names.
- **Temp names:** temp names are visible `.md` files in the same folder, named `<stem>.stickies-move-<8 hex>.md`. They keep the `stickies-id`, so after a crash the next sync just sees a path change.
- **Capitalization-only renames** count as path changes. Mac → iOS is in v1. iOS → Mac is **Later** (v1: skipped and reported). On the Mac (case-insensitive file system) they go through a temp name. On iOS (case-sensitive) they are a plain move.

**Edit vs. delete** keeps the edit, because losing an edit is worse than a note coming back. The sync summary names it: "Kept 'Idea': edited on the Mac after it was deleted on <device>."

**Turning Sync off for a root** shows a confirmation: "The next sync removes N notes of '<root>' from <device>. They stay on this Mac. Unsynced edits on <device> are kept as conflict copies."

### 3.4 Conflict copies

When the text can't be combined, or a "left" note was edited on iOS:

1. **The iOS version becomes a new note** next to the original's Mac path: `<stem> (conflict <device name> <yyyy-mm-dd>).md`, with a suffix if that name exists. It gets:
   - `stickies-id` = **UUIDv5(namespace, originalId + iOS fileHash)**. This is deterministic: the same conflict always gets the same id.
   - `stickies-conflict-of: <original id>`
   - the iOS version's `stickies-color`

   If a conflict copy with that id already exists on the Mac, from an earlier, interrupted sync, it is reused. A second copy is never created. Sync may write frontmatter into this file because sync created it.
2. **The Mac writes the copy first (step 6).** Only if that succeeds does the plan include overwriting the iOS original with the Mac's version (step 7, `dependsOn` the copy). The iOS original's previous content goes to `.stickies-trash/` first (rule 3).
3. **The conflict copy is a normal tracked note.** It's written to iOS too (into its root folder, or nowhere if it's outside the sync set) and gets a base.
4. **The Mac saves the base text** of the original, `base-text/<originalId>.md` as it was before this sync, to `conflict-base/<copyId>.md` for the three-way merge (§4).

The same conflict never comes back by itself. If both sides edit again, the next sync is a new conflict.

### 3.5 Decision table (images)

Images are keyed by `rootId/path` and use the same base logic (`images.json`). iOS can't add or edit images in the app, so iOS-side changes only come from other apps through Files. The set of referenced images is computed **after** the note decisions (§2.4).

| Mac \ iOS | unchanged | modified | deleted | absent (no base) |
|---|---|---|---|---|
| **unchanged** | nothing | iOS → Mac (Mac file to `Backups/` first) | still referenced: send to iOS again; otherwise forget base | — |
| **modified** | Mac → iOS | **Mac wins:** Mac → iOS, previous iOS file to `.stickies-trash/` | still referenced: send to iOS again | — |
| **deleted** (gone from the Mac) | trash on iOS | trash on iOS (iOS file in `.stickies-trash/`) | forget base | — |
| **created** | — | — | — | Mac → iOS |
| **absent (no base)** | — | — | — | created on iOS: **Later** (v1: skipped, "Images added on <device> aren't synced yet"). Full rule: iOS → Mac, `must not exist`; if the path is taken on the Mac, skip with "Image not synced: '<name>' already exists on the Mac" |

Further rules:

- **Created on both sides:** the same hash means record the base. A different hash means the Mac wins, and the previous iOS file goes to `.stickies-trash/`.
- **Image no longer referenced** by any synced note (after the plan): the iOS copy goes to `.stickies-trash/`, and the base is removed after confirmation. The Mac file is **never** touched.
- **Never deleted on the Mac.** Sync never trashes or deletes an image on the Mac, because images are project files that something else might use.
- **Image moved on the Mac:** shows up as "deleted" at the old path and "created" at the new path. The notes' references decide which paths are in the set.
- **No conflict-named image files are ever created.** The Mac always wins, and the previous iOS version is recoverable from `.stickies-trash/` for 30 days.

### 3.6 Session protocol

**Transport:**

- Bonjour discovery: both apps advertise and browse, as today.
- Plain TCP (no TLS for now, §2.7).
- Messages are length-prefixed JSON frames, **at most 2 MB per frame.**
- File contents are sent **one file per message, in chunks of up to 1 MB** (base64), each chunk acknowledged implicitly by the next request. There's no single message that holds many files.
- **Keepalive:** whichever side is busy (hashing, waiting for the user's confirmation, applying) sends a `keepalive` frame every 5 seconds.
- One protocol version: `1`. There are no compatibility branches.

**Who starts:** the Mac's Sync button, or the iOS Sync button. In both cases the iOS device ends up as the *responder* and the Mac as the *planner*. After the hello, the roles are fixed by device type, not by who opened the connection.

```
1  hello        both → both   { protocol: 1, deviceId, deviceName, platform, vaultId?, generation? }
                               Mismatched protocol → abort: "Update Markdown Stickies on <device>."
                               Unknown vault or generation mismatch → this session is a first sync (§2.7).
2  prepare      Mac → iOS     { roots: [{rootId, folderName}], defaultRootId }
                 Both: save open editors (flush pending saves).
                 Both: check readable —
                       Mac: each synced root exists and can be read;
                       iOS: vault readable, every root folder from .stickies-vault exists.
                       Failure → abort and name the folder. Never treat "can't read" as "empty".
3  manifest     iOS → Mac     { vaultId, generation,
                                notes: [{id, rootId|inbox, path, fileHash, restHash, color, size}],   # duplicates allowed
                                unknown: [{rootId, path, reason}],
                                images: [{rootId, path, hash, size}] }
4  plan         (Mac, local)  Build the Mac sync set and manifest, load base, fix Mac duplicates (§2.3),
                               resolve iOS duplicates (→ reassignId steps), run the planner → Plan.
                               Bulk-delete guard (§3.8) → may wait for the user's confirmation (keepalive).
5  fetch        Mac → iOS     requests the needed iOS files one at a time
   file         iOS → Mac     one file per request, chunked
                               The Mac checks each received hash against the manifest; a mismatch → skip that item.
6  apply-mac    (Mac, local)  Apply the Mac-side steps through the writer (§3.9), in order:
                               conflict copies → writes → moves → trash. Record each result.
7  ops          Mac → iOS     Built from the plan AND the actual step 6 results: every iOS step whose
                               prerequisite failed on the Mac is dropped.
                               [{ opId, kind: write|move|trash|reassignId, rootId, path, newPath?,
                                  expectHash | expectAbsent, dependsOn?: [opId], content (chunked) }]
                               Order: reassignId → writes (conflict copies first) → moves → trash.
8  results      iOS → Mac     [{ opId, status: done|skipped, reason?, resultHash? }]
                               iOS applies each step through its writer; a step whose dependsOn was
                               skipped is skipped too.
9  commit       (Mac, local)  Per note and image:
                               - Mac hash == iOS hash (resultHash, or the step 3 hash if untouched)
                                 → base = that hash; path only if both paths are equal;
                                 copy the Mac file to base-text/.
                               - both sides confirmed gone → remove the base entry.
                               - otherwise → base unchanged.
                               generation += 1. Save base.json / images.json / roots.json atomically.
10 summary      Mac → iOS     { generation, roots, updated, created, trashed, conflictCopies,
                                kept[], skipped[], fixedDuplicates[] }
                               iOS writes .stickies-vault (generation, roots). Both show the same summary.
                               Close the connection.
```

**Failures:**

- Every receive has a **15-second idle timeout.** It's re-armed on every frame, including keepalives, not checked only between chunks.
- There's one **Cancel** button on each device. It closes the connection immediately.
- A **single lock** allows one sync at a time. It is released on every exit path (`defer`).
- **No automatic retries.** If anything fails before step 9, the base is unchanged, and the next sync recomputes everything.
  - Steps already applied are detected by the same-hash shortcut (§3.2).
  - Conflict copies already written are reused through their deterministic id (§3.4).
  - If step 10 doesn't reach iOS, its generation is one behind, which `previousGeneration` accepts (§2.7).
- On iOS, the session asks for **extra background time** (`beginBackgroundTask`) so step 8 can finish if the user leaves the app. If iOS suspends it anyway, the Mac times out and nothing is committed.

### 3.7 Path validation (both sides, every incoming path)

**Reject a path that:**

- is absolute, empty, or contains `..`
- has a component starting with `.`, or is inside `.stickies-trash`
- resolves (after following symlinks on the receiving side) outside its root folder
- doesn't end in `.md`, for a note

**Additionally, on the Mac, for paths coming from iOS** (creates and moves). Skip the step with the reason "Folder is excluded on the Mac" if the path:

- isn't allowed by scan.conf
- lies inside a built-in skipped folder
- lies inside a deeper root, which would make it belong to another root

The iOS file is left untouched.

**Normalization and comparison:**

- **Every path is normalized** to Unicode NFC before comparing, sending or storing it.
- **Identity comparisons are exact,** after NFC.
- **Collision checks ignore case on both devices.** The Mac's file system usually ignores case and iOS's is case-sensitive, so `Idea.md` and `idea.md` must never both be created through sync.

**Directories:** sync may create missing directories inside a root folder. It never deletes directories.

### 3.8 Safety guards

- **Vault identity and generation** (§2.7). An unknown vault, or a stale generation, makes the session a **first sync**: no "deleted" states exist, nothing is trashed, and differing content becomes conflict copies.
- **Bulk-delete guard.** If a plan would move more than 10 notes to the trash, on either side, the Mac waits and asks: "This sync would move N notes to the Trash on <device> / this Mac. Continue?" The dialog lists them. Cancel aborts with no changes. The threshold can be generous because these are trash moves, not real deletions: macOS Trash on the Mac, `.stickies-trash/` (30 days) on iOS.
- **Missing or unreadable folders abort the sync and name the folder.** That covers a missing drive or revoked permission on the Mac, and a renamed or deleted root folder on iOS. They never turn into "all deleted".
- **Unknown notes are skipped** (§3.2), never deleted.

### 3.9 One writer per device

All note and image writes on a device go through **one serialized writer** (an actor):

- editor saves
- HTML-convert "Apply"
- color changes
- renames
- merge saves
- duplicate fix-ups
- sync steps

Each write states its precondition (expected hash, or must not exist) and fails cleanly if it isn't met. Image writers included: `NoteImageStore` writes with "must not exist" and adds a numeric suffix on collision.

The writer also:

- knows which notes are open with unsaved edits, through a registry the editors report to. It uses this for rule 5.
- makes the copies required by rule 3 (`Backups/` on the Mac, `.stickies-trash/` on iOS)
- keeps the "recent own writes" list for the folder watcher. That replaces `NoteStore.recentLocalWrites`, keyed by path.

### 3.10 Open editors (both apps)

- Both apps autosave shortly after typing stops, and step 2 of every session saves all editors. So a dirty editor during a sync is rare. The rules below are the safety net.
- An editor remembers the `fileHash` it loaded or last saved.
- **When sync changes, moves or trashes the note of a clean editor:**
  - **Changed:** the editor reloads, keeping the cursor position where possible.
  - **Moved:** the editor follows the new path.
  - **Trashed:** the editor closes with a notice.
- **When the note's editor is dirty,** sync doesn't touch the file at all (rule 5).
- **On save, if the file on disk no longer matches** what the editor loaded (another app changed it), or the file is gone without a move notice, the editor saves its buffer as a conflict copy (`<stem> (conflict <this device> <date>).md`, new `stickies-id`, `stickies-conflict-of`). It then reloads or closes, and shows a notice. **It never overwrites silently.**
- **iOS gains the reload behavior it lacks today.** `VaultStore` tells the open `NoteEditorView` about every sync step that touched its note.

### 3.11 First sync and migration from the old sync

- **The new protocol is incompatible with the old one.** Both apps must be updated together. An old peer fails at hello with a clear message.
- **On the Mac,** nothing changes for existing files until each one is opened. Old `id:` lines don't count. A note with only `id:` gets a `stickies-id` when it is next opened.
- **On iOS: a fresh, empty vault folder "On My iPhone".** The first sync fills it with the Mac's tracked notes in the new layout. The old flat folder stays untouched.
  - Notes that exist only in the old iOS folder are moved by hand (Files app) into the new vault's top level (the Inbox). Opening them in the app adds `stickies-id`, and the next sync places them on the Mac. There is no import helper.
- **Matching on a first sync** uses only `stickies-id`. If the same id exists on both sides with different content, the result is a conflict copy, never an overwrite.
- **Choosing the vault:** the iOS onboarding asks for a folder "On My iPhone". If the chosen folder is in iCloud Drive or another cloud provider, the app warns that evicted files will be skipped during syncs, and allows it anyway. Placeholders are handled as unknown (§3.2).

### 3.12 UI states (identical wording in both apps)

| State | Text |
|---|---|
| Idle | — |
| Connecting | "Connecting to <device>…" |
| Syncing | "Syncing with <device>…" plus a progress count |
| Waiting for confirmation (bulk guard) | the dialog from §3.8 |
| Done | "Synced with <device>" plus a summary line: "3 updated · 1 new · 2 moved to Trash · 1 conflict copy". Use "Already up to date" when nothing changed. Skipped items ("Couldn't read…", "Folder is excluded on the Mac", "Image not synced…") are listed below, expandable. |
| Failed | "Sync failed" plus a one-sentence reason and the next step, for example "Couldn't reach <device>. Make sure both apps are open on the same Wi-Fi." or "Folder 'ProjectA' is missing on <device>. Restore it in the Files app or sync again after removing it on the Mac." |
| Cancelled | "Sync cancelled. Nothing was changed." if before commit, otherwise "Sync cancelled." |

- **Conflicts are not a sync state.** They show up as conflict-copy notes (§4.1).
- "Sync Later", "Awaiting Merge", "Keep both files" and similar phrases no longer exist.
- The other device is always named by its device name. Before a device has been seen, the generic text is "iPhone or iPad".

---

## 4. The merge (Mac only, separate from sync)

### 4.1 Finding conflicts

- Any tracked note with `stickies-conflict-of` is a conflict copy. That frontmatter key is the only record; there is no separate conflict list.
- **Mac control window:** a badge on the original, plus a "Conflicts" filter. The conflict copy's row shows "Conflict copy of '<title>'" and a **Merge…** button.
- **iOS:** the conflict copy's row shows "Conflict copy — merge on the Mac". iOS has no merge UI. The user can still read, edit or delete both notes on iOS like any notes.

### 4.2 Merge view

- **Shows a three-way comparison** (**Later**; v1: two-way, original and conflict copy):
  - the original, the Mac's current file
  - the conflict copy's current file
  - the base, from `conflict-base/<copyId>.md`. If that file is missing (for example a conflict copy made by an editor, §3.10), it falls back to a two-way view.
- **Lines changed on only one side** are pre-selected automatically. Overlapping changes are marked for the user to choose.
- **Controls:** take this line or that line per hunk, take everything from one side, and an editable result pane.
- **The result is saved verbatim.** No marker lines are stripped automatically. If marker-like lines (`<<<<<<<`, `>>>>>>>`) remain, Save asks for confirmation.
- **Frontmatter:** the result keeps the original's frontmatter (`stickies-id`, color, other keys). The conflict copy's `stickies-conflict-of` and `stickies-id` are dropped with the copy.

### 4.3 Saving a merge

1. Write the result into the **original** through the writer, with the precondition "original still has the hash shown in the merge view". The previous content goes to `Backups/`.
   - If the precondition fails (you edited the original meanwhile), the merge view reloads that side. Nothing is lost.
   - If the original is open in a sticky with unsaved edits, the merge view asks the sticky to save first, then reloads.
2. Move the **conflict copy** to the macOS Trash and remove `conflict-base/<copyId>.md`.
3. **No sync is started automatically.** The next sync sees "original modified on Mac, copy deleted on Mac". It sends the merged text to the device and trashes its copy.

**Other ways to resolve:** deleting the conflict copy, or editing both notes by hand, is just as valid. `conflict-base/` files whose conflict copy no longer exists are cleaned up at the next sync.

### 4.4 What the merge never does

- delete anything except the one conflict copy it resolves, which goes to the Trash
- write frontmatter stamps
- start or abort a sync
- affect the other device directly

---

## 5. What gets removed or changed in existing code

### 5.1 MarkdownStickiesCore

| File / symbol | Action |
|---|---|
| `SyncCatalogBuilder.swift` (whole file): `catalog`, `localIndexForApply`, `pathIndex`, `writeBody`, `apply`, `applyRemoteCatalog`, `preserveConflict`, `findSiblingFile`, `finalizeRename`, `desiredURL`, `contentFingerprintsOnDisk`, `payload(fromFile:)` | delete |
| `SyncModels.swift`: `SyncNotePayload`, `SyncWireMessage` (protocol v5), `SyncApplyAck`, `SyncConflict`, `SyncExchangeResult`, `SyncMerge` (`decide`, `decideByConflictResolved`, `decideByMtime`, `decideTitleOnly`, `decisions`, `outboundIDs`, `ConflictRole`), `SyncFrameCodec` | delete (framing is rewritten in the transport) |
| `SyncFeedback.swift`: `SyncFeedback` (debug codes, ack-retry wording), `SyncExchangeRole`, `statusSummary`, `SyncDebugLog` | delete; replaced by `SyncStatus` (§6.1) |
| `SyncImageAssets.swift`: `SyncAssetOffer`, `SyncAssetBlob`, `offers`, `makeOffer`, `loadBlob`, `missingOffers`, `applyBlob` | delete |
| `SyncImageAssets.swift`: `resolveImageURL`, `resolveExistingImageURL`, `relativeImageFilenames`, `rawImageDestinations`, `findImageFile`, `sanitizedFilename` | **rewrite** as `ImageReferences.swift`. The kept helpers depend on `sanitizedFilename` and don't meet §2.4: no `<img src>`, no link titles, no `%20`, they reject `..`, and they fall back to a file of the same name. Both editors use them. |
| `LanSyncService.swift` (whole file, ~1,000 lines) | delete; replaced by `SyncTransport` + `SyncSession` |
| `NoteFrontmatter`: `idKey` and the `id`-based sync (`syncID`, `ensuringSyncID`, `settingSyncID`), `contentFingerprint`, `conflictResolvedKey` + `conflictResolvedAt`/`settingConflictResolved`/`clearingConflictResolved`, `conflictSiblingKey` + `isConflictSibling`/`markingConflictSibling`, `ensuringOpenMetadata`, `settingDisplayTitle`, `settingFolder`, `folder(in:)`, `ensuringCreatedOn`, `settingCreatedOn`, `isTrashFolder`, `trashDirectory`, `moveToTrash`, `relativeFolder` (both), `normalizeFolder`, `folderKey`, `titleKey`, `displayTitle(in:)` | delete |
| `NoteFrontmatter.initialDocument` | change: write `stickies-id` (and `created_on`) instead of `id`. Used by `NoteStore.createNote` (`NoteStore.swift:626`) and iOS note creation (`ContentView.swift:401`). |
| `NoteFrontmatter.upsert`, `preferredKeyOrder`, `insertionIndex`, `leadingFrontmatter` | change: no forced `id:`, no preferred order, block detection and line endings as in §2.1 |
| `NoteFrontmatter`: `splitDocument`, `joinDocument`, `createdOn(in:)`, `createdOnKey`, `matchingRoot` | keep (`splitDocument`/`joinDocument` use the new block detection) |
| `NoteFrontmatter.isTrashed(file:)`, `trashFolderName` | change: match only `<root>/Trash/` (legacy), not any folder named `Trash` at any depth |
| `TextDiff.conflictMarkedBody` | delete (dead code) |
| `TextMerge.twoWay` / `mergeDocuments` with the Levenshtein "similar line" heuristics | replace with a standard three-way merge (§6.2) |
| `Sources/SyncMergeHarness/` (executable target) and its entry in `Package.swift` | delete; replaced by scenario tests |
| Tests: `SyncCatalogApplyTests`, `SyncMergeScenarioTests`, the asset parts of `SyncImageAssetsTests`, `TextMergeTests` | delete or rewrite against the new modules (§8) |

### 5.2 macOS app

| File / symbol | Action |
|---|---|
| `NoteStore`: `pendingConflicts`, `openConflictNotes`, `acknowledgeConflict`, `mergeConflict` (including its direct `removeItem` of the sibling, `NoteStore.swift:309-315`), `normalizedMergeBody`, `removeConflictSiblingCopies`, `presentSyncResult`, `applyRemoteCatalog`, the `SyncDebugLog` calls, `configureSync` callbacks | delete; replaced by a thin binding to `SyncSession` |
| `NoteStore.rescan`: the `ensuringSyncID` write for open notes | delete (scanning never writes) |
| `NoteStore.syncInboundPaths` / `syncOutboundPaths`, and their use in `ControlWindowView.swift:214-215` | replace with sets of `stickies-id`, filled from the session summary |
| `ControlWindowView.swift:40` (binding to `pendingConflicts`) | replace with the conflicts filter (§4.1) |
| `Views/SyncConflictSheet.swift` | delete; replaced by `MergeView` (§6.4) |
| `Views/SyncBannerOverlay.swift`: "Sync Later", merge-cancel, debug-code branches | simplify to the states in §3.12 |
| `StickyWindowManager.open`: `ensuringSyncID` plus `writePreservingModifiedDate`, and the catch branch that writes `initialDocument` over an unreadable file | replace (§2.2) |
| `StickyWindowManager.renameNote` (`StickyWindowManager.swift:266-300`): path-keyed maps, `touchForSync` | change: write through the writer, update the path keys and saved state, no mtime bump |
| `StickyWindowManager.touchForSync`, `writePreservingModifiedDate` | delete |
| `StickyWindowManager.forceReloadIfOpen` | delete (only the old merge used it) |
| `StickyWindowManager.deleteNote`: move to in-root `Trash/` with a `folder: Trash` stamp | replace with the macOS Trash |
| `NoteStateStore`: path-keyed `states` and `setOpenPaths` | change: key by `stickies-id`, with a migration on first open (§6.3) |
| WebView: `Services/MarkdownHTMLRenderer.swift`, `Services/MarkdownBlockParser.swift`, the `WKWebView` preview pane and `import WebKit` in `HTMLConvertWindowController` | delete (§6.5) |
| `NoteImageStore.saveImageFile` (`removeItem` at the destination), `saveImage` and `saveImageData` (`.atomic` overwrite) | change: write through the writer with "must not exist" and a numeric suffix on collision |

### 5.3 iOS app

| File / symbol | Action |
|---|---|
| `VaultStore`: `configureSync` callbacks, `applyRemoteCatalog`, `presentSyncResult`, `SyncDebugLog` calls, `ScanConfig.load()` uses, `dismissSyncBanner`'s merge-cancel path | delete; replaced by a thin binding to `SyncSession` (responder) |
| `VaultStore.syncInboundPaths`, `syncOutboundPaths`, `acknowledgeInbound` (`VaultStore.swift:26-28`, `:307`), and their use in `ContentView.swift:267` | replace with sets of `stickies-id` from the session summary |
| `VaultStore.moveNoteToTrash` (in-vault `Trash/` with a `folder` stamp, and a comment claiming it syncs) | replace with `.stickies-trash/` |
| `VaultStore.rescan`: `isTrashed` filter, scan of the whole vault | change: `VaultScanner` (root folders, Inbox, "Not synced" files) |
| `NoteEditorView.load`: `ensuringSyncID` with a faked modification time | replace (§2.2) |
| `NoteEditorView.saveIfNeeded`: plain overwrite | replace with a conditional write through the writer (§3.10) |
| `NoteEditorView` "Show Frontmatter" mode: edits the whole document | change: `stickies-*` lines are shown read-only and preserved on save (§6.6) |
| `ContentView` note creation | change: new notes go to the vault's top level (Inbox) with `stickies-id` |
| `SyncBannerOverlay.swift`: "Awaiting Merge", "Sync Later" | simplify to §3.12 |

---

## 6. What gets added

### 6.1 MarkdownStickiesCore: new modules

No AppKit or UIKit in any of these, so they can be tested on their own (and ported later if ever needed).

| Module | Responsibility |
|---|---|
| `StickiesFrontmatter` | Block detection (§2.1). Read and write `stickies-id`, `stickies-color` and `stickies-conflict-of`. It adds keys into an existing block, keeps all other keys, the line endings and the BOM. |
| `NoteHashing` | `fileHash`, `restHash` (exact definition in §2.6) |
| `ImageReferences` | Parses and resolves image references (§2.4) |
| `SyncSetBuilder` (Mac) | Candidates under the synced roots, then tracked notes, then the duplicate fix-up. Applies scan.conf everywhere. Probes base paths for unknown and left notes (§3.2). |
| `VaultScanner` (iOS) | Lists tracked notes in the root folders and the Inbox, plus unknown files and images. Reads and creates `.stickies-vault`. Reports duplicates as they are. |
| `Manifest` | The value type both sides exchange |
| `SyncStateStore` (Mac) | `base.json` (with the generations), `images.json`, `roots.json`, `base-text/`, `conflict-base/`, `Backups/` with 30-day cleanup. Saved atomically. |
| `SyncPlanner` | **Pure function:** `plan(mac:, peer:, base:, imageRefs:) -> Plan`. Implements §3.2–3.5 and §3.8, including duplicate resolution, ordering and `dependsOn`. No file access. |
| `PathRules` | Validation, NFC normalization, collision checks that ignore case, conflict-copy, suffix and temp naming (§3.3, §3.7) |
| `NoteWriter` | An actor. Serialized, conditional writes, moves, trash moves and `reassignId`. Knows which editors have unsaved edits. Makes the copies of rule 3. Platform trash adapters: macOS Trash and `.stickies-trash/` (30 days). Keeps the list of the app's own recent writes for the folder watcher. |
| `SyncTransport` | Bonjour, TCP, framing (2 MB), chunking (1 MB), keepalive, 15-second idle timeouts, cancellation |
| `SyncSession` | Runs the steps in §3.6. Planner role on the Mac, responder role on iOS. |
| `SyncStatus` | The UI state enum and summary strings from §3.12, shared by both apps |
| `TextMerge3` | A standard three-way line merge (diff3), used only by `MergeView` |
| `NoteColor` | Moves from the Mac app into Core: a preset (`StickyColor` raw values) or `#rrggbb`. iOS can read and display it. The platform colors stay in each app. |

### 6.2 Three-way merge

`TextMerge3.merge(base:, mine:, theirs:)` returns hunks: unchanged, changed only in mine, changed only in theirs, changed in both (conflict). Lines changed on only one side merge automatically. Hunks changed on both sides go to the user. There's no similarity heuristic.

### 6.3 macOS app

- **Sync button:** syncs with the iOS device it finds. If several are found, it asks which one.
- **Confirmation dialogs:** the bulk-delete guard (§3.8) and "Turn Sync Off" (§3.3).
- **Conflicts in the control window:** a "Conflicts" filter and badges (§4.1).
- **Read-only open:** a read-only sticky mode for files that can't be read or written (§2.2).
- **Color syncs:** a color change (preset or custom) writes `stickies-color` through the writer.
- **Window state by id:** saved state moves from path keys to `stickies-id` on a note's first open as a tracked note. Notes not opened since keep their old path entry until they are.

### 6.4 MergeView (macOS)

This replaces `SyncConflictSheet`. It's opened from **Merge…** on a conflict copy. Its behavior is described in §4.2–4.3.

### 6.5 HTML→Markdown convert window (macOS)

- The preview pane shows the **converted Markdown** in a read-only `MarkdownSourceEditorView`, rendered exactly as a sticky renders it.
- It does not render HTML, and there is no WebKit anywhere in the app.
- `HTMLToMarkdown` (pure Swift, in Core) stays unchanged.

### 6.6 iOS app

- **Onboarding:** pick a folder "On My iPhone", with a warning for cloud locations (§3.11).
- **Sync button:** connects to the Mac it finds. The Mac runs the session (§3.6).
- **Vault layout:**
  - root folders as sections or folders in the list (§2.5)
  - new notes in the Inbox
  - files outside the root folders and the Inbox are marked "Not synced"
- **Sticky color** (preset or custom hex) shown in the list and as the editor background. **Display only.**
- **Show Frontmatter:** the `stickies-*` lines are shown but read-only and are preserved exactly on save. This keeps the color display-only, and it means removing the id on iOS can't make the Mac trash the note.
- **Conflict-copy rows** (§4.1).
- **Editor reload and conditional save** (§3.10).
- **Trash:** a `.stickies-trash/` view to restore notes, emptied after 30 days.

---

## 7. Side effects users will notice

1. **Opening a note writes it once,** to add `stickies-id` (and `stickies-color`). Git shows a diff, and other editors with the file open reload it. Later opens write nothing.
2. **Notes reach the iPhone only after they were opened** (or created) in the app. Notes that were never opened don't sync. This is intentional.
3. **Notes with an old `id:` line** get a second key, `stickies-id`, when opened. The old line stays until the user removes it by hand (the "show frontmatter" view on the Mac).
4. **A color change is now a file change.** It shows up in git and syncs.
5. **Window positions are kept across renames and Finder moves** inside the roots, once the note is tracked.
6. **Deleting a note on the Mac** moves it to the macOS Trash, not into a `Trash/` folder inside the project. Existing `<root>/Trash/` folders are left alone and stay hidden from the app.
7. **Subfolders named `Trash` deeper inside a project become visible.** Today they're hidden by mistake.
8. **Deletes now sync.** A note deleted on one device moves to the trash on the other at the next sync, unless the other device edited it.
9. **Git branch switches:** if a branch switch removes a note on the Mac while the iPhone edited it, the edit wins, and the note comes back as an untracked file on the current branch. Switching back can then make git refuse the checkout until that file is moved. Nothing is lost.
10. **The iOS folder layout changes** (§2.5, §3.11). A fresh vault folder "On My iPhone" is used. New iOS notes appear first at the top level and move into a folder at the next sync.
11. **Unreferenced images no longer sync.** Images sync only while a synced note references them, and sync never deletes images on the Mac.
12. **Overwritten Mac files are kept for 30 days** in the app's `Backups/` folder (Application Support), in addition to the Trash for deletions.
13. **Old app versions can't sync** with the new ones (protocol 1).
14. **No more `debug-*.md` files** are written into note folders. Existing ones can be deleted by hand. File names starting with `debug-` are no longer special.
15. **Sync no longer fakes modification times,** so file dates on both devices reflect real writes.
16. **One iOS device** is supported for now. The sync state is kept per device, so more could be added later.

---

## 8. Tests (part of the rewrite, not optional)

1. **Planner table tests:**
   - one test per cell of §3.3 and §3.5
   - field merge, including identical changes on both sides
   - path changes on both sides, a capitalization-only rename, swaps (A↔B), and collisions on create and move
   - edit vs. delete
   - the "left" and "unknown" states
   - the same-hash shortcut
   - path recording only when both paths are equal
2. **Guard tests:**
   - an unknown vault, a stale generation and `previousGeneration` behave as specified
   - an unreadable Mac root aborts
   - a missing iOS root folder aborts
   - the bulk-delete threshold (more than 10) triggers on either side
   - duplicate ids are repaired on both devices, with the tie-break by path, and never while dirty
   - an incoming path that escapes its root, or that the Mac excludes, is rejected or skipped
   - NFC/NFD and case-only collisions are handled
3. **Writer tests** on temp folders:
   - a precondition mismatch skips the step
   - a move or create never overwrites
   - rule 3 copies are made (`Backups/`, `.stickies-trash/`)
   - trash adapters work
   - frontmatter writes keep all other keys, their order, CRLF and the BOM
   - a note starting with a horizontal rule gets a new block, not a key in its text
4. **Session tests** over an in-memory transport, with fault injection:
   - cut the connection after each of steps 1–10, then run the next sync; it must converge with nothing lost and **no extra conflict copies**
   - a failing conflict-copy write on the Mac drops the dependent iOS overwrite
   - a silent peer times out
   - keepalives during the bulk-guard dialog keep the session alive
   - files over 1 MB are chunked
   - Cancel at every step
5. **Editor tests:**
   - sync skips a dirty note, for every step kind
   - a clean editor reloads, follows a move, and closes on trash
   - a dirty editor whose file changed or vanished writes a conflict copy
   - iOS frontmatter view keeps the `stickies-*` lines
6. **Scenario tests** (replacing `SyncMergeHarness`):
   - two roots with the same name, and removing one of them
   - the same file name in different folders
   - an iOS Inbox note before and after the first sync
   - an image added on iOS through Files
   - a conflict copy, then a merge, then a sync
   - turning Sync off for a root with unsynced iOS edits
   - an EXCLUDE rule added for a synced note
   - a stale vault copy restored on iOS
   - a renamed root folder on iOS
   - Files → Duplicate on iOS
   - an evicted iCloud file
   - deleting on iOS while the Mac is unchanged (the note must not come back)

---

## 9. Decisions and later work

### 9.1 Decided (2026-10-11)

| Question | Decision |
|---|---|
| Color on iOS | Display only; `stickies-*` keys read-only in the iOS frontmatter view (§6.6) |
| Pairing / encryption | Not now. Local, low-risk use (§2.7) |
| iOS trash retention | 30 days |
| Bulk-delete guard | More than 10 notes moved to trash (either side) asks first. It's a trash move, never a real deletion (§3.8) |
| Conflict-copy name | `<stem> (conflict <device> <yyyy-mm-dd>).md`, for notes only |
| Image conflicts | The Mac wins. The previous iOS version goes to `.stickies-trash/`. No conflict-named images (§3.5) |
| Importing old iOS notes | By hand: fresh vault folder, then move notes into the Inbox (§3.11) |
| New iOS notes before or after the first sync | Created at the vault's top level (Inbox) and placed into the default root at the next sync (§2.5) |
| Vault location | Chosen by the user, "On My iPhone"; warning for cloud locations (§3.11) |
| Several iOS devices | Not needed now. The per-device state keeps the option open (§2.7) |

### 9.2 Later (not part of this rewrite)

- **Pairing and encryption.** Pair once with a QR code carrying a random 32-byte key, stored in the Keychain on both sides. Every connection then uses TLS with that pre-shared key (Network.framework PSK), and unpaired devices are refused before any data is exchanged. This would only sync with QR-paired devices. It's a good idea once the app is used on untrusted networks.
- **Pasting and adding images on iOS.** When this comes, revisit §3.5: iOS-created images, naming, and collisions.
- **Choosing a folder for new iOS notes** instead of the Inbox.
- **Opt-in tracking.** An import dialog when adding a folder, a "not added yet" list, a "remove frontmatter" action, and a Finder context-menu action "Add to Markdown Stickies".
- **Several iOS devices** with a device picker and per-device summaries.

---

## 10. Order of work (Core v1)

Work happens on the branch `sync-rewrite`; `main` stays the current app. The old apps aren't used for syncing until the new sync is ready, so no stopgaps are needed in the old code.

Each step has its own tests and leaves the apps building.

1. **Core foundations:** `StickiesFrontmatter`, `NoteHashing`, `PathRules`, `NoteColor`.
2. **Core planner:** `Manifest`, `SyncPlanner` with the v1 decision table, fallbacks and guards, `ImageReferences`. Pure, in-memory tests.
3. **Core writer and state:** `NoteWriter` (conditional steps, Trash, `.stickies-trash/`, `Backups/`), `SyncStateStore`.
4. **Mac app basics:** `SyncSetBuilder`, `stickies-id` on first open, saved window state by id, read-only open, color in frontmatter. Testable in the Mac app without any sync.
5. **Core transport and session:** `SyncTransport`, `SyncSession`, tested over an in-memory connection with fault injection.
6. **iOS app:** `VaultScanner`, the Inbox, editor reload and conditional save, read-only `stickies-*` lines, then the first real sync with a fresh folder "On My iPhone", after a backup.
7. **Cleanup and merge:** remove the old sync code and the WebView (§5), the convert-window preview, MergeView (two-way), and the new UI wording.
8. **Later cases** from the Scope table, one at a time, each with its tests.

---

## 11. Change log

### Revision 2 (2026-10-11): after the independent review

References are to `docs/rewrite-spec-review.md`.

| Finding | Change |
|---|---|
| D1 stale vault overwrites Mac text | Generation counter with `previousGeneration` (§2.7); rule 3 "nothing overwritten without a copy" and the Mac `Backups/` (§2.6, §3.1) |
| D2 iOS root folder renamed or deleted | `rootId → folderName` stored in `.stickies-vault`, names never reused, a missing root folder aborts (§2.5, §3.8) |
| D3 leaving the set drops iOS edits | New "left" state; an edited iOS copy becomes a conflict copy next to the Mac file (§3.2, §3.3) |
| D4 duplicate ids on iOS | The manifest lists duplicates; the Mac resolves them with `reassignId` (§2.3, §3.6) |
| D5 evicted or unreadable files | New "unknown" state and rule 9; vault "On My iPhone" (§3.1, §3.2, §3.11) |
| D6 iOS overwrite without the conflict copy | Step 7 built from the step 6 results; `dependsOn` (§3.4, §3.6) |
| D7 repeated conflict copies | Deterministic conflict-copy id, reused (§3.4) |
| D8 skipped move undone later | The base path is recorded only when both paths are equal (§3.2, §3.6) |
| D9 iOS notes in folders the Mac excludes | The Mac checks iOS paths against scan.conf (§3.7) |
| D10 dirty check only for writes and only as a snapshot | Rule 5 checks at step time for all step kinds; `dirtyIds` removed (§3.1, §3.9, §3.10) |
| D11 duplicate ids in window maps | Runtime maps stay path-keyed; saved state is id-keyed (§2.3) |
| D12 image set computed too early | Computed from the post-plan note versions (§2.4, §3.5) |
| D13 crash during a case-only move | Visible `.md` temp names that keep the id (§3.3) |
| D14 frontmatter detection | Line-1 rule, BOM, line endings (§2.1) |
| D15 git branch switches | Side effect 9 (§7) |
| G1 base text unavailable | `base-text/` for every note; `conflict-base/` snapshots (§2.6, §3.4) |
| G2 timeout during the dialog | Keepalive every 5 seconds (§3.6) |
| G3 frame limit | One file per message, 1 MB chunks, 2 MB frames (§3.6) |
| G4 collision on create | The suffix rule applies to creates (§3.3) |
| G5 iOS is case-sensitive | Exact identity comparison; collision checks ignore case (§3.7) |
| G6 when a base entry is removed | Only after both sides are confirmed gone (§3.1 rule 7, §3.6) |
| G7 incomplete image rules | Full image table (§3.5) |
| G8 identical change on both sides | Counts as a change on one side (§3.3) |
| G9 iOS can edit the frontmatter | `stickies-*` lines read-only on iOS (§6.6) |
| G10 duplicate tie-break | Base path, then path order; never while dirty (§2.3) |
| G11 `restHash` not defined | Exact definition (§2.6) |
| G12 Inbox and swaps | Inbox (§2.5); two-phase moves (§3.3) |
| W1, W2 image helpers | Marked "rewrite" as `ImageReferences` (§5.1, §6.1) |
| W3 custom colors | `#rrggbb` allowed; `NoteColor` moves to Core (§2.1, §6.1) |
| W4 `initialDocument` and `upsert` write `id:` | Listed as changes (§5.1) |
| W5 second hard delete in `mergeConflict` | Added to §5.2 and the stopgaps (§10) |
| W6 other image writers | Through the writer with "must not exist" (§3.9, §5.2) |
| W7 iOS can't add images | Spec corrected; pasting on iOS listed as later work (§0, §9.2) |
| W8 missing symbols; `isTrashed` at any depth | Added to §5; `isTrashed` limited to `<root>/Trash/` (§5.1, §7) |
| O1 `conflicts.json` | Removed; `stickies-conflict-of` plus `conflict-base/` (§2.6, §4.1) |
| O2 conflict-named images | Removed; the Mac wins (§3.5) |
| O3 `dirtyIds` | Removed (§3.6) |
| O4 empty-folder cleanup | Removed (§3.7) |
| Not in the review: removing `stickies-id` on iOS could trash the note on the Mac | The "unknown" state (§3.2) plus read-only `stickies-*` lines on iOS (§6.6) |

### Revision 3 (2026-10-11): Core v1 scope

- New "Scope" subsection in §0: Core v1 contents, the fallback rule ("skipped and reported, never guessed"), and the table of later cases with their v1 behavior.
- **Later** markers in §2.3, §2.7, §3.3, §3.5 and §4.2.
- §10 rewritten as the Core v1 order of work on the branch `sync-rewrite`. The stopgaps are removed because the old apps aren't used for syncing in the meantime.

### Revision 3.1 (2026-10-11): color has one source

- `stickies-color` is written for every opened note, yellow included (no "absent = default" shortcut).
- The Mac no longer stores colors in `note-state.json`; an old stored color is moved into the note on its next open and then dropped. The note list reads colors from the files (cached with the ids).
