# DeltaView privacy policy

Effective 21 October 2026. This policy covers DeltaView on every platform,
including the Microsoft Store edition.

**DeltaView collects nothing and sends nothing to Dhiva Labs or anyone
else.** There is no account, no analytics or telemetry, no crash reporting,
no advertising and no check for updates. Everything DeltaView remembers stays
on your computer.

## What DeltaView keeps on your computer

- **Settings**: your preferences (appearance, editor, compare rules, ignore
  patterns, keyboard shortcuts, the external editor command), your recent
  comparisons (the paths of the folders, files and archives you compared, and
  the server, user name and path of SFTP locations), the tabs that were open,
  so the next start can restore them, and the window's size and position.
- **Saved SFTP connections**: for each server you connected to, its host name,
  port, your user name, how you sign in (password or key), the path of your
  private key file if you use one, the last folder you opened and when. **Never
  a password or a key passphrase.**
- **Trusted host keys**: for each server whose identity you confirmed, its host
  name, port, key type and SHA-256 fingerprint, and the date you confirmed it.
  A server presenting a different key is refused until you remove the old one.
- **Temporary files**: to open a compressed tar archive, DeltaView may unpack
  it into a scratch file, deleted when the archive is closed (or a day later,
  if DeltaView was interrupted).

Passwords and key passphrases you type are kept in memory only, so that
another comparison on the same server does not ask again. They are forgotten
when DeltaView closes and are never written to disk.

Where these files are:

| | Settings, connections, host keys | Temporary files |
| --- | --- | --- |
| Windows (installer) | `%APPDATA%\com.dhivalabs\DeltaView` | `%LOCALAPPDATA%\DeltaView\Cache` |
| Windows (Microsoft Store) | inside the app's own folder under `%LOCALAPPDATA%\Packages`; Windows deletes it when you uninstall the app | the same |
| Linux | `~/.local/share/com.dhivalabs.delta_view` | `~/.cache/deltaview` |
| macOS | inside DeltaView's sandbox, `~/Library/Containers/com.dhivalabs.deltaView` | the same |

You can clear recent comparisons from the home screen, and forget saved
connections and trusted host keys in the SFTP connect dialog. Deleting the
folders above removes everything.

## What DeltaView reads

- The files and folders you open, and the archives you browse.
- Your private key file, when you connect to a server with one.
- `~/.ssh/known_hosts` (read only), to tell you whether a server's key is one
  your SSH client already trusts.
- The clipboard, only when you ask to compare or paste its text.

DeltaView changes your files only when you tell it to: saving an edit or a
merge, copying changes across, synchronizing folders, or exporting a report.

## Network connections

DeltaView connects only to the SFTP servers you choose, at the address and
port you enter, to list and read files there (and to write them, when you
save, copy or sync to that server). It makes no other connection. The link in
the About dialog opens the project page in your web browser when you click it.

The Microsoft Store edition is installed and updated by the Microsoft Store,
which is covered by Microsoft's privacy statement.

## Changes and contact

Changes to this policy are made in this file, and its history is public in
the [DeltaView repository](https://github.com/Dhiva-Labs/Delta_view). Questions:
reachout@dhivalabs.com.
