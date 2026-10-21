# Publishing DeltaView to the Launchpad PPA

DeltaView ships in the Dhiva Labs PPA next to the other apps:

```bash
sudo add-apt-repository ppa:dhiva-labs/apps
sudo apt update
sudo apt install delta-view
```

The package is called `delta-view`, like the `.deb` on GitHub releases, and
installs the same files (`/opt/delta_view`, `/usr/bin/delta-view`), so one
replaces the other cleanly.

## What is in the source package

Launchpad's builders have no network access, so everything the build needs is
inside the source package:

- `packaging/vendor/flutter-3.44.6-linux-slim.tar.xz`: the Flutter SDK, the
  same file Secure Shell Go vendors.
- `packaging/vendor/pub-cache-3.44.6.tar.xz`: the pub.dev packages that
  `pubspec.lock` names.

Both are ignored by git; `packaging/vendor/README` says how they are made.
Rebuild the pub cache tarball whenever `pubspec.lock` changes, and both when
the Flutter version changes. `debian/rules` builds offline from them; its
comments record the failures each step prevents.

## Releasing a version

1. Add an entry at the top of `debian/changelog`, e.g. `1.2.0~noble1`, with
   the series (`noble`) and the date.
2. Build the source package from a clean copy (the output lands one folder up):

   ```bash
   dpkg-buildpackage -S -sa -d -k3D8D857AAF4D50E6
   ```

   `-d` skips the local build-dependency check; Launchpad installs them.
   GPG asks for the key's passphrase.
3. Upload:

   ```bash
   dput dhiva-apps ../delta-view_<version>_source.changes
   ```

4. Launchpad builds amd64 in 15 to 30 minutes:
   <https://launchpad.net/~dhiva-labs/+archive/ubuntu/apps/+packages>

A version can be uploaded only once. If a build fails, fix it and upload the
next revision (`~noble2`).

## Rehearse before uploading

Build the binary package in a container with no network, as Launchpad does.
This is how 1.1.0~noble1 was checked before its upload:

```bash
lxc launch ubuntu:24.04 ppa-test
lxc file push ../delta-view_<version>.dsc ../delta-view_<version>.tar.xz ppa-test/root/
lxc exec ppa-test -- sh -c 'apt-get update && apt-get install -y dpkg-dev && cd /root && apt-get build-dep -y ./delta-view_<version>.dsc'
lxc config device add ppa-test eth0 none        # cut the network
lxc exec ppa-test -- sh -c 'cd /root && dpkg-source -x delta-view_<version>.dsc && cd delta-view-<version> && dpkg-buildpackage -b -us -uc'
lxc delete --force ppa-test
```

## arm64 and other Ubuntu releases

Only amd64 is built: the vendored SDK carries the x64 engine. arm64 needs an
arm64 SDK tarball and `Architecture: amd64 arm64` in `debian/control`;
`debian/rules` already picks the bundle folder by architecture.

Each upload targets the series in the top changelog entry (`noble`). For
another series, add an entry such as `1.1.0~jammy1 jammy` and upload again.
