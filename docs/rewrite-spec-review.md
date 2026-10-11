# Review of `docs/rewrite-spec.md`

Status: independent review · 2026-10-11 · read-only (no files changed besides this one)

Scope: the full spec, checked against the current code in `MarkdownStickies/`, `MarkdownStickiesIOS/` and `MarkdownStickiesCore/`. The decisions in §0 "Decisions already made" were not questioned. Findings only name problems those decisions cause.

Labels:

- **CONFIRMED**: traced through the spec and, where relevant, the code.
- **SUSPECTED**: plausible, but not fully traced.

Line numbers refer to the current working tree.

Summary: the core design holds up: hash-only decisions, trash-only deletes, conditional writes, and a base that only advances on matching hashes. The holes are at the edges:

- what counts as "deleted"
- how iOS root folders map to roots
- interrupted sessions
- several §5 claims that don't match the code

---

## Top 5

1. **D1**: a stale copy of the iOS vault (same `vaultId`) silently overwrites newer Mac text. The old text can't be recovered.
2. **D2**: renaming, moving or deleting a root folder on iOS trashes that root's notes on the Mac. If there are 10 notes or fewer, there is no prompt.
3. **D3**: "Leaving the sync set" trashes unsynced iOS edits. The planner also can't tell "left the set" from "deleted".
4. **D4**: duplicate ids on iOS (Files → Duplicate) are undefined. One copy silently overwrites and renames the Mac note.
5. **D6**: the iOS original can be overwritten even when the Mac failed to write the conflict copy.

---

## Task 1: Data loss

### D1 · critical · CONFIRMED · A stale vault with the same `vaultId` overwrites newer Mac content
**Spec:** §2.5, §2.6, §3.2, §3.3, §3.8 (vault identity), §3.1 rule 2

**Scenario:**
1. Sync. The base for "Idea" is H1 on both devices.
2. The iOS vault folder is copied, by Files → Duplicate, an iCloud backup, or a copy kept before a reinstall. `.stickies-vault`, and with it the `vaultId`, is copied too.
3. Idea is edited on the Mac (H2) and synced. Both devices and the base are now H2.
4. The user re-picks or restores the old copy, where Idea is H1.
5. At the next sync the Mac is unchanged (H2 = base) and iOS counts as "modified" (H1 ≠ H2). The planner copies iOS → Mac.

**Result:**
- **Mac:** Idea is H1. H2 is gone, because the overwrite doesn't go to the Trash and the base stores only hashes.
- **iOS:** Idea is H1.
- Notes created after the copy count as "deleted on iOS" and are trashed on the Mac. At 10 or fewer there is no prompt.

**Suggested fix:**
- Store a generation counter in `.stickies-vault`. The Mac increments it at commit and stores it with the base. A mismatch means the session runs as a first sync.
- Every overwrite on the Mac moves the previous file to the Trash first, so that rule 2 also covers overwrites.

### D2 · critical · CONFIRMED · Problems with an iOS root folder become mass deletes on the Mac
**Spec:** §2.5, §3.6 step 2, §3.8

**Scenario A:**
1. In Files, the user renames `ProjectA` to `Project A`, or moves or deletes it.
2. iOS now treats the folder as unknown ("Not synced"). The manifest has none of root A's ids.
3. Each note counts as deleted on iOS and unchanged on the Mac, so it is trashed on the Mac.
4. The root has 8 notes, so the bulk guard doesn't fire.

**Result A:**
- **Mac:** 8 project notes are in the Trash.
- **iOS:** the notes sit in a "Not synced" folder.
- At the next sync both sides are "deleted", the base is forgotten, and the notes never come back.

**Scenario B:**
1. There are two roots named "Notes" (A) and "Notes (2)" (B).
2. The user removes root A.
3. The spec doesn't say whether folder names are recomputed. If they are, B becomes "Notes".
4. iOS scans A's old folder as root B, so A's ids appear under B.
5. B's real folder becomes unknown, so B's notes are trashed on the Mac.

Step 2 only checks that the vault is readable and that `vaultId` matches. It doesn't check each root folder.

**Suggested fix:**
- Store the `rootId → folderName` mapping in `.stickies-vault`, and never reassign a name once it is given.
- A missing root folder aborts the sync and names it, like an unreadable root on the Mac.
- Also trigger the bulk guard when a root loses most of its notes, whatever the count.

### D3 · high · CONFIRMED · Leaving the set throws away iOS edits; "left" and "deleted" can't be told apart
**Spec:** §3.3 (Notes leaving the sync set), §3.6 steps 3–4, §2.4

**Scenario:**
1. Idea is synced. The base is H1.
2. Idea is edited on iOS (H2) and not synced yet.
3. On the Mac, one of these happens:
   - an EXCLUDE rule now matches the note
   - the user moves it to a non-synced folder
   - the user turns off Sync for its root (the confirmation doesn't mention pending edits)
4. At the next sync the iOS copy goes to `.stickies-trash` and the base entry is dropped.

**Result:**
- **Mac:** H1.
- **iOS:** H2 exists only in the trash and is purged after 30 days. The summary just says "moved to Trash".

**Classification gap:** the Mac manifest contains only the sync set. Without probing the old path, the planner can't tell "left the set" from "deleted".

**Resurrection variant:**
1. The user moves the Mac file to `~/Downloads` in Finder. This looks like a delete.
2. iOS modified the note, so the decision is "restore on the Mac from iOS".
3. A second file with the same `stickies-id` appears in the synced root, while the original sits in Downloads.

**Suggested fix:**
- Leaving the set follows the edit-vs-delete rule. If iOS modified the note, write the iOS version to the Mac file (if the Mac is unchanged) or to a conflict copy next to it. Only then trash the iOS copy.
- Define the classification: a file with that id that still exists outside the set means "left". Otherwise the note is "deleted".

### D4 · high · CONFIRMED · Duplicate ids on iOS are undefined
**Spec:** §2.3 (only the Mac repairs duplicates), §3.2, §3.6 step 3

**Scenario:**
1. In Files, the user duplicates `Idea.md`. This creates `Idea 2.md` with the same id.
2. The user rewrites `Idea 2.md` as a different note.
3. The manifest contains id X twice. A planner keyed by id keeps whichever one comes last.
4. If it keeps `Idea 2.md`, that counts as a modification on iOS plus a path change, with the Mac unchanged.

**Result:**
- **Mac:** `Idea.md` is overwritten with Idea 2's text and renamed to `Idea 2.md`.
- **iOS:** the original text survives only in `Idea.md`, which is hidden behind the duplicate.
- If the order flips at a later sync, the name and the content flip back.

**Suggested fix:**
- Repair duplicates on iOS before building the manifest, with the same rule as on the Mac. Alternatively, the manifest lists every instance and the Mac sends write ops that give the extra copies new ids.
- Add the case to the §8.2 tests.

### D5 · high · SUSPECTED · Unreadable or cloud-evicted files count as "deleted"
**Spec:** §2.4, §3.7 (hidden path components), §3.6 step 2 and §3.8 (only roots are checked)

**Scenario on iOS:**
1. The vault is in iCloud Drive. The folder picker allows that.
2. iOS evicts `Idea.md` and leaves the hidden placeholder `.Idea.md.icloud`.
3. The scanner skips hidden files, so the note counts as deleted on iOS and is trashed on the Mac.

**Scenario on the Mac:**
1. A file can't be read. Causes: a dataless iCloud file while offline, permission denied, or invalid UTF-8 after an external tool changed it.
2. The id can't be read, so the note counts as deleted on the Mac and is trashed on iOS.

**Suggested fix:**
- Any file under a root that can't be read, placeholders included, goes into the manifest as "unknown", by path.
- Never classify an id as deleted while its base path is unknown.
- On iOS, either download evicted files first or refuse vaults inside cloud providers.

### D6 · high · CONFIRMED · The iOS original is overwritten although the conflict copy wasn't written
**Spec:** §3.4 step 2 ("only after step 1 is confirmed"), §3.6 steps 4, 6, 7

**Scenario:**
1. Both sides modified a note. The plan is built in step 4.
2. In step 6 the Mac fails to write the conflict copy. Causes: no write permission in that project folder, a full disk, or the file name was taken after planning.
3. Nothing ties the step 7 ops to the results of step 6. iOS receives "write the Mac version over the original (expect H_ios)" and applies it.

**Result:** the iOS version existed only in the Mac's memory and is lost on both devices.

**Suggested fix:**
- Build the step 7 ops from the actual results of step 6, and drop every op whose prerequisite failed.
- Add `dependsOn: opId` to the ops, and have iOS skip dependent ops when the earlier op was skipped.

### D7 · medium · CONFIRMED · Each interrupted session after step 6 creates another conflict copy
**Spec:** §3.4; §3.6 "Failures" (claims the matching-hash shortcut detects steps already applied)

**Scenario:**
1. The Mac writes conflict copy C1 with a random id.
2. The connection drops at step 7.
3. At the next sync the original is still modified on both sides, so the Mac creates C2.
4. C1 is sent to iOS as "created on the Mac".

**Result:** two identical conflict copies on both devices, and one more after each further failure.

**Suggested fix:** derive the copy's id deterministically, for example UUIDv5(originalId, iOS fileHash). Reuse an existing copy with that id.

### D8 · medium · CONFIRMED · Commit stores a single `base.path` even when the move was skipped
**Spec:** §2.6, §3.3 path table, §3.6 step 9

**Scenario:**
1. A note is renamed from Idea to Plan on the Mac.
2. The move on iOS is skipped, because the editor is dirty or the target exists. The content hashes still match, so commit runs.
3. Suppose commit stores the Mac path. At the next sync, the iOS path (Idea) differs from the base (Plan), which counts as "changed on iOS".

**Result:** the Mac file is moved back to `Idea.md`. The user's rename is undone.

**Suggested fix:** update `base.path` only when both normalized paths are equal.

### D9 · medium · CONFIRMED · Notes created on iOS in folders the Mac excludes end up invisible on both devices
**Spec:** §2.4, §2.5, §3.7, §3.3

**Scenario:**
1. On iOS, the user creates a note in a folder the Mac doesn't scan:
   - `<root>/build/` or `<root>/vendor/`, which are built-in skips (`MarkdownStickiesCore/Sources/MarkdownStickiesCore/NoteScanner.swift:5-20`)
   - a folder matched by an EXCLUDE rule
   - a subfolder that is a deeper, non-synced root on the Mac
2. Sync 1 writes the note on the Mac and records the base.
3. At sync 2 the note isn't in the Mac's sync set, so it "leaves the set" and the iOS copy is trashed.

**Result:**
- **Mac:** the file sits in a folder the app never shows.
- **iOS:** the note is in the trash.

**Suggested fix:**
- The Mac checks every incoming iOS path against scan.conf, the built-in skips, hidden paths and overlapping roots.
- If a path isn't allowed, skip it with the reason "Folder is excluded on the Mac", and leave iOS untouched.

### D10 · medium · SUSPECTED · Rule 4 covers writes but not moves or trashes, and uses a stale dirty list
**Spec:** §3.1 rule 4, §3.6 step 3 (`dirtyIds` is a snapshot), §3.10

**Scenario:**
1. The iOS editor on Idea is clean at step 3.
2. The Mac renamed Idea to Plan. The user starts typing before step 8.
3. In step 8 the iOS writer moves the file to `Plan.md`. The hash check passes because the file on disk is unchanged.
4. The editor autosaves to the old path, as `MarkdownStickiesIOS/NoteEditorView.swift:198-212` does today. §3.10 doesn't define a save when the file is missing.

**Result:** a new `Idea.md` with the same id (the duplicate problem in D4), or a conflict copy whose handling is undefined. Trashing has the same race.

**Suggested fix:**
- Rule 4 covers write, move and trash.
- The writer checks whether the editor is dirty when it applies each op, not from the step 3 list.
- A save whose file is missing goes through the conflict-copy path.

### D11 · medium · SUSPECTED · Duplicate ids outside the sync manifest collide in id-keyed window state
**Spec:** §2.3 (the fix-up runs only before the manifest is built), §6.1

**Scenario:**
1. A tracked note is copied into a non-synced root, or into a synced root before the next sync runs.
2. Both files carry the same id. The window maps keyed by id (§2.3) map two files to one key.
3. Opening or saving one of them can target the other file.

**Suggested fix:** detect duplicates on every rescan, or keep runtime window maps keyed by path and use the id only for persisted state.

### D12 · medium · CONFIRMED · The image set's note versions are undefined, so a new iOS image can be trashed
**Spec:** §2.4, §3.5

**Scenario:**
1. On iOS, the user adds `docs/diagram.png` through Files and references it in an edit of `idea.md`.
2. Suppose the image set comes from the Mac's notes, since only the Mac evaluates scan.conf. No Mac note references the image yet.
3. The image "leaves the set" and is trashed on iOS, in the same session in which `idea.md` reaches the Mac.

**Result:** the image is broken on both devices.

**Suggested fix:** compute the image set after the note decisions, from the post-plan versions of each note on both sides.

### D13 · low · SUSPECTED · A crash during a case-only move leaves the note at a temp name
**Spec:** §3.3 ("the move goes through a temp name"), §3.9

**Scenario:**
1. The Mac crashes in the middle of a case-only move.
2. If the temp name is hidden or doesn't end in `.md`, the note drops out of the set.
3. It counts as deleted on the Mac and is trashed on iOS.

**Result:** the Mac file stays at the temp name, invisible to the app.

**Suggested fix:** specify the temp name, plus a writer journal that is recovered at launch before any scan.

### D14 · low · CONFIRMED · Frontmatter detection can write `stickies-id` into the note body
**Spec:** §2.1 rule 1, §5.1 (keeps the parser and `upsert`)

**Problems in the kept parser:**
- It skips leading blank lines and treats the first `---`…`---` pair as YAML (`MarkdownStickiesCore/Sources/MarkdownStickiesCore/NoteFrontmatter.swift:424-454`). A note that starts with a horizontal rule gets `stickies-id:` written into its visible text on first open.
- `upsert` rewrites the closing fence with `\n`, which mixes line endings in CRLF files.
- A UTF-8 BOM hides an existing block, so a new block is inserted in front of it. This breaks rule 1.

**Suggested fix:** frontmatter must start on line 1, after an optional BOM. Writes preserve the file's line endings.

### D15 · low · CONFIRMED · Edit-vs-delete brings notes back on the wrong git branch
**Spec:** §3.3

**Scenario:**
1. A branch switch removes a note on the Mac while iOS edited it.
2. Edit wins, so the note is restored on the Mac as an untracked file on the wrong branch.
3. Switching back, git refuses the checkout because the untracked file would be overwritten.

Nothing is lost, but users will be surprised.

**Suggested fix:** mention the case in §7.

---

## Task 2: Spec gaps

### G1 · high · CONFIRMED · `base-text/` can't be produced
**Spec:** §2.6 (the base stores only hashes), §3.4 step 4, §4.2

At conflict time neither device has the base text, so the merge view always falls back to the two-way view.

**Suggested fix:** store the base file content for each note in the sync state; notes are small. This also enables the overwrite backup in D1. Otherwise, remove the three-way merge from §4.

### G2 · high · CONFIRMED · The bulk-guard pause breaks the 15-second idle timeout
**Spec:** §3.6 step 4 and "Failures", §3.8

iOS waits for step 5 while the Mac shows the dialog. After 15 seconds iOS times out, and pressing Continue on the Mac then fails. Long hashing on large trees and a long apply step on iOS have the same problem.

**Suggested fix:** whichever side is busy sends a keepalive or progress frame every 5 seconds.

### G3 · high · CONFIRMED · The frame limit can't hold the messages in steps 5 and 7
**Spec:** §3.6 transport, steps 5 and 7

Each of these steps sends all file contents in a single message, and a frame holds at most 32 MB. One 20 MB image is about 26.7 MB in base64. A first sync with two large images, or many smaller ones, can never finish.

**Suggested fix:** send one item per frame, or stream in chunks.

### G4 · medium · CONFIRMED · Created notes have no collision rule, so the sync never converges
**Spec:** §3.3 (the numeric-suffix rule covers only moves)

A note created on iOS is written on the Mac with the precondition "must not exist". If the Mac already has a file at that path, for example an untracked `README.md`, the write is skipped at every sync.

**Suggested fix:** apply the same suffix rule to creates. The next sync then sees the path change on the Mac and moves the iOS copy.

### G5 · medium · SUSPECTED · "Both file systems ignore case" (§3.7) isn't true for iOS
On iOS, APFS is case-sensitive, and so are some external volumes on the Mac. `Idea.md` and `idea.md` can coexist on iOS and then run into G4 on the Mac.

**Suggested fix:** the iOS writer checks for collisions that differ only in case before it creates a file. Case folding is used only for these collision checks.

### G6 · medium · CONFIRMED · When a base entry is removed is undefined
**Spec:** §3.3 ("dropped", "forget base"), §3.6 step 9 (defines only how a base is set)

**Scenario:**
1. The base entry is dropped at planning time.
2. The trash op on iOS is skipped.
3. At the next sync the note exists on iOS with no base, so it counts as created on iOS.
4. iOS → Mac brings the note back, with a duplicate id next to the original that was moved out.

**Suggested fix:** step 9 removes a base entry only when both sides confirm the note is gone.

### G7 · medium · CONFIRMED · The image rules (§3.5) leave cases undefined
- deleted on iOS but still referenced: send it again, or forget it?
- modified on the Mac and deleted on iOS
- created on both sides with the same hash
- an image moved on the Mac

**Suggested fix:** write a full table like the one in §3.3, with "trash on the Mac" replaced by "keep on the Mac and send again".

### G8 · low · CONFIRMED · Field merge doesn't define an identical text change on both sides
**Spec:** §3.3 (field merge)

This happens after every interrupted field merge. Treated as "changed on both sides", it creates an unneeded conflict copy.

**Suggested fix:** an identical change counts as a change on one side.

### G9 · low · CONFIRMED · iOS can already change the color and the id
**Spec:** §6.6

The iOS "Show Frontmatter" mode edits the whole document (`MarkdownStickiesIOS/NoteEditorView.swift:36-43`, `:143-148`). So "iOS can't change the color" is false, and the "color changed on both sides" case can actually happen.

**Suggested fix:** state this in §6.6, or hide the `stickies-*` keys in the iOS editor.

### G10 · low · Duplicate fix-up: "oldest file" has no tie-break
**Spec:** §2.3

A Finder copy keeps the creation date, so two files can tie. The fix-up may also write into an open note with unsaved edits, which breaks rule 4.

**Suggested fix:** break ties by path. Delay the fix-up while the note has unsaved edits.

### G11 · low · `restHash` isn't defined precisely
**Spec:** §2.6

Undefined:
- whether only a line inside the frontmatter is removed
- whether the key match is case-sensitive
- how the line ending of the removed line is handled

**Suggested fix:** define it exactly in `NoteHashing`.

### G12 · low · Undefined edge cases on iOS and in moves
**Spec:** §2.5, §3.3

- Where a new iOS note goes before the first sync, when no root folders exist yet.
- Two notes that swap names in one session (A↔B) end up with permanent ` (2)` suffixes.

**Suggested fix:** define a default folder for new notes before the first sync. Run moves in two phases, through temp names.

---

## Task 3: Wrong claims (§0, §5)

### W1 · high · CONFIRMED · The image helpers marked "keep" depend on a function marked "delete"
**Spec:** §5.1

`sanitizedFilename` is on the delete list. The functions on the keep list call it, all in `MarkdownStickiesCore/Sources/MarkdownStickiesCore/SyncImageAssets.swift`:
- `relativeImageFilenames` (line 68)
- `resolveImageURL` (line 197)
- `resolveExistingImageURL` (line 246)
- `findImageFile` (line 271)

### W2 · medium · CONFIRMED · The kept image helpers don't implement §2.4
**Spec:** §5.1, §2.4

Problems, all in `SyncImageAssets.swift`:
- `rawImageDestinations` (lines 222-243) matches only `![…](…)`, not `<img src>`.
- It handles neither link titles (`"…"`) nor `%20`.
- `resolveExistingImageURL` (lines 245-263) rejects `..`.
- If the structured path doesn't exist, `resolveExistingImageURL` falls back to a file with the same name next to the note, which can pick the wrong image.

**Suggested fix:** list these helpers as "rewrite", not "keep".

### W3 · medium · CONFIRMED · Custom hex colors exist
**Spec:** §2.1 rule 5, §2.2, §6.1

The app has `NoteColor.custom(hex)` (`MarkdownStickies/Models/StickyColor.swift:47-50`) and a custom color picker (`MarkdownStickies/Windows/StickyWindowController.swift:276`). The spec knows only the six presets. Custom colors are either lost when color moves into the file, or written as unknown values.

**Suggested fix:** allow `#rrggbb` values, or migrate custom colors explicitly.

### W4 · medium · CONFIRMED · `initialDocument` and `upsert` still write `id:`
**Spec:** §5.1, §2.2

- `initialDocument` writes `id:` (`MarkdownStickiesCore/Sources/MarkdownStickiesCore/NoteFrontmatter.swift:296-319`). §5 doesn't mention it. It is used by:
  - `MarkdownStickies/Services/NoteStore.swift:626` (`createNote`)
  - `MarkdownStickiesIOS/ContentView.swift:401` (note creation on iOS)
  - the catch branch of `StickyWindowManager.open`
- The kept `upsert` adds `id:` before any other key (`NoteFrontmatter.swift:386-389`). It also places new keys according to `preferredKeyOrder`.
- §5 doesn't mention these symbols either: `matchingRoot`, `normalizeFolder`, `idKey`, `createdOnKey`, `trashFolderName`.

### W5 · medium · CONFIRMED · The stopgap in §10 misses a second hard delete
**Spec:** §0, §10 step 2

`NoteStore.mergeConflict` also calls `removeItem` directly on the sibling copy (`MarkdownStickies/Services/NoteStore.swift:309-315`). This is separate from `removeConflictSiblingCopies`, so stopping only that function leaves this delete in place.

### W6 · low · CONFIRMED · Two more image writers overwrite on collision
**Spec:** §5.2

§5.2 lists only `saveImageFile`. `saveImage` and `saveImageData` also replace an existing file through `.atomic` writes (`MarkdownStickies/Services/NoteImageStore.swift:27`, `:69`). The timestamps have millisecond precision, so this is rare.

### W7 · low · CONFIRMED · iOS has no code that pastes or saves images
**Spec:** §3.5, §8.6

No such code exists in `MarkdownStickiesIOS/`. "Both apps name pasted images" is wrong. The test scenario "an iOS-created note with an image" in §8.6 can't be produced in the app.

### W8 · low · CONFIRMED · Symbols missing from §5.2 and §5.3
- `VaultStore.syncInboundPaths`, `syncOutboundPaths` and `acknowledgeInbound` (`MarkdownStickiesIOS/VaultStore.swift:26-28`, `:307`), and their use in `MarkdownStickiesIOS/ContentView.swift:267`
- `MarkdownStickies/Views/ControlWindowView.swift:40` (the binding to `pendingConflicts`) and `:214-215` (`syncInboundPaths` and `syncOutboundPaths`)
- `StickyWindowManager.renameNote` (`MarkdownStickies/Windows/StickyWindowManager.swift:266-300`), which uses path-keyed maps and `touchForSync`
- `NoteFrontmatter.isTrashed` matches a folder named `Trash` at any depth, not just the legacy `Trash/` at the root of each folder (`NoteFrontmatter.swift:205-207`). The iOS app also uses it (`MarkdownStickiesIOS/VaultStore.swift:220`).

### Verified correct

All §0 claims match the code:

| §0 claim | Code |
|---|---|
| Deletion during renames: the `finalizeRename` destination delete | `MarkdownStickiesCore/Sources/MarkdownStickiesCore/SyncCatalogBuilder.swift:523-526` |
| Overwrite on a failed read: the catch branch in `open` | `MarkdownStickies/Windows/StickyWindowManager.swift:47-54` |
| Deletion by content match | `MarkdownStickies/Services/NoteStore.swift:357-374` |
| Sync hangs: the timeout is checked only between chunks | `MarkdownStickiesCore/Sources/MarkdownStickiesCore/LanSyncService.swift:823-856` |
| Stale iOS saves: faked modification time on load, plain overwrite on save | `MarkdownStickiesIOS/NoteEditorView.swift:166-212` |
| In-vault `Trash/` with a `folder:` stamp | `NoteFrontmatter.swift:231-257` |
| `debug-*.md` logs written into note folders | `SyncFeedback.swift:280-330` |
| iOS reads scan.conf | `MarkdownStickiesIOS/VaultStore.swift:127`, `:219` |

All other symbols listed in §5.1–5.3 exist where stated.

---

## Task 4: Over-engineering

- **O1:** drop `conflicts.json`. The copy's frontmatter already holds `originalId`, and `baseRestHash` is useless without the base text. Keep only `base-text/`, and only if G1 is fixed.
- **O2:** image conflicts. §3.5 step 2 already puts the previous iOS image into `.stickies-trash`. The extra conflict image on the Mac only clutters project folders and could be dropped.
- **O3:** `dirtyIds` in the manifest is redundant once the writer checks for unsaved edits at apply time (D10). At most, keep it as a hint.
- **O4:** remove the optional empty-folder cleanup (§3.7).

---

## Checked and found sound

- Deletes go only to the trash, with no fallback to `removeItem` (rule 2). The exception is overwrites; see D1.
- The matching-hash shortcut makes retries of plain writes, moves and trash moves safe.
- Conditional writes protect against external edits made between the manifest and the apply step.
- The step 5 check compares received hashes against the manifest.
- Edit-vs-delete works in both directions.
- A vault the Mac hasn't seen never causes deletes.
- An unreadable root on the Mac aborts the sync.
- Commit advances a note's content base only when the hashes match, so the base is always a common ancestor. The path is the exception; see D8.
- Saving a merge checks its precondition, and the merge interacts correctly with later syncs (§4.3).
- Path validation blocks `..` traversal and symlinks that escape the root (§3.7).
- NFC normalization is used for comparisons.
- Duplicate-id repair on the Mac works within synced roots, apart from the missing tie-break (G10).
