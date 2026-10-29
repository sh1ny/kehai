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
