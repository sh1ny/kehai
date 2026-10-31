/// The Windows console code page of the line client (design D14).
///
/// A console reads and writes through its code pages, not through Dart's
/// UTF-8 codecs, so the client sets both to UTF-8 while it runs and puts the
/// old ones back on exit. Elsewhere, and when input and output are not a
/// console, nothing changes.
library;

import 'dart:ffi';
import 'dart:io';

/// The code page number of UTF-8.
const int utf8CodePage = 65001;

/// The console code page calls, or a stand-in for them.
abstract interface class ConsoleCodePages {
  /// The input code page, or 0 when there is no console.
  int get input;

  /// The output code page, or 0 when there is no console.
  int get output;

  /// Sets the input code page; returns whether it was set.
  bool setInput(int codePage);

  /// Sets the output code page; returns whether it was set.
  bool setOutput(int codePage);
}

/// Sets the console's code pages to UTF-8 and returns a function that puts
/// the previous ones back. A page that cannot be set is left alone.
void Function() useUtf8Console(ConsoleCodePages pages) {
  final input = pages.input;
  final output = pages.output;
  final changedInput = input != utf8CodePage && pages.setInput(utf8CodePage);
  final changedOutput = output != utf8CodePage && pages.setOutput(utf8CodePage);
  return () {
    if (changedInput) pages.setInput(input);
    if (changedOutput) pages.setOutput(output);
  };
}

/// Sets the code pages of the Windows console that [stdin] or [stdout] is
/// attached to, and returns the function that restores them. A no-op on other
/// platforms and when neither is a console.
void Function() useUtf8ConsoleIfAttached() {
  if (!Platform.isWindows || !_isConsole()) return () {};
  try {
    return useUtf8Console(_Kernel32Pages());
  } on Object {
    // kernel32 cannot be reached; the console keeps its code pages.
    return () {};
  }
}

bool _isConsole() {
  try {
    return stdin.hasTerminal || stdout.hasTerminal;
  } on Object {
    return false;
  }
}

/// The code page calls of `kernel32.dll`.
final class _Kernel32Pages implements ConsoleCodePages {
  _Kernel32Pages() : _lib = DynamicLibrary.open('kernel32.dll');

  final DynamicLibrary _lib;

  late final int Function() _getInput = _lib
      .lookupFunction<Uint32 Function(), int Function()>('GetConsoleCP');
  late final int Function() _getOutput = _lib
      .lookupFunction<Uint32 Function(), int Function()>('GetConsoleOutputCP');
  late final int Function(int) _setInput = _lib
      .lookupFunction<Int32 Function(Uint32), int Function(int)>(
        'SetConsoleCP',
      );
  late final int Function(int) _setOutput = _lib
      .lookupFunction<Int32 Function(Uint32), int Function(int)>(
        'SetConsoleOutputCP',
      );

  @override
  int get input => _getInput();

  @override
  int get output => _getOutput();

  @override
  bool setInput(int codePage) => _setInput(codePage) != 0;

  @override
  bool setOutput(int codePage) => _setOutput(codePage) != 0;
}
