/// Where a workspace's sessions live on disk (design D13).
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../permissions/workspace_paths.dart';
import '../session/journal.dart';

/// The canonical form of [workspace]: its real path, canonicalized.
String canonicalWorkspace(String workspace) =>
    p.canonicalize(realPath(workspace) ?? p.absolute(workspace));

/// The directory key of [workspace]: the first 16 hex digits of the SHA-256 of
/// its canonical path.
String workspaceKey(String workspace) => sha256
    .convert(utf8.encode(canonicalWorkspace(workspace)))
    .toString()
    .substring(0, 16);

/// The directory holding the sessions of [workspace] under the Kehai [home].
Directory sessionsDirFor(String home, String workspace) =>
    Directory(p.join(home, 'sessions', workspaceKey(workspace)));

/// The session directory with the largest id under [sessions], or null.
///
/// Ids start with a UTC timestamp, so the largest name is the latest session.
/// Only directories holding a journal count.
Directory? latestSession(Directory sessions) {
  if (!sessions.existsSync()) return null;
  Directory? latest;
  for (final entry in sessions.listSync(followLinks: false)) {
    if (entry is! Directory) continue;
    if (!File(p.join(entry.path, journalFileName)).existsSync()) continue;
    if (latest == null ||
        p.basename(entry.path).compareTo(p.basename(latest.path)) > 0) {
      latest = entry;
    }
  }
  return latest;
}

/// Whether [id] is one plain path segment that can name a session.
bool isSessionId(String id) =>
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$').hasMatch(id) && !id.contains('..');
