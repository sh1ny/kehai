# Hook startup measurements

Design D14 and the `hook-deadlines` spec require the default hook deadline to
be at least 3x the p95 startup of a trivial hook on each shell, and never
below 2 s. `test/hooks/hook_default_test.dart` parses the table below and
checks `defaultHookTimeout` against it.

## Method

- Date: 2026-10-29.
- Host: Windows 11 Pro 10.0.26300 on an Intel Core i7-13700K with 64 GB. The
  Linux rows ran in WSL2 on the same machine (kernel 6.18, 6 vCPUs, 24 GB),
  from a copy of the tree on the WSL ext4 disk. Other agents and editors were
  running, so these are loaded-host numbers, not best cases.
- Tool: `dart run tool/measure_hook_startup.dart 50` (Dart 3.13.7). It
  spawns the shell 50 times in a row with `Process.run`, with the host
  environment, and times each run from spawn to exit. The first run is not
  discarded. p50 and p95 use the nearest-rank method over the 50 runs.
- Commands: `bash -c true` and `pwsh -NoProfile -Command exit`. On Windows
  `bash` is Git for Windows' `bash.exe` as `detectShell` finds it. On Linux it
  is the first `bash` on `PATH`. `pwsh` is PowerShell 7.6.4 on both (on Linux
  installed through mise, not by this task).
- Windows PowerShell 5.1 (`powershell.exe`) is the detection fallback behind
  `pwsh`; it is not measured because it is only used when neither Git Bash nor
  `pwsh` exists.

## Results

| Platform | Shell | Runs | p50 ms | p95 ms |
| --- | --- | --- | --- | --- |
| Windows | git-bash | 50 | 108 | 156 |
| Windows | pwsh | 50 | 642 | 815 |
| Linux | bash | 50 | 5 | 7 |
| Linux | pwsh | 50 | 147 | 209 |

Highest p95: 815 ms (Windows `pwsh`); 3x is 2445 ms.

## Default

The default is the larger of 10 s and 3x the highest p95. Here 3x the highest
p95 is 2.4 s, so the 10 s floor of D14 stands.

Default hook deadline: 10000 ms
