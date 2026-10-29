/// Kehai engine library: session tree, journal, result store, the model
/// provider interface and the OpenAI sign-in.
library;

export 'src/session/errors.dart';
export 'src/session/path.dart';
export 'src/session/record.dart';
export 'src/session/tree.dart';
export 'src/session/fork.dart' show ForkResult;
export 'src/session/journal.dart';
export 'src/session/materialize.dart';
export 'src/session/migration.dart';
export 'src/session/ownership.dart'
    show OwnershipHooks, OwnershipPause, Takeover;
export 'src/session/requests.dart';
export 'src/session/state.dart';
export 'src/session/writer.dart';
export 'src/results/composer.dart';
export 'src/results/descriptor.dart';
export 'src/results/line_scanner.dart';
export 'src/results/live_result.dart' show LiveResult;
export 'src/results/reader.dart';
export 'src/results/search.dart';
export 'src/results/handles.dart';
export 'src/results/result_store.dart';
export 'src/config/user_config.dart';
export 'src/provider/provider.dart';
export 'src/provider/chatgpt_adapter.dart' show ChatGptAdapter;
export 'src/auth/failure_text.dart' show FailureKind;
export 'src/auth/auth_failure.dart' show AuthFailure;
export 'src/auth/credential_backend.dart' show CredentialBackend;
export 'src/auth/credential_error.dart' show CredentialStoreError;
export 'src/auth/credential_store.dart'
    show
        CredentialLock,
        CredentialRecord,
        CredentialRegistration,
        CredentialStore,
        CredentialTokens;
export 'src/auth/refresher.dart' show Credentials, Refresher;
export 'src/auth/login_controller.dart' show LoginFailure;
export 'src/auth/browser_login.dart'
    show BrowserLauncher, BrowserLogin, LoginResult;
export 'src/auth/logout.dart' show logoutOpenAi;
export 'src/tools/roster.dart' show ToolDefinition, toolDefinitions;
export 'src/tools/runtime.dart';
export 'src/tools/schema.dart' show parseArguments, validateArguments;
export 'src/tools/tool.dart';
export 'src/tools/atomic_write.dart' show FileWriteSeams, RenameFile;
export 'src/tools/edit.dart' show EditTool;
export 'src/tools/read.dart'
    show ReadSeams, ReadSource, ReadSourceOpener, ReadTool;
export 'src/tools/bash.dart' show BashTool, defaultForegroundBudget;
export 'src/tools/job_tool.dart' show JobTool, defaultJobWait;
export 'src/tools/write.dart' show WriteTool;
export 'src/tools/search.dart'
    show
        FindTool,
        GrepTool,
        LsTool,
        RgFound,
        RgMissing,
        RgResolution,
        resolveRg;
export 'src/tools/ask.dart'
    show Answerer, AskTool, PromptChannel, PromptItem, PromptKind, askRules;
export 'src/permissions/credentials.dart'
    show isCredentialPath, isCredentialTarget;
export 'src/permissions/gate.dart' show PermissionGate;
export 'src/permissions/workspace_paths.dart' show isInside, realPath;
export 'src/shell/proof.dart' show ProvenCommand, proveReadOnly, tokenizeSimple;
export 'src/shell/detect.dart'
    show ShellDetection, ShellInfo, ShellKind, detectShell;
export 'src/shell/direct_exec.dart'
    show
        DirectExecRefused,
        DirectResult,
        resolveProgram,
        runDirect,
        startDirect;
export 'src/shell/launch.dart'
    show ShellProcess, shellArguments, startProcess, startShell;
export 'src/jobs/supervisor.dart';
