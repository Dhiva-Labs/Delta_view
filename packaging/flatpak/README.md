# Flatpak

`com.dhivalabs.delta_view.yml` packages the files the `.deb` installs as a
Flatpak on the GNOME 51 runtime, so the Flatpak runs the same binary as every
other Linux format.

## How CI builds it

The `flatpak` job in `.github/workflows/desktop.yml`, on x86_64 and aarch64:

1. takes the installed tree of that architecture's `.deb` from the `distros`
   job and unpacks it into `packaging/flatpak/tree/` (ignored by git);
2. builds the manifest with `flatpak/flatpak-github-actions/flatpak-builder`
   in Flathub's builder image and exports
   `delta-view-<version>-<arch>.flatpak`, with Flathub as the runtime repo;
3. runs `smoke.sh`: installs the bundle with `flatpak install --user`, runs
   ldd on every ELF file inside the sandbox, prints `--version`, then opens
   a folder in `$HOME` against one in `/tmp` and checks that the app found
   both (they land in its recent list) and drew its window (colours in
   Xvfb's framebuffer, read by `xwd-colours.py`).

The bundle is attached to releases next to the other packages. Install it
with:

```sh
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user ./delta-view-<version>-<arch>.flatpak
flatpak run com.dhivalabs.delta_view
```

## Permissions

- `--filesystem=home`, `/media`, `/run/media`: DeltaView compares paths, not
  single picked files (path fields, command line, recent list, folder
  watching, merges and syncs saved in place, `~/.ssh/known_hosts`), so the
  file chooser portal is not enough. Same as the snap's `home` and
  `removable-media` plugs.
- `--filesystem=/tmp`: `git difftool` writes its temporary files there.
- `--share=network`: SFTP.
- "Open in file manager" and the About links use `xdg-open`, which inside the
  sandbox goes through the OpenURI portal; no extra permission.

## Submitting to Flathub

Not done; the user decides. A Flathub submission would differ:

- the `tree` dir source becomes the release `.deb` of each architecture (a
  `type: file` source with `only-arches`, url and sha256, unpacked with
  `bsdtar` in the build commands), or a build from source with the Flutter
  SDK as a module;
- `<releases>` in the metainfo must list the new version each release, and
  Flathub wants screenshots and an `x-checker-data` entry;
- the broad filesystem permissions above need a justification in the
  submission.
