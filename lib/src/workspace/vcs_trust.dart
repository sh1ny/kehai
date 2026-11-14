part of 'vcs_collector.dart';

const int _maximumVcsBindingUnits = 16384;
const String _invalidVcsBinding = 'Invalid inherited VCS trust binding.';

typedef _VcsRepositorySelection = ({
  String repository,
  String? backend,
  String? markerKind,
});

typedef _VcsTrustBinding = ({
  String workspace,
  _VcsRepositorySelection selection,
});

/// Invocation authority for one startup repository selection.
///
/// The binding cannot change. An observed mismatch only revokes authority;
/// neither configuration nor admitted observations can restore it.
final class VcsTrust {
  VcsTrust._(this._binding);

  /// Grants authority explicitly for [root] and the selected [backend].
  ///
  /// Callers must obtain authorization before calling this factory. A managed
  /// child supplies the parent's [inheritedBinding] rather than binding afresh.
  /// Invalid or foreign-workspace data throws a bounded [FormatException].
  factory VcsTrust.grant({
    required String root,
    String backend = 'auto',
    String? inheritedBinding,
  }) {
    final inherited = inheritedBinding == null
        ? null
        : _decodeVcsTrustBinding(inheritedBinding);
    final workspace = _canonicalVcsWorkspace(root);
    if (inherited != null && inherited.workspace != workspace) {
      throw const FormatException(_invalidVcsBinding);
    }
    final selection = _selectVcsRepository(workspace, backend);
    final trust = VcsTrust._(
      inherited ?? (workspace: workspace, selection: selection),
    );
    trust._allows(selection, workspace: workspace);
    return trust;
  }

  /// The shared denied authority used when no startup grant was supplied.
  static final VcsTrust untrusted = VcsTrust._(null);

  final _VcsTrustBinding? _binding;
  bool _revoked = false;

  bool get _canStart => !_revoked && _binding?.selection.backend != null;

  bool _allows(_VcsRepositorySelection selection, {required String workspace}) {
    final binding = _binding;
    if (binding == null || _revoked) return false;
    if (binding.workspace != workspace || binding.selection != selection) {
      _revoked = true;
      return false;
    }
    return selection.backend != null;
  }

  /// Encodes the original binding for a still-authorized child in [root].
  ///
  /// Returns `null` when denied or revoked. The child must also receive an
  /// explicit startup grant; this payload alone is never authority.
  String? childBinding({required String root, required String backend}) {
    final binding = _binding;
    if (binding == null || !_canStart) return null;
    final workspace = _canonicalVcsWorkspace(root);
    if (!_allows(
      _selectVcsRepository(workspace, backend),
      workspace: workspace,
    )) {
      return null;
    }
    final encoded = jsonEncode({
      'version': 1,
      'workspace': binding.workspace,
      'repository': binding.selection.repository,
      'backend': binding.selection.backend,
      'markerKind': binding.selection.markerKind,
    });
    if (encoded.length > _maximumVcsBindingUnits) {
      throw const FormatException('Inherited VCS trust binding is too large.');
    }
    return encoded;
  }
}

String _canonicalVcsWorkspace(String root) =>
    p.normalize(realPath(root) ?? p.absolute(root));

_VcsRepositorySelection _selectVcsRepository(String root, String backend) {
  if (backend != 'auto' &&
      backend != 'git' &&
      backend != 'jj' &&
      backend != 'none') {
    throw ArgumentError.value(backend, 'backend', 'Invalid VCS backend.');
  }
  if (backend == 'none') {
    return (
      repository: p.normalize(p.absolute(root)),
      backend: null,
      markerKind: null,
    );
  }
  final repository = p.normalize(projectRoot(root));
  final jjKind = _vcsMarkerKind(repository, '.jj');
  final gitKind = _vcsMarkerKind(repository, '.git');
  final selected = backend == 'auto'
      ? jjKind != null
            ? 'jj'
            : gitKind != null
            ? 'git'
            : null
      : (backend == 'jj' ? jjKind : gitKind) == null
      ? null
      : backend;
  return (
    repository: repository,
    backend: selected,
    markerKind: selected == 'jj'
        ? jjKind
        : selected == 'git'
        ? gitKind
        : null,
  );
}

String? _vcsMarkerKind(String repository, String marker) =>
    switch (FileSystemEntity.typeSync(
      p.join(repository, marker),
      followLinks: false,
    )) {
      FileSystemEntityType.notFound => null,
      FileSystemEntityType.directory => 'directory',
      FileSystemEntityType.file => 'file',
      FileSystemEntityType.link => 'link',
      _ => 'other',
    };

_VcsTrustBinding _decodeVcsTrustBinding(String encoded) {
  if (encoded.length > _maximumVcsBindingUnits) {
    throw const FormatException('Inherited VCS trust binding is too large.');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(encoded);
  } on FormatException {
    throw const FormatException(_invalidVcsBinding);
  }
  if (decoded is Map<String, Object?> && decoded.length == 5) {
    if (decoded case {
      'version': final int version,
      'workspace': final String workspace,
      'repository': final String repository,
      'backend': final String? backend,
      'markerKind': final String? markerKind,
    }) {
      final validSelection = switch ((backend, markerKind)) {
        (null, null) => true,
        ('git' || 'jj', 'directory' || 'file' || 'link' || 'other') => true,
        _ => false,
      };
      if (version == 1 &&
          validSelection &&
          _isVcsBindingPath(workspace) &&
          _isVcsBindingPath(repository)) {
        return (
          workspace: workspace,
          selection: (
            repository: repository,
            backend: backend,
            markerKind: markerKind,
          ),
        );
      }
    }
  }
  throw const FormatException(_invalidVcsBinding);
}

bool _isVcsBindingPath(String path) =>
    path.isNotEmpty &&
    !path.contains('\u0000') &&
    p.isAbsolute(path) &&
    p.normalize(path) == path;
