/// Which files are Kehai credential files (design D6, D13).
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'workspace_paths.dart';

/// The name prefix of every credential file in the Kehai home: the records
/// (`auth.json`, `auth.dpapi`), `auth.lock` and the backends' temporary files
/// `auth.<x>.<pid>_<n>.tmp`.
const String credentialPrefix = 'auth.';

/// Whether [resolvedPath] is a credential file of the Kehai home [kehaiHome].
///
/// A credential file is a file directly in the home whose name starts with
/// `auth.`. Both paths must be real paths (see `realPath`). The name is
/// compared ignoring case on Windows, where the file system does.
bool isCredentialPath(String resolvedPath, String kehaiHome) {
  var name = p.basename(resolvedPath);
  if (p.style == p.Style.windows) name = name.toLowerCase();
  return name.startsWith(credentialPrefix) &&
      p.equals(p.dirname(resolvedPath), kehaiHome);
}

/// Whether the absolute [path] names a credential file of [kehaiHome].
///
/// Both its resolved path and its lexical form are checked. The resolved path
/// catches a link to a credential file; the lexical form catches a credential
/// name whose directory cannot be resolved. The gate and the file tools use
/// this one rule.
bool isCredentialTarget(String path, Directory kehaiHome) {
  final home = realPath(kehaiHome.path) ?? kehaiHome.absolute.path;
  final real = realPath(path);
  return isCredentialPath(p.normalize(path), home) ||
      (real != null && isCredentialPath(real, home));
}
