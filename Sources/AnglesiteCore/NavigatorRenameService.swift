import Foundation

/// The page/post re-title pipeline: load the file, rewrite its title via `PageTitleEditor`, save,
/// then commit best-effort. I/O and git are injected so the flow is unit-testable; the defaults are
/// the real `FileDocumentIO` + `NativeContentOperations.processGitCommit`. Lives in AnglesiteCore
/// (not the app-target model) so `swift test` covers it — the same split as `TokenOnboarding`.
public struct NavigatorRenameService: Sendable {
    public enum RenameError: Error, Equatable {
        case emptyTitle
        case noEditableLocation
        case io(String)
    }

    public typealias GitCommit = NativeContentOperations.GitCommit

    private let loadContents: @Sendable (URL) throws -> String
    private let saveContents: @Sendable (String, URL) throws -> Void
    private let gitCommit: GitCommit

    public init(
        loadContents: @escaping @Sendable (URL) throws -> String = { try FileDocumentIO.load($0).contents },
        saveContents: @escaping @Sendable (String, URL) throws -> Void = { try FileDocumentIO.save($0, to: $1) },
        gitCommit: @escaping GitCommit = NativeContentOperations.processGitCommit
    ) {
        self.loadContents = loadContents
        self.saveContents = saveContents
        self.gitCommit = gitCommit
    }

    public func rename(
        fileURL: URL,
        fileExtension: String,
        projectRoot: URL,
        relativePath: String,
        newTitle: String
    ) async -> Result<String, RenameError> {
        let contents: String
        do { contents = try loadContents(fileURL) }
        catch { return .failure(.io("\(error)")) }

        let rewritten: String
        switch PageTitleEditor.rewrite(contents: contents, fileExtension: fileExtension, newTitle: newTitle) {
        case .success(let s): rewritten = s
        case .failure(.emptyTitle): return .failure(.emptyTitle)
        case .failure(.noEditableLocation): return .failure(.noEditableLocation)
        }

        do { try saveContents(rewritten, fileURL) }
        catch { return .failure(.io("\(error)")) }

        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        // Best-effort: a failed commit (not a repo, rejecting hook, git missing) is ignored —
        // the file is saved and is the source of truth. Mirrors NativeContentOperations.
        _ = await gitCommit(projectRoot, relativePath, "anglesite: rename title to \"\(trimmed)\"")
        return .success(trimmed)
    }
}
