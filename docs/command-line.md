# DeltaView on the command line

DeltaView opens what you give it on the command line as its first tabs, so
it slots into `git difftool`, `git mergetool`, file managers and scripts.

The executable is `delta-view` on Linux when installed from the `.deb`
(a symlink to `/opt/delta_view/delta_view`), and
`C:\Program Files\DeltaView\delta_view.exe` on Windows (the installer's
default; adjust if you chose another folder). Examples below say
`delta-view`; on Windows use the full path or add that folder to `PATH`.

## Usage

```
delta-view                                   open the home screen
delta-view LEFT RIGHT                        compare two folders or two files
delta-view --merge LOCAL BASE REMOTE [--output MERGED]
                                             resolve a three-way merge
delta-view --help
delta-view --version
```

| Option | Meaning |
| --- | --- |
| `-m`, `--merge` | Treat the three paths as `LOCAL BASE REMOTE`. |
| `-o FILE`, `--output FILE`, `--output=FILE` | Where the merged result is written. Without it, the merge is saved over `LOCAL`. |
| `-h`, `--help` | Print the usage and exit. |
| `-V`, `--version` | Print `DeltaView <version>` and exit. |
| `--` | Everything after it is a path, even if it starts with `-`. |

Paths may be relative to the current directory and may start with `~`.
Whether a comparison is a folder tree or a side-by-side file diff is
decided from what is on disk: two folders open the folder view, two files
the file view.

DeltaView never refuses to start over a bad argument. Nothing found at a
path, a folder paired with a file, one path instead of two: each shows a
short notice at the top of the window and the home screen stays usable.
`--help` and `--version` exit without opening a window; everything else
exits with status 0 when the window closes.

```sh
delta-view ~/src/app ~/src/app-v2          # folder tree
delta-view a.json b.json                   # file diff
delta-view --merge mine.txt base.txt theirs.txt --output merged.txt
```

Comparisons opened from the command line replace the restored session for
that run; the session is saved again when the window closes.

## git difftool

```sh
git config --global diff.tool deltaview
git config --global difftool.deltaview.cmd 'delta-view "$LOCAL" "$REMOTE"'
git config --global difftool.prompt false
```

Then:

```sh
git difftool                 # each changed file in turn
git difftool HEAD~3 -- lib/  # against an older commit
git difftool --dir-diff      # the whole change set as one folder comparison
```

`--dir-diff` (`-d`) is the comfortable one: git writes both sides to
temporary folders and DeltaView opens them as a single folder comparison,
so you walk the tree instead of pressing through files one at a time.

On Windows, put the full path in the command, for example
`'"C:/Program Files/DeltaView/delta_view.exe" "$LOCAL" "$REMOTE"'`.

## git mergetool

```sh
git config --global merge.tool deltaview
git config --global mergetool.deltaview.cmd \
  'delta-view --merge "$LOCAL" "$BASE" "$REMOTE" --output "$MERGED"'
git config --global mergetool.deltaview.trustExitCode false
git config --global mergetool.keepBackup false
```

`git mergetool` then opens each conflicted file as a three-way merge:
your side on the left, the common ancestor in the middle, their side on
the right, and the result saved to `$MERGED` when you press Save. With
`trustExitCode false`, git treats the conflict as resolved when the merged
file was written, which matches how DeltaView works (it exits 0 whether or
not you saved). `keepBackup false` stops git leaving `*.orig` files behind.

## Compare from the file manager

The `.deb` installs a desktop entry that accepts folders and files, so in
GNOME Files you can select two folders (or two files), right-click and
choose *Open With → DeltaView*.

For a one-click menu entry, the package ships a script under
`/opt/delta_view/extras/`:

```sh
mkdir -p ~/.local/share/nautilus/scripts
ln -s /opt/delta_view/extras/compare-with-deltaview \
      ~/.local/share/nautilus/scripts/"Compare with DeltaView"
```

It appears under *right-click → Scripts → Compare with DeltaView* the next
time Files opens a menu (no restart needed). Nemo reads scripts from
`~/.local/share/nemo/scripts` and Caja from `~/.config/caja/scripts`; the
same script works in both.

What the script does with the selection:

| Selected | Result |
| --- | --- |
| two folders or two files | opens the comparison |
| three files | opens a three-way merge (`LOCAL BASE REMOTE` in selection order) |
| one item | remembers it; running the script on another item compares the two |

If `notify-send` is available it tells you what it remembered. Set
`DELTA_VIEW=/path/to/delta_view` in the environment to point it at a build
that is not installed under `/opt`.

## Building the package

`packaging/make_deb.sh` produces the `.deb` from a release build; see the
README. The desktop entry it writes uses `Exec=/opt/delta_view/delta_view %F`
and declares `inode/directory` and `text/plain`, which is what makes the
*Open With* route above work.
