/// How DeltaView names an SSH server and an account on it, so the
/// known-hosts store, saved connections and the credential cache all agree.
library;

/// [host] as a lookup key: trimmed, lower-case, without the brackets an
/// IPv6 address may be written with.
String normalizeHost(String host) {
  var h = host.trim().toLowerCase();
  if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
  return h;
}

/// `user@host:port`, with the port always present.
String accountKey(
        {required String username, required String host, required int port}) =>
    '$username@${normalizeHost(host)}:$port';

/// `host` or `host:port` (port shown only when it is not 22), bracketing
/// IPv6 addresses that need it.
String displayAddress(String host, int port) {
  final h = normalizeHost(host);
  if (port == 22) return h;
  return h.contains(':') ? '[$h]:$port' : '$h:$port';
}
