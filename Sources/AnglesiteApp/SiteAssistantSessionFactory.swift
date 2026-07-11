import Foundation
import AnglesiteCore

/// The per-site assistant/edit bundle that `SiteWindow` installs into the preview session.
@MainActor
struct SiteAssistantSession {
    let chat: ChatModel
    let editObserver: MCPApplyEditRouter.EditObserver
    let editPostProcessor: MCPApplyEditRouter.PostProcessor?
}

/// Builds the cross-cutting assistant surface for one open site: chat, annotations, undo,
/// edit-recording, and best-effort alt-text post-processing.
@MainActor
enum SiteAssistantSessionFactory {
    typealias MCPClientProvider = @Sendable () async -> MCPClient?
    typealias EditRouterProvider = @Sendable (_ siteID: String) async -> (any EditRouter)?
    typealias GraphSnapshotProvider = @Sendable () async -> SiteGraphExplorerSnapshot
    typealias AssistantBuilder = @Sendable (
        _ editBridge: IntentEditBridge,
        _ contentGraph: SiteContentGraph,
        _ knowledgeIndex: SiteKnowledgeIndex,
        _ semanticRanker: SemanticRanker?,
        _ integrationService: any IntegrationOperationsService,
        _ conventionsEngine: ProjectConventionsEngine?,
        _ conventionsStore: ProjectConventionsStore,
        _ themeCatalog: ThemeCatalog?,
        _ graphSnapshotProvider: @escaping GraphSnapshotProvider
    ) -> any ConversationalAssistant

    struct Dependencies {
        var annotationFeed: @Sendable (_ sourceDirectory: URL) -> AnnotationFeed
        var resolveAnnotation: @Sendable (_ sourceDirectory: URL, _ id: String) async throws -> Void
        var undoCommand: @Sendable (_ mcpClient: @escaping MCPClientProvider) -> UndoCommand
        var editRouterProvider: EditRouterProvider
        var assistant: AssistantBuilder
        var altTextGenerator: @Sendable (
            _ siteID: String,
            _ sourceDirectory: URL,
            _ mcpClient: @escaping MCPClientProvider,
            _ conventionsEngine: ProjectConventionsEngine?
        ) -> AltTextGenerator

        static let live: Dependencies = {
            let annotationFeed: @Sendable (URL) -> AnnotationFeed = { sourceDirectory in
                AnnotationFeedFactory.native(directory: sourceDirectory)
            }
            let resolveAnnotation: @Sendable (URL, String) async throws -> Void = { sourceDirectory, id in
                try AnnotationStore.resolve(in: sourceDirectory, id: id)
            }
            let undoCommand: @Sendable (@escaping MCPClientProvider) -> UndoCommand = { mcpClient in
                UndoCommand(mcpClient: mcpClient)
            }
            let editRouterProvider: EditRouterProvider = { siteID in
                await EditRouterRegistry.shared.router(for: siteID)
            }
            let assistant: AssistantBuilder = { editBridge, contentGraph, knowledgeIndex, semanticRanker, integrationService, conventionsEngine, conventionsStore, themeCatalog, graphSnapshotProvider in
                CombinedAugmentedAssistant(
                    base: FoundationModelAssistant(
                        tier: .onDevice,
                        editBridge: editBridge,
                        contentGraph: contentGraph,
                        knowledgeIndex: knowledgeIndex,
                        semanticRanker: semanticRanker,
                        integrationService: integrationService,
                        conventionsEngine: conventionsEngine,
                        conventionsStore: conventionsStore,
                        copyEditAuditor: CopyEditAuditorFactory.makeDefault(),
                        socialMediaPlanner: SocialMediaPlannerFactory.makeDefault(),
                        postRepurposer: PostRepurposerFactory.makeDefault(),
                        themeCatalog: themeCatalog
                    ),
                    index: knowledgeIndex,
                    graphSnapshotProvider: graphSnapshotProvider
                )
            }
            return Dependencies(
                annotationFeed: annotationFeed,
                resolveAnnotation: resolveAnnotation,
                undoCommand: undoCommand,
                editRouterProvider: editRouterProvider,
                assistant: assistant,
                altTextGenerator: { siteID, sourceDirectory, mcpClient, conventionsEngine in
                    AltTextGenerator(
                        siteID: siteID,
                        siteDirectory: sourceDirectory,
                        isEnabled: { AppSettings.shared.autoGenerateAltText },
                        produce: { imageURL, context in
                            let conventions = await conventionsEngine?.conventions(siteID: siteID)
                            let prompt = AltTextPromptBuilder.build(
                                basePrompt: "Generate concise, descriptive alt text for this image as it would appear on a website. If the image is purely decorative, mark it decorative and use empty alt text.",
                                conventions: conventions
                            )
                            return try await FoundationModelAssistant(tier: .onDevice).generateStructured(
                                prompt: prompt,
                                imageURL: imageURL,
                                context: context,
                                resultType: GeneratedAltText.self
                            )
                        },
                        apply: { edit in
                            let reply = await MCPApplyEditRouter(mcpClient: mcpClient).apply(edit)
                            if reply.status == .failed {
                                await LogCenter.shared.append(
                                    source: "alt-text:\(siteID)", stream: .stderr,
                                    text: "applying generated alt text failed: \(reply.message ?? "unknown error")"
                                )
                            }
                        },
                        log: { message in
                            await LogCenter.shared.append(
                                source: "alt-text:\(siteID)", stream: .stderr, text: message)
                        }
                    )
                }
            )
        }()
    }

    static func makeSession(
        siteID: String,
        sourceDirectory: URL,
        configDirectory: URL,
        mcpClient: @escaping MCPClientProvider,
        contentGraph: SiteContentGraph,
        knowledgeIndex: SiteKnowledgeIndex,
        semanticRanker: SemanticRanker?,
        conventionsEngine: ProjectConventionsEngine?,
        integrationService: any IntegrationOperationsService,
        themeCatalog: ThemeCatalog? = nil,
        dependencies: Dependencies = .live,
        graphSnapshotProvider: @escaping GraphSnapshotProvider
    ) -> SiteAssistantSession {
        let editBridge = IntentEditBridge(routerProvider: dependencies.editRouterProvider)
        // A second `ProjectConventionsStore` instance pointed at the same `configDirectory` as
        // `SiteWindowModel`'s Style Guide store (rather than threading that instance through this
        // factory's parameter list) — harmless because all writes now flow through the shared
        // `conventionsEngine` (#465): `BrandVoiceWriter`/`ProjectConventionsModel` only ever persist
        // the engine's merged snapshot to whichever store instance they hold, so a second store
        // pointed at the same `conventions.json` never observes a stale value.
        let conventionsStore = ProjectConventionsStore(configDirectory: configDirectory)
        let chat = ChatModel(
            siteID: siteID,
            siteDirectory: sourceDirectory,
            configDirectory: configDirectory,
            assistant: dependencies.assistant(
                editBridge,
                contentGraph,
                knowledgeIndex,
                semanticRanker,
                integrationService,
                conventionsEngine,
                conventionsStore,
                themeCatalog,
                graphSnapshotProvider
            ),
            annotationFeed: dependencies.annotationFeed(sourceDirectory),
            annotationResolver: { [resolveAnnotation = dependencies.resolveAnnotation] id in
                try await resolveAnnotation(sourceDirectory, id)
            },
            undoCommand: dependencies.undoCommand(mcpClient)
        )

        let altTextGenerator = dependencies.altTextGenerator(siteID, sourceDirectory, mcpClient, conventionsEngine)
        let postProcessor: MCPApplyEditRouter.PostProcessor? = { reply, message in
            await altTextGenerator.postProcess(reply: reply, message: message)
        }

        return SiteAssistantSession(
            chat: chat,
            // The router may retain this observer for the preview lifetime. Capture weakly to avoid
            // a PreviewModel -> editRouter -> observer -> ChatModel cycle; SiteWindow stores the
            // returned chat model immediately, so normal window ownership still keeps it alive.
            editObserver: { [weak chat] reply in
                Task { @MainActor in
                    chat?.recordEdit(reply)
                }
            },
            editPostProcessor: postProcessor
        )
    }
}
