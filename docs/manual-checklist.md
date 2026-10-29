# Cleanori Phase 1: manual checklist

How to read it:

- `[x]` was checked on a **scratch home**: a Debug build started with `CLEANORI_HOME=<scratch folder>` (never the real
  home folder), watched in screenshots and driven with mouse and key events where needed. The numbers in brackets are
  what was seen.
- `[x] (code)` was checked by reading the code, the build and the tests, not by watching the running app.
- `[ ]` still needs you, on your Mac. Items marked **owner** need a person at the screen, or must use your real home
  folder.

The installed app is `~/Applications/Cleanori.app` (Release build, ad-hoc signed). A Release build ignores
`CLEANORI_HOME`, so it always works on the real home folder.

## Before any scan of your real home

- [ ] **Owner:** give Cleanori Full Disk Access. Open System Settings, Privacy & Security, Full Disk Access, press +, add
  `~/Applications/Cleanori.app`, switch it on, then quit and start Cleanori again.
  - The app is signed ad hoc, so macOS may treat every rebuilt and reinstalled copy as a new app. Repeat the grant (remove
    the old entry, add the app again) after each rebuild and reinstall.
  - Without it macOS asks once for each protected folder (Music, Photos, Documents, Desktop, Downloads, and so on) while
    a scan runs, and the scan waits for the answer. "Don't Allow" is safe: that folder is then skipped and the sizes
    above it are marked `≈`.
  - A prompt about Apple Music left over from an earlier test run may still be on the screen. Answer it or press Don't
    Allow.
- [ ] **Owner:** check Settings › Project folders before the first scan. Developer Junk looks for `node_modules` and
  project builds only in these folders (default `~/Developer`). Settings refuses your whole home folder, a folder that
  contains it, `~/Library` and anything in it, and folders outside your home folder, and a saved list from an older
  build is cleaned of such folders when the app starts. Add the folders that really hold your projects.

## Rehearse on a scratch home first (Debug build)

```sh
xcodegen generate
xcodebuild -project Cleanori.xcodeproj -scheme Cleanori -destination 'platform=macOS' -derivedDataPath build/DerivedData build
open -n build/DerivedData/Build/Products/Debug/Cleanori.app \
  --env CLEANORI_HOME=/path/to/scratch-home --env CLEANORI_AUTOSCAN=1      # 1 = Developer Junk, largefiles, diskmap
```

In that mode the log goes to `<scratch-home>/Library/Logs/Cleanori/`, "Move to Trash" items go to
`<scratch-home>/.Trash/`, and no simulators are listed or touched, so your own Trash, log and simulators stay untouched.
Developer Junk searches `<scratch-home>/Developer` only. The Settings values are still your real ones (`defaults` for
`dev.ori.Cleanori`), so Settings › Add… still checks folders against your real home folder: a folder of the scratch
home is refused as outside your home folder.

## 1. Developer Junk

- [x] Scan lists DerivedData, node_modules, package caches, project builds and iOS DeviceSupport, with Delete or Move to
  Trash tags and sizes. An old project's `node_modules` is ticked, a project worked on today is marked "active" and not
  ticked.
- [x] A `node_modules` whose folder has no `package.json` is listed with a "no package.json" tag and is not ticked, even
  when it is old (`tool-lib`, 301 days: unticked, while `shop-web` and `blog`, also 301 days, were ticked).
- [x] (code) Tool folders below a project folder (`.nvm`, `.vscode`, `.vscode-insiders`, `.cursor`, `.yarn`, `.cache`,
  `.local`, `.config`, `.npm`, `.pnpm-store`, `.bun`, `.gradle`, `.android`, `.cargo`, `.rustup`) and folders named
  `Library` are not searched, so npm's own `node_modules`, editor extensions and Yarn's unplugged packages are never
  listed. Other hidden folders, such as `.worktrees`, still are.
- [x] An open group starts with a grey line saying how its items come back (under node_modules: "Restored by running
  npm, pnpm, yarn or bun install in the project").
- [ ] Hover a group row and an item row: the tooltip has the same help text (an item's comes after its path). Open
  Package caches, Xcode Archives, iOS Simulators and Android emulators and read their lines: pnpm says the store may
  free much less than shown, Archives say they cannot be rebuilt, simulators and emulators say their apps and data are
  lost.
- [x] A group shows a dash when only some of its children are ticked (node_modules by default, DerivedData after one
  child was unticked). Ticking the iOS DeviceSupport group put its 12 MB into "Selected". Unticking a child works.
- [ ] Clicking a half-ticked group's checkbox ticks all of its children, and clicking a fully ticked group unticks them
  all.
- [ ] Locked row: open Xcode, press Rescan. DerivedData and iOS DeviceSupport show "Xcode is running", cannot be ticked
  and are not in the totals. Close Xcode and rescan: they come back.
- [x] Confirm sheet: "Clean 84.3 MB?" with "Deleted permanently (cannot be undone) 72.3 MB" and "Moved to Trash 12 MB",
  the line "Log: ~/Library/Logs/Cleanori" (seen as text; in that check the log really went to the scratch home), Cancel
  and Clean. Pressing Return cancels (nothing was removed); Clean needs a click.
- [x] (code) The confirm sheet and the bottom bar list a way of removing as soon as one ticked item goes that way, even
  an item of 0 bytes, so a ticked delete always brings up "Deleted permanently (cannot be undone)" and the bar never
  says "all moved to Trash" while something is deleted.
- [x] Report banner: "Freed 72.3 MB · 12 MB moved to Trash", the APFS snapshot note, and the table refreshed
  (20 MB left: the project and DerivedData folder that were not ticked, still unticked).
- [x] Files on disk: ticked delete items gone, the ticked iOS DeviceSupport folder in `<scratch>/.Trash`, unticked items
  untouched.
- [x] Log: `clean-YYYY-MM-DD.jsonl` has one line per action (6 lines: 5 `delete`, 1 `trash`), each with
  `timestamp, action, ruleID, path, bytes, result, message`.
- [x] A scratch-home run lists no iOS Simulators group: in that mode no simulators are listed or touched.
- [x] (code) If `xcrun simctl` does not answer within 30 seconds (60 for a delete), it is stopped. The table then says
  "simctl did not answer in time · iOS Simulators skipped", and a delete that hangs is logged as failed with that reason
  instead of hanging the clean.
- [ ] **Owner:** real-home scan with Xcode closed finishes in under 2 minutes (spec §1, criterion 4). Time it from the
  Scan click to the table.
- [ ] **Owner:** the default selection on the real home is at least 90 GB (criterion 1). Read "Selected" in the bottom bar.
- [ ] **Owner:** the first real Clean, only after you have looked at the table and the confirm sheet. Afterwards check
  `~/Library/Logs/Cleanori/clean-*.jsonl` (criterion 3) and the free space on the Overview.

## 2. Large Files

- [x] Scan lists files over the minimum size, in the order Jan, Feb, Mar 2025 (oldest first), with kind chips and Kind,
  Last opened and Size columns. The dates shown were the modified dates set on the scratch files.
- [ ] **Owner:** on real files the "Last opened" column shows the date you last opened them (Spotlight's date), and the
  oldest come first.
- [x] Tick two files, then pick the "Videos" chip: one is hidden, and the bar says "Selected 134.8 MB · moved to Trash
  · 1 hidden by filters". Move to Trash moved only the visible ticked file; the hidden ticked file stayed where it was.
- [x] Move to Trash sheet says "Move 1 file to Trash?" with the size; the report says "1 file · 134.8 MB moved to
  Trash"; the log has one `trash` line.
- [x] A second file with the same name goes to the Trash as "Holiday-B 2.mov" and nothing is overwritten (scratch
  `.Trash` only; the real Trash does that itself).
- [ ] "Not opened in" menu (30, 90, 180, 365 days) narrows the list after a rescan.
- [ ] Reveal in Finder, from the button and from the right-click menu.
- [ ] A file inside a Developer Junk folder (for example under `~/.npm`, or in a project's `android/app/build`,
  `ios/build`, `ios/Pods`, `.next` or `.expo`) shows "Managed in Developer Junk" and cannot be ticked.
- [ ] **Owner:** the first real Move to Trash: the file lands in your real Trash and "Put Back" works.

## 3. Disk Map

- [x] Drill into a folder by clicking a bubble or a row, go back with the back button and the breadcrumb, hover
  highlights the row and the bubble, Rescan keeps the folder you are in.
- [ ] **Owner:** scan the real home (after the Full Disk Access step above) and check that Library and Developer are the
  two largest top-level folders. Note the total, the two largest folders and the scan time. Not done yet: in an earlier
  attempt macOS asked whether Cleanori may access Apple Music and nobody was there to answer, so the scan was stopped at
  about 8,000 items. A read-only scan of `~/Developer` alone measured 119.16 GB, 1,362,780 items, in 65 s.
- [ ] **Owner:** click through on the real home: drill, back, breadcrumb, Reveal in Finder (right-click), Choose folder…
  (the folder panel needs a person).

## 4. Settings and permissions

- [x] Settings opens with ⌘, as "Cleanori Settings": Inactive project threshold, Project folders with Add… and Remove,
  Large Files minimum size (100 MB, 500 MB, 1 GB, 5 GB).
- [x] The threshold stepper goes up one day per click (60 to 63).
- [x] (code) The stepper stops at 7 and 365, and a saved value outside 7 to 365 is ignored at start (the default,
  60, is used).
- [ ] **Owner:** hold the stepper down at both ends: it stops at 7 and at 365.
- [x] Changing "Large Files minimum size" in Settings (100 MB to 500 MB) rescans Large Files by itself; the list became
  empty ("No file of 500 MB or more…") and the screen's "Larger than" menu shows 500 MB. Back to 100 MB brings the files
  back.
- [x] The threshold (63 days) was still 63 after quitting and starting the Debug app again.
- [ ] **Owner:** the other Settings survive a relaunch. In the installed app: set the Large Files minimum to 500 MB,
  empty the project folder list (it keeps "No project folders…" and Developer Junk finds nothing), quit, start again.
  Both are still there. (The values were seen in `defaults read dev.ori.Cleanori` right after the change, but a relaunch
  reading the empty list and the 500 MB back has not been checked.)
- [x] Remove takes the selected folder out of the list and shows "No project folders…". The Add… panel opens with "Choose
  the folders that hold your projects" (in the Debug rehearsal, at the scratch home).
- [ ] **Owner:** Add… a real folder: the panel comes down as a sheet on the Settings window, the folder appears in the
  list, adding it a second time is refused with "It is already in the list.", and the next Developer Junk scan looks
  inside it.
- [ ] **Owner:** Add… refuses your home folder, a folder that contains it (such as `/Users`), `~/Library` or a folder
  in it, and a folder outside your home folder. Each refused folder gets a line under the list saying why, and the list
  does not change.
- [x] (code) A saved project folder list that holds a folder Settings would refuse (from an older build) is cleaned
  when the app starts; if nothing is left of it, `~/Developer` is used.
- [ ] **Owner:** change a setting in the installed Release app, quit it, start it again: the value is still there.
- [x] Full Disk Access banner: shown on the Overview only when the Safari container cannot be listed (a scratch home with
  `Library/Containers/com.apple.Safari` set to `chmod 000`); not shown when that folder does not exist (every other
  scratch home). The × hides it until the next launch.
- [x] "Open Settings" opens System Settings at Privacy & Security, Full Disk Access.
- [ ] **Owner:** on your Mac the banner matches reality. After granting Full Disk Access to Cleanori (see above) and
  restarting the app, the banner is gone and fewer sizes are marked `≈`.

## 5. Window and appearance

- [x] Dark mode: Overview, Developer Junk, Large Files, the sheets, the report banners, Settings and the Full Disk
  Access banner looked right in screenshots. Disk Map in dark mode was checked in an earlier round of screenshots.
- [ ] **Owner:** light mode on every screen, the Settings window and the banner (tag colours and the white text on the
  orange Large Files button are the ones to look at).
- [ ] **Owner:** the window can be dragged by the empty band at the top (the title bar is hidden).
- [ ] **Owner:** the sidebar toggle button at the top left of the window hides and shows the sidebar.
- [ ] **Owner:** the window cannot be made narrower than 860 pt, and nothing is cut off at that width (a long help line
  under an open group may end in "…"; its tooltip has all of it).
- [ ] **Owner:** VoiceOver: sidebar rows, the table checkboxes, the Clean and Move to Trash buttons, the bubbles and rows
  in Disk Map ("<name>, <size>"), the sheets and the Settings controls are all read out and can be used.
- [x] Scan and clean animations, on a scratch home in dark and light mode: bubbles in the module's colours drift up
  behind the module icon while scanning, and fade out before the top edge; while cleaning, the table gives way to a
  cluster of bubbles (the biggest items the biggest) that pop as items finish, smallest first; when the report appears,
  sparkles burst once from the middle of the table.
- [ ] **Owner:** with System Settings → Accessibility → Display → Reduce motion on, the scan bubbles stand still, the
  clean bubbles fade without popping and there is no sparkle burst.
- [ ] **Owner:** Large Files' Move to Trash shows the same bubbles in orange (checked in code, not on screen).
