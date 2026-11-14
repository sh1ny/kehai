import 'dart:io';

import 'package:kehai/kehai.dart' show realPath;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'session_support.dart' show tempDir;

/// A real Git workspace with observable, identity-preserving configured programs.
final class ConfiguredVcsWorkspace {
  ConfiguredVcsWorkspace._(
    this.workspace,
    this.monitorMarker,
    this.filterMarker,
    this.environment,
  );

  /// Creates an initialized dirty repository without running either program.
  static Future<ConfiguredVcsWorkspace> create() async {
    final temporary = await tempDir();
    final physical = realPath(temporary.path)!;
    final workspace = Directory(p.join(physical, 'workspace'))..createSync();
    final emptyGlobal = File(p.join(physical, 'empty.gitconfig'))
      ..writeAsStringSync('');
    final environment = Map<String, String>.of(Platform.environment)
      ..removeWhere((key, _) => key.toUpperCase().startsWith('GIT_'))
      ..['GIT_CONFIG_NOSYSTEM'] = '1'
      ..['GIT_CONFIG_GLOBAL'] = emptyGlobal.path
      ..['GIT_TERMINAL_PROMPT'] = '0';
    final fixture = ConfiguredVcsWorkspace._(
      workspace,
      File(p.join(physical, 'fsmonitor-marker.txt')),
      File(p.join(physical, 'filter-marker.txt')),
      Map.unmodifiable(environment),
    );
    await fixture.git(['init', '--initial-branch=main']);
    for (final (key, value) in [
      ('user.name', 'Nikolay Bochev'),
      ('user.email', '309868+sh1ny@users.noreply.github.com'),
      ('commit.gpgsign', 'false'),
      ('core.autocrlf', 'false'),
      ('core.hooksPath', '/dev/null'),
    ]) {
      await fixture.git(['config', key, value]);
    }
    fixture.tracked.writeAsStringSync('baseline\n');
    File(p.join(workspace.path, '.gitattributes'))
        .writeAsStringSync('tracked.txt filter=kehai-trust\n');
    final attributes = File(
      p.join(workspace.path, '.git', 'info', 'attributes'),
    );
    attributes.parent.createSync(recursive: true);
    attributes.writeAsStringSync('* -filter\ntracked.txt filter=kehai-trust\n');
    await fixture.git(['add', '--all']);
    await fixture.git([
      'commit',
      '--no-gpg-sign',
      '-m',
      'test: initialize configured-program fixture',
      '-m',
      'Co-authored-by: KintsugiBot <296966193+KintsugiBot@users.noreply.github.com>',
    ]);
    fixture.tracked.writeAsStringSync('initial dirty content\n');
    await fixture.git([
      'config',
      'filter.kehai-trust.clean',
      'cat; printf filter >> ${_shellLiteral(fixture.filterMarker.path)}; :',
    ]);
    await fixture.git(['config', 'filter.kehai-trust.required', 'true']);
    await fixture.git(['config', 'core.fsmonitorHookVersion', '2']);
    await fixture.git([
      'config',
      'core.fsmonitor',
      'printf monitor >> ${_shellLiteral(fixture.monitorMarker.path)}; '
          "printf 'token\\0/\\0'; :",
    ]);
    return fixture;
  }

  /// The canonical workspace directory.
  final Directory workspace;

  /// The out-of-repository fsmonitor execution marker.
  final File monitorMarker;

  /// The out-of-repository clean-filter execution marker.
  final File filterMarker;

  /// The fixture-only Git environment, isolated from inherited routing/config.
  final Map<String, String> environment;

  /// The tracked file whose clean conversion preserves its bytes.
  File get tracked => File(p.join(workspace.path, 'tracked.txt'));

  /// Runs a fixture setup command without inheriting other Git routing.
  Future<void> git(List<String> arguments) async {
    final result = await Process.run(
      'git',
      arguments,
      workingDirectory: workspace.path,
      environment: environment,
      includeParentEnvironment: false,
    );
    expect(
      result.exitCode,
      0,
      reason: 'git ${arguments.join(' ')}: ${result.stderr}',
    );
  }

  /// Removes only this fixture's program markers between observed phases.
  void clearMarkers() {
    for (final marker in [monitorMarker, filterMarker]) {
      if (marker.existsSync()) marker.deleteSync();
    }
  }
}

String _shellLiteral(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";
