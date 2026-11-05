# Playlist Sorting Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement temporary playlist sorting (Spotify-style) across mobile and desktop for Mornye, supporting sorting by custom order, date added, title, artist, album, and duration without mutating saved playlist order.

**Architecture:** Create a domain model `PlaylistSortMode` and utility comparator functions for sorting track collections in memory. Update `TrackListTable` / `SliverTrackTable` to support an optional Date Added column with interactive header clicks on desktop. Add a dedicated sort button with modal sheet (mobile) and popup menu (desktop) in `LibraryTracksFolderScreen` and `PlaylistScreen`, directing playback to use the sorted view sequence.

**Tech Stack:** Flutter (Dart), Flutter Riverpod, Material/Desktop design components.

**Spec:** `docs/superpowers/specs/2026-11-05-playlist-sorting-design.md`

## Global Constraints
- Preserve existing manual playlist order when `PlaylistSortMode.custom` is active.
- Sorting in `LibraryTracksFolderScreen` and `PlaylistScreen` must be non-destructive (view-only state).
- Desktop table headers must support sorting toggle (ascending, descending, and reset to default).
- Code changes must adhere to Mornye styling and lint rules (`analysis_options.yaml`).

## Review Focus
1. **Identical or missing `addedAt` timestamps:** Two tracks added at the same millisecond or lacking timestamps must maintain their original relative order (stable sort). (Tested in Task 1).
2. **Missing or null track metadata:** Empty titles, null artists, or zero duration must sort gracefully at the end without throwing exceptions. (Tested in Task 1).
3. **Case-insensitive & diacritic-tolerant string comparison:** Sorting by title or artist must treat "á", "A", and "a" properly without ASCII-byte case skew. (Tested in Task 1).
4. **Custom order restoration:** Toggling back to `custom` mode must restore the exact initial list indices. (Tested in Task 1).
5. **Desktop header cycle:** Repeated clicks on a column header in `SliverTrackTable` must cycle: ascending -> descending -> default. (Tested in Task 2).

---

### Task 1: Environment Setup & `PlaylistSortMode` Domain Model

**Files:**
- Create: `lib/models/playlist_sort.dart`
- Test: `test/playlist_sort_test.dart`

**Interfaces:**
- Produces:
  ```dart
  enum PlaylistSortMode {
    custom,
    dateAddedDesc,
    dateAddedAsc,
    titleAsc,
    titleDesc,
    artistAsc,
    artistDesc,
    albumAsc,
    albumDesc,
    durationAsc,
    durationDesc,
  }

  List<CollectionTrackEntry> sortCollectionTrackEntries(
    List<CollectionTrackEntry> entries,
    PlaylistSortMode mode,
  );

  List<Track> sortTracksByMode(
    List<Track> tracks,
    PlaylistSortMode mode,
  );
  ```

- [ ] **Step 1: Write the failing unit tests for `PlaylistSortMode` and comparators**

Create `test/playlist_sort_test.dart` exercising:
- Sorting `CollectionTrackEntry` by `dateAddedDesc` and `dateAddedAsc`.
- Sorting by `titleAsc` (case-insensitive, diacritic comparison).
- Sorting by `artistAsc` and `albumAsc` with null/empty values placed last.
- Sorting by `durationAsc` and `durationDesc`.
- Preserving stable indices when returning to `custom` mode.
- Verifying identical dates maintain relative order.

- [ ] **Step 2: Ensure Flutter/Dart test environment is active and verify tests fail**

Run: `flutter test test/playlist_sort_test.dart`
Expected: FAIL (file or definitions missing)

- [ ] **Step 3: Implement `PlaylistSortMode` and comparators in `lib/models/playlist_sort.dart`**

Implement `PlaylistSortMode` enum, label helpers, and comparator sorting methods for `List<CollectionTrackEntry>` and `List<Track>`.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/playlist_sort_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/models/playlist_sort.dart test/playlist_sort_test.dart
git commit -m "feat(playlist): add PlaylistSortMode domain model and comparators"
```

---

### Task 2: Desktop Track Table: Add `TrackTableColumn.dateAdded` Support

**Files:**
- Modify: `lib/widgets/desktop/track_table.dart`
- Modify: `lib/widgets/desktop/track_list_table.dart`
- Test: `test/desktop_track_table_date_added_test.dart`

**Interfaces:**
- Consumes: `TrackTableColumn`, `TrackTableRow`, `PlaylistSortMode`
- Produces:
  - `TrackTableColumn.dateAdded`
  - `TrackTableRow` optional property `DateTime? dateAdded`
  - Formatted relative or short date display in table cell
  - Desktop header click sort support for `dateAdded`

- [ ] **Step 1: Write the test for `TrackTableColumn.dateAdded`**

Create `test/desktop_track_table_date_added_test.dart` testing:
- Header label for `dateAdded` is rendered.
- Rows display formatted date when `dateAdded` is provided.
- Clicking the `dateAdded` header sorts rows chronologically.
- Second click reverses order to descending.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/desktop_track_table_date_added_test.dart`
Expected: FAIL with missing `TrackTableColumn.dateAdded`

- [ ] **Step 3: Implement `dateAdded` in `track_table.dart` and `track_list_table.dart`**

- Add `TrackTableColumn.dateAdded` to `TrackTableColumn`.
- Add `dateAdded` field to `TrackTableRow`.
- In `_buildRows()` in `track_list_table.dart`, accept optional `List<DateTime>? datesAdded` to populate `dateAdded` on rows.
- Format `dateAdded` using relative or locale date (e.g. `addedAt.toLocal()`).

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/desktop_track_table_date_added_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/desktop/track_table.dart lib/widgets/desktop/track_list_table.dart test/desktop_track_table_date_added_test.dart
git commit -m "feat(desktop): add dateAdded column to TrackTable"
```

---

### Task 3: Playlist Sort UI Component (Modal Bottom Sheet & Popup Menu)

**Files:**
- Create: `lib/widgets/playlist_sort_sheet.dart`
- Test: `test/playlist_sort_sheet_test.dart`

**Interfaces:**
- Consumes: `PlaylistSortMode`
- Produces:
  ```dart
  Future<PlaylistSortMode?> showPlaylistSortSheet({
    required BuildContext context,
    required PlaylistSortMode currentSort,
    bool hasDateAdded = true,
  });

  Widget buildPlaylistSortButton({
    required BuildContext context,
    required PlaylistSortMode currentSort,
    required ValueChanged<PlaylistSortMode> onSortChanged,
    bool hasDateAdded = true,
  });
  ```

- [ ] **Step 1: Write test for `PlaylistSortSheet`**

Create `test/playlist_sort_sheet_test.dart` testing:
- Bottom sheet renders all sort options (Custom, Date Added, Title, Artist, Album, Duration).
- Selecting an option returns the selected `PlaylistSortMode`.
- Correct tile is checked/selected for `currentSort`.
- Hides `dateAdded` options when `hasDateAdded == false`.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/playlist_sort_sheet_test.dart`
Expected: FAIL

- [ ] **Step 3: Implement `lib/widgets/playlist_sort_sheet.dart`**

- Build responsive widget using Mornye's expressive design tokens.
- Support both mobile modal sheet and desktop popup menu anchor.
- Provide clear visual indicators (check icon / highlighted chip) for active sort.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/playlist_sort_sheet_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/widgets/playlist_sort_sheet.dart test/playlist_sort_sheet_test.dart
git commit -m "feat(ui): add PlaylistSortSheet and sort button widget"
```

---

### Task 4: Integrate Playlist Sorting in `LibraryTracksFolderScreen`

**Files:**
- Modify: `lib/screens/library_tracks_folder_screen.dart`
- Test: `test/library_tracks_folder_sort_test.dart`

**Interfaces:**
- Consumes: `PlaylistSortMode`, `sortCollectionTrackEntries`, `buildPlaylistSortButton`, `TrackTableColumn.dateAdded`
- Produces:
  - Working sort button in playlist header.
  - Sorted entries displayed in mobile `SliverList` and desktop `TrackListTable`.
  - Playback (Play All, Shuffle, row click) using the active sorted order.
  - Reset to custom order when entering manual reorder mode (`_editOrder`).

- [ ] **Step 1: Write widget test for playlist sorting in `LibraryTracksFolderScreen`**

Create `test/library_tracks_folder_sort_test.dart` testing:
- Sort button appears in playlist mode.
- Changing sort mode re-orders the visible tracks.
- "Play All" plays the tracks in the sorted order.
- Entering edit order resets or disables conflicting sorting.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/library_tracks_folder_sort_test.dart`
Expected: FAIL

- [ ] **Step 3: Implement sorting in `LibraryTracksFolderScreen`**

- Add `PlaylistSortMode _sortMode = PlaylistSortMode.custom;` to `_LibraryTracksFolderScreenState`.
- Compute `_effectiveEntries`: apply `sortCollectionTrackEntries(entries, _sortMode)` when `_sortMode != PlaylistSortMode.custom`.
- Pass `_effectiveEntries` to `TrackListTable` (including `datesAdded: _effectiveEntries.map((e) => e.addedAt).toList()`).
- Add sort button to `appBarActions` in `_buildAppBar`.
- Connect desktop table sort callbacks to update `_sortMode`.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/library_tracks_folder_sort_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/screens/library_tracks_folder_screen.dart test/library_tracks_folder_sort_test.dart
git commit -m "feat(playlist): integrate sorting into LibraryTracksFolderScreen"
```

---

### Task 5: Integrate Sorting into Catalog/External `PlaylistScreen`

**Files:**
- Modify: `lib/screens/playlist_screen.dart`
- Test: `test/playlist_screen_sort_test.dart`

**Interfaces:**
- Consumes: `PlaylistSortMode`, `sortTracksByMode`, `buildPlaylistSortButton`
- Produces:
  - Sort button in `PlaylistScreen` header actions.
  - Sorted display for catalog/external playlists (Title, Artist, Album, Duration, Release Date).

- [ ] **Step 1: Write test for `PlaylistScreen` sorting**

Create `test/playlist_screen_sort_test.dart` testing:
- Sort button is visible in `PlaylistScreen`.
- Changing sort order re-orders catalog tracks.
- Tapping track in sorted order plays correct index.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/playlist_screen_sort_test.dart`
Expected: FAIL

- [ ] **Step 3: Implement sorting in `PlaylistScreen`**

- Add `PlaylistSortMode _sortMode = PlaylistSortMode.custom;` to `_PlaylistScreenState`.
- Compute `_sortedTracks = sortTracksByMode(_tracks, _sortMode)`.
- Use `_sortedTracks` across list tiles, desktop table, and playback activation.
- Add sort button to `actions` / `appBarActions`.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/playlist_screen_sort_test.dart`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/screens/playlist_screen.dart test/playlist_screen_sort_test.dart
git commit -m "feat(playlist): integrate sorting into PlaylistScreen"
```

---

### Task 6: Full Verification & Code Health Check

**Files:**
- All touched files

- [ ] **Step 1: Run static analysis**

Run: `flutter analyze`
Expected: No errors or warnings in touched files.

- [ ] **Step 2: Run all playlist-related tests**

Run: `flutter test test/playlist_* test/desktop_track_table_date_added_test.dart test/library_tracks_folder_sort_test.dart`
Expected: All tests PASS.

- [ ] **Step 3: Final commit & summary**

```bash
git commit -m "chore: verify and finalize playlist sorting feature"
```
