/// A small glob matcher in rg's glob syntax (design D6).
///
/// `*` stays inside a path segment, `**` spans segments (`**/` at the start of
/// a pattern or after a `/` also matches zero segments), `?` is one character
/// that is not `/`, `[...]` is a class (`!` or `^` negates, `a-z` ranges),
/// `{a,b}` alternates and `\` escapes. Matching is case-sensitive, as rg's is.
library;

/// A glob over `/`-separated paths relative to a search root.
///
/// A glob without a `/` matches the basename at any depth; one with a `/` is
/// anchored to the root.
final class GlobMatcher {
  /// Compiles [glob].
  GlobMatcher(this.glob) : _regex = _compile(glob);

  /// The glob as given.
  final String glob;

  final RegExp _regex;

  /// Whether the relative path [path] (with `/` separators) matches.
  bool matches(String path) => _regex.hasMatch(path);
}

RegExp _compile(String glob) {
  var pattern = glob;
  final anchored = pattern.contains('/');
  if (pattern.startsWith('/')) pattern = pattern.substring(1);
  final out = StringBuffer(anchored ? '^' : r'^(?:.*/)?');
  final braces = _balanced(pattern);
  var depth = 0;
  for (var i = 0; i < pattern.length; i++) {
    final c = pattern[i];
    switch (c) {
      case r'\':
        if (i + 1 < pattern.length) {
          out.write(RegExp.escape(pattern[++i]));
        } else {
          out.write(r'\\');
        }
      case '*':
        if (i + 1 < pattern.length && pattern[i + 1] == '*') {
          final first = i;
          while (i + 1 < pattern.length && pattern[i + 1] == '*') {
            i++;
          }
          final atStart = first == 0 || '/{,'.contains(pattern[first - 1]);
          final slashNext = i + 1 < pattern.length && pattern[i + 1] == '/';
          final atEnd =
              i + 1 == pattern.length || '},'.contains(pattern[i + 1]);
          if (atStart && slashNext) {
            out.write('(?:.*/)?');
            i++;
          } else if (atStart && atEnd) {
            out.write('.*');
          } else {
            out.write('[^/]*');
          }
        } else {
          out.write('[^/]*');
        }
      case '?':
        out.write('[^/]');
      case '[':
        final close = _classEnd(pattern, i);
        if (close < 0) {
          out.write(r'\[');
        } else {
          out.write(_class(pattern.substring(i + 1, close)));
          i = close;
        }
      case '{' when braces:
        depth++;
        out.write('(?:');
      case '}' when braces && depth > 0:
        depth--;
        out.write(')');
      case ',' when braces && depth > 0:
        out.write('|');
      default:
        out.write(RegExp.escape(c));
    }
  }
  out.write(r'$');
  return RegExp(out.toString(), dotAll: true);
}

/// Whether the braces of [pattern] pair up, ignoring escaped ones.
bool _balanced(String pattern) {
  var depth = 0;
  for (var i = 0; i < pattern.length; i++) {
    final c = pattern[i];
    if (c == r'\') {
      i++;
    } else if (c == '{') {
      depth++;
    } else if (c == '}') {
      if (--depth < 0) return false;
    }
  }
  return depth == 0;
}

/// The index of the `]` that closes the class opened at [open], or -1.
int _classEnd(String pattern, int open) {
  var i = open + 1;
  if (i < pattern.length && '!^'.contains(pattern[i])) i++;
  // A `]` right after the opening is a member.
  if (i < pattern.length && pattern[i] == ']') i++;
  while (i < pattern.length) {
    if (pattern[i] == ']') return i;
    i++;
  }
  return -1;
}

String _class(String body) {
  var negate = false;
  var members = body;
  if (members.isNotEmpty && '!^'.contains(members[0])) {
    negate = true;
    members = members.substring(1);
  }
  final escaped = members
      .replaceAll(r'\', r'\\')
      .replaceAll('[', r'\[')
      .replaceAll('^', r'\^');
  return negate ? '[^$escaped/]' : '[$escaped]';
}
