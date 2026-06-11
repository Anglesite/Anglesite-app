import Testing

/// Root suite for all App Intents tests. `.serialized` ensures children (each intent suite)
/// run sequentially — `AppDependencyManager.shared` and `WindowRouter.shared` are global mutable
/// state and parallel execution would race.
@Suite("AppIntents", .serialized)
struct AppIntentsTests {}
