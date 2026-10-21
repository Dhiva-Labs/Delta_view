# Microsoft Store listing (Partner Center)

The text to enter in Partner Center for DeltaView, kept here for future
updates. [docs/WINDOWS-STORE.md](../../../docs/WINDOWS-STORE.md) says where
each part goes.

## Pricing and availability

- Price: free. No in-app purchases.
- Markets: all.
- Visibility: public.

## Properties

- Category: Developer tools (subcategory Utilities, if Partner Center offers one).
- Privacy policy: <https://github.com/Dhiva-Labs/Delta_view/blob/main/PRIVACY.md>
- Website: <https://github.com/Dhiva-Labs/Delta_view>
- Support contact: reachout@dhivalabs.com
- Product declarations: installs to alternate drives allowed. Turn OFF
  OneDrive backup of app data: the privacy policy says DeltaView's settings,
  saved connections and host keys stay on the computer.
- System requirements: Windows 10 version 1809 or later, x64 or Arm64. No
  account. A network connection only for SFTP servers.

## Submission options: restricted capability

Partner Center asks why the package declares `runFullTrust`. Paste:

> DeltaView is a desktop (Win32) application, built with Flutter and packaged
> as MSIX; full trust is how a packaged desktop application runs. It is a file
> and folder comparison tool: it reads and writes the files and folders the
> user chooses anywhere on their drives, including paths passed on the command
> line by git difftool and git mergetool through its delta-view execution
> alias. It saves edits and merges, copies changes between sides, synchronizes
> folders, exports reports, opens SFTP connections to servers the user enters,
> and starts the external editor the user configures. It installs no services,
> drivers or background tasks, and sends no data anywhere except to the SFTP
> servers the user chooses.

## Store listing (English, United States)

**Product name:** DeltaView

**Short description:**

Compare folders and files side by side, merge changes, and sync folders. Works
with local drives, zip and tar archives, and SFTP servers, and as git difftool
and mergetool.

**Description:**

DeltaView shows what changed between two folders or two files, and helps you
bring them together.

Compare two folders and DeltaView scans both trees in the background and shows
them side by side: what is new, what was removed, and what differs. Open any
changed file to see a side-by-side diff with the changed words highlighted,
copy changes from one side to the other, or edit in place with undo. When the
folders should match, synchronize them with a preview of every step and a
confirmation before anything is overwritten or deleted.

For merge conflicts, DeltaView opens a three-way merge: your version, the
common ancestor and theirs, with the clean changes already merged and each
conflict one key away. It works as git difftool and git mergetool, and the
delta-view command opens comparisons from a terminal.

• Folder compare: recursive side-by-side trees, filters, sorting, ignore
  patterns and .gitignore support, quick compare by size and date for huge
  trees, and reports as HTML or CSV.
• File compare: side-by-side diff with in-line highlights, syntax
  highlighting, word wrap or horizontal scrolling, hidden unchanged runs, find,
  go to line and a minimap. Compare rules for whitespace, case, line endings
  and blank lines.
• Editing that respects your files: encoding (UTF-8, UTF-16, Latin-1) and line
  endings are kept when you save.
• Three-way merge: take a side, both, the base, or edit by hand.
• Images: side by side, swipe, onion skin and pixel difference.
• JSON, YAML and CSV compared by structure, so reordered keys or rows are not
  changes.
• Anywhere: local folders, zip and tar archives (read-only), SFTP servers
  (you confirm each server's key), and pasted text or the clipboard.
• Yours to tune: light and dark themes, accent color, color-blind-safe diff
  colors, editor font and size, density, and keyboard shortcuts you can
  change. Recent comparisons, open tabs and the window are remembered.
• Private: no account, no telemetry. DeltaView connects only to the SFTP
  servers you choose, and never saves passwords.

DeltaView is open source (MIT) at github.com/Dhiva-Labs/Delta_view.

**What's new in this version:** First Microsoft Store release.

**Product features** (one per line in Partner Center):

1. Side-by-side folder compare with filters and ignore rules
2. Side-by-side file diff with in-line highlights
3. Copy changes across and edit in place, with undo
4. Three-way merge, also as git mergetool
5. Folder sync with a preview of every step
6. Compare inside zip and tar archives
7. Compare folders on SFTP servers
8. Image compare: swipe, onion skin, pixel difference
9. JSON, YAML and CSV compared by structure
10. HTML and CSV reports
11. Keeps file encodings and line endings on save
12. delta-view command for terminals and git

**Keywords:** diff, compare files, compare folders, merge tool, folder sync,
git difftool, sftp

**Copyright:** © 2026 Dhiva Labs

**Developed by:** Dhiva Labs

**Screenshots:** none in the repository yet. Partner Center needs at least one
desktop screenshot, 1366×768 or larger. Suggested: a folder comparison, a file
diff, a three-way merge, an image comparison and Settings, each on Windows,
with critical content in the top two-thirds.

**Store logos:** `packaging/windows/msix/store-logos/`: the 1:1 app tile icon
(300×300) is the one the Store uses for apps; the 1:1 box art (1080×1080) and
2:3 poster art (1440×2160) are optional for apps. Rendered by
`packaging/windows/msix/make-assets.py`.

## Age ratings (IARC)

All Other App Types; answer No to every question (no ratings-relevant content,
no sharing between users, no location sharing, no digital purchases, not a web
browser or search engine). Expected result: IARC 3+, ESRB Everyone, PEGI 3,
USK 0.

## Certification notes

DeltaView needs no account and no network to test.

1. Start DeltaView. The home screen offers Folders, Files, Text and Merge.
2. Folders: pick two folders (for example two copies of a folder, one with an
   edited file) and press Compare. The tree marks what is new, removed or
   changed; double-click a changed file for its side-by-side diff.
3. Text: paste two snippets and press Compare.
4. In a terminal, `delta-view FOLDER1 FOLDER2` opens the same comparison
   through the app execution alias.

SFTP is optional and needs a server of your own: on a side's card, choose
Remote (SFTP)…, enter the server, user name and password, and confirm the
server's key.
