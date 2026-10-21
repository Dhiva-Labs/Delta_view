# DeltaView in the Microsoft Store

DeltaView reaches the Store as an MSIX bundle that CI builds on every run:
`DeltaView-<version>.msixbundle`, holding `DeltaView-<version>-x64.msix` and
`DeltaView-<version>-arm64.msix`. The packages are unsigned; the Store signs
them when it publishes. Publishing a GitHub release attaches all three files to
it, next to the installers and `.deb` files.

The packaging lives in `packaging/windows/msix/`:

| File | What |
| --- | --- |
| `AppxManifest.xml.in` | the package manifest: identity, the `delta-view` alias, capabilities |
| `build-msix.ps1` | packs one architecture from `flutter build windows --release` |
| `bundle-msix.ps1` | combines the x64 and arm64 packages into the bundle |
| `common.ps1` | helpers both scripts and CI use |
| `Assets/`, `store-logos/` | tile, taskbar and Store images, from `make-assets.py` |
| `store-listing.md` | everything to paste into Partner Center |

## Once: reserve the name and check the identity

1. In [Partner Center](https://partner.microsoft.com/dashboard/apps-and-games/overview),
   choose **Apps and games → New product → MSIX or PWA app** and reserve the
   name **DeltaView**. If it is taken, reserve another and change both
   `DisplayName` values in `AppxManifest.xml.in` to it: the package's display
   name has to be a name reserved for the product.
2. Open the product's **Product management → Product identity** page. It shows
   three values for the package manifest:

   | Partner Center | DeltaView default |
   | --- | --- |
   | Package/Identity/Name | `Dhiva-Labs.DeltaView` |
   | Package/Identity/Publisher | `CN=0F69015A-AA5B-431D-970A-165099309E53` |
   | Package/Properties/PublisherDisplayName | `Dhiva-Labs` |

   The publisher values are the same as for the other Dhiva Labs apps. The
   name is the one most likely to differ. If any value differs, change its
   default in the `param(...)` block at the top of
   `packaging/windows/msix/build-msix.ps1` (`$Name`, `$Publisher`,
   `$PublisherDisplayName`), and nothing else: CI and the bundle take the
   identity from there. A package whose identity does not match is rejected
   when you upload it.
3. Fill in the product's pages from
   [`store-listing.md`](../packaging/windows/msix/store-listing.md):
   **Pricing and availability**, **Properties** (category, privacy policy,
   website, support contact, product declarations), **Age ratings**, and the
   **Store listing** with screenshots and the Store logos from
   `packaging/windows/msix/store-logos/`. The privacy policy URL points to
   `PRIVACY.md` on `main`, so it must be merged before you submit.

## Every release: upload the bundle

1. Release as usual: `version:` in `pubspec.yaml` is the version, and the
   package version is that with a fourth field of 0 (`1.1.0+3` becomes
   `1.1.0.0`; the Store keeps the fourth field for itself). Every Store
   update needs a higher version than the last one submitted.
2. Publish the GitHub release. The **Desktop builds** workflow attaches
   `DeltaView-<version>.msixbundle` (for an existing release, run the workflow
   by hand with its tag in `release_tag`). Download the bundle.
3. In Partner Center, open DeltaView and create a submission (**Start your
   submission** the first time, **Update** after that).
4. **Packages**: upload the `.msixbundle`. Partner Center reads the identity,
   version and the two architectures from it. On an update the previous
   bundle may stay in the list or be removed; Windows installs the highest
   version.
5. **Submission options**: the first time, Partner Center asks why the package
   needs the restricted capability `runFullTrust`. Paste the justification
   from `store-listing.md`, and the certification notes there as **Notes for
   certification**.
6. **Store listing**: update **What's new in this version**.
7. **Submit to the Store.** Certification usually takes up to three business
   days; Partner Center emails the result.

## Notes

- **Visual C++ runtime.** A Flutter app needs the Visual C++ runtime
  (`vcruntime140.dll`, `msvcp140.dll` and their siblings). `build-msix.ps1`
  copies the runtime DLLs of the Visual Studio that compiled `delta_view.exe`
  into the package, next to the exe, so the app runs on a PC that has no
  Visual C++ Redistributable, whether it came from the Store or was installed
  by hand. The package does not declare the
  `Microsoft.VCLibs.140.00.UWPDesktop` framework instead: Microsoft updates
  that framework less often than Visual Studio, a packaged app loads it in
  place of any newer runtime on the PC, and a program must not run on a
  runtime older than the compiler that built it (Visual Studio 2022 17.10
  changed `std::mutex` in a way that crashes on older runtimes). A
  sideloaded package would also need the framework installed first. CI checks
  that the installed app loads the runtime from its own package.
- **The `delta-view` command.** The package declares the app execution alias
  `delta-view.exe`, so the commands in [command-line.md](command-line.md)
  work in a terminal once DeltaView is installed from the Store. Windows
  lists it under **Settings → Apps → Advanced app settings → App execution
  aliases**.
- **App data.** Packaged, DeltaView keeps its settings in its own folder
  under `%LOCALAPPDATA%\Packages`, and Windows deletes them when the app is
  uninstalled. They are separate from those of the installer edition.
- **What CI checks.** The Windows jobs pack the Store package with the real
  identity, check its manifest, architecture and contents, then pack a copy
  with a test identity, sign it with a throwaway certificate, install it with
  `Add-AppxPackage`, start it through `delta-view.exe` with two folders, wait
  for its window and uninstall it. The bundle job combines both architectures.
- **Building by hand** on a Windows PC with Flutter, Visual Studio (C++ desktop
  workload) and the Windows SDK:

  ```powershell
  flutter build windows --release
  .\packaging\windows\msix\build-msix.ps1      # dist\DeltaView-<version>-<arch>.msix
  ```

  It packs the architecture of the PC it runs on. With both packages in
  `dist`, `bundle-msix.ps1 -Packages <x64.msix>, <arm64.msix>` makes the
  bundle. To install a package locally it must be signed: follow the
  "Install a test-signed copy of the Store package" step in
  `.github/workflows/desktop.yml`.
- **New images.** After changing `assets/brand/delta_view.svg`, run
  `python3 packaging/windows/msix/make-assets.py` (needs `cairosvg` and
  `Pillow`) and commit the PNGs it writes.
