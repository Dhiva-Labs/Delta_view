# Publishing DeltaView to the Snap Store

```bash
sudo snap install delta-view
```

The snap is strictly confined: it can open files in your home folder and on
removable media, and connect to the SFTP servers you choose. Hidden folders in
your home (such as `~/.ssh`) are outside its reach; pick a key file with the
file chooser instead.

## Building

```bash
snapcraft --use-lxd
```

This builds in a throwaway LXD container: the `flutter` plugin clones the
Flutter SDK and runs `flutter build linux --release`, and the `gnome`
extension supplies GTK. The first run takes a while; later ones reuse the
container. It produces `delta-view_<version>_amd64.snap`.

Try it without publishing:

```bash
sudo snap install --dangerous ./delta-view_<version>_amd64.snap
delta-view
sudo snap remove delta-view
```

## Releasing

Bump `version:` in `snap/snapcraft.yaml`, then:

```bash
snapcraft upload --release=stable ./delta-view_<version>_amd64.snap
```

An upload does not touch the store listing. The first time, and whenever the
icon, summary or description change, push them from the snap:

```bash
snapcraft upload-metadata ./delta-view_<version>_amd64.snap
```

Without it the Snap Store shows no logo for the snap. Screenshots, the banner
and the website links are set on <https://snapcraft.io/delta-view/listing>.

The `Snap` workflow (`.github/workflows/snap.yml`) builds amd64 and arm64 on
native runners, installs each and runs it confined, and keeps the snaps as the
`snap-amd64` and `snap-arm64` artifacts. Nothing is published from CI. Upload
the arm64 one from the artifacts to add the architecture to the same channel:

```bash
gh run download <run-id> --repo Dhiva-Labs/Delta_view --name snap-arm64
snapcraft upload --release=stable ./delta-view_<version>_arm64.snap
```

`snapcraft status delta-view` shows what is in each channel.
