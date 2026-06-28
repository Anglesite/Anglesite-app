// Sources/AnglesiteApp/InspectorContext.swift
import Foundation
import AnglesiteCore

/// Shared surface the inspector chrome (load/save/conflict/⌘S) drives, so one chrome wraps both the
/// typed descriptor form and the plain page metadata form.
@MainActor
protocol InspectorEditorModel: AnyObject {
    var file: FileRef { get }
    var isDirty: Bool { get }
    var loadError: String? { get }
    var isLoading: Bool { get }
    var conflictDiskContents: String? { get set }
    func load() async
    @discardableResult func save() async -> Bool
    func flushBeforeLeaving() async -> Bool
    func checkExternalChange() async
    func keepMyChanges()
    func reloadFromDisk() async
}

/// What the right-hand inspector is editing for the current selection.
@MainActor
enum InspectorContext: Identifiable {
    case typed(TypedEntryEditorModel)
    case page(PageMetadataModel)

    var model: any InspectorEditorModel {
        switch self {
        case .typed(let m): m
        case .page(let m): m
        }
    }
    var id: String { model.file.id }
}
