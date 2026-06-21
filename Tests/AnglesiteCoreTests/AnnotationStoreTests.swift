// Tests/AnglesiteCoreTests/AnnotationStoreTests.swift
import Testing
import Foundation
@testable import AnglesiteCore

/// Native port of `server/annotations.mjs` — load/save/add/list/resolve over
/// `<projectRoot>/annotations.json`. These tests pin the behavior to the Node source it replaces.
@Suite("AnnotationStore")
struct AnnotationStoreTests {

    private func makeRoot() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("annotation-store-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private let now = Date(timeIntervalSince1970: 1_750_000_000) // 2025-06-15T15:06:40Z

    @Test("add persists a new unresolved annotation and returns it")
    func addPersists() throws {
        let root = makeRoot()
        let a = try AnnotationStore.add(
            in: root, path: "/about", selector: "h1", text: "tighter tone", sourceFile: nil, now: now
        )
        #expect(a.path == "/about")
        #expect(a.selector == "h1")
        #expect(a.text == "tighter tone")
        #expect(a.resolved == false)
        #expect(a.resolvedAt == nil)
        #expect(a.sourceFile == nil)
        #expect(a.createdAt == now)
        #expect(a.id.count == 8)

        // Persisted and reloadable.
        let loaded = AnnotationStore.load(in: root)
        #expect(loaded.count == 1)
        #expect(loaded[0].id == a.id)
    }

    @Test("list excludes resolved and filters by path")
    func listFilters() throws {
        let root = makeRoot()
        let home = try AnnotationStore.add(in: root, path: "/", selector: "#hero", text: "a", sourceFile: nil, now: now)
        _ = try AnnotationStore.add(in: root, path: "/about", selector: "h1", text: "b", sourceFile: nil, now: now)
        let toResolve = try AnnotationStore.add(in: root, path: "/", selector: ".x", text: "c", sourceFile: nil, now: now)
        _ = try AnnotationStore.resolve(in: root, id: toResolve.id, now: now)

        // Default: only unresolved, all paths.
        let all = AnnotationStore.list(in: root)
        #expect(all.count == 2)
        #expect(all.allSatisfy { !$0.resolved })

        // Path filter.
        let homeOnly = AnnotationStore.list(in: root, path: "/")
        #expect(homeOnly.map(\.id) == [home.id])
    }

    @Test("resolve marks resolved with a timestamp and persists")
    func resolveMarks() throws {
        let root = makeRoot()
        let a = try AnnotationStore.add(in: root, path: "/", selector: "#hero", text: "a", sourceFile: nil, now: now)
        let resolvedAt = now.addingTimeInterval(60)
        let resolved = try AnnotationStore.resolve(in: root, id: a.id, now: resolvedAt)
        #expect(resolved.resolved == true)
        #expect(resolved.resolvedAt == resolvedAt)
        // Persisted: a fresh load reflects the resolution.
        #expect(AnnotationStore.load(in: root).first?.resolved == true)
    }

    @Test("resolve re-stamps resolvedAt on a second call (mirrors the Node store)")
    func resolveReStamps() throws {
        let root = makeRoot()
        let a = try AnnotationStore.add(in: root, path: "/", selector: "#hero", text: "a", sourceFile: nil, now: now)
        _ = try AnnotationStore.resolve(in: root, id: a.id, now: now)
        let later = now.addingTimeInterval(120)
        let second = try AnnotationStore.resolve(in: root, id: a.id, now: later)
        // Deliberate: `annotations.mjs` re-stamps unconditionally, so we do too.
        #expect(second.resolvedAt == later)
    }

    @Test("resolve throws notFound for an unknown id")
    func resolveNotFound() throws {
        let root = makeRoot()
        #expect(throws: AnnotationStore.AnnotationStoreError.notFound("nope")) {
            try AnnotationStore.resolve(in: root, id: "nope", now: now)
        }
    }

    @Test("add throws once the unresolved limit is reached")
    func addLimit() throws {
        let root = makeRoot()
        for i in 0..<50 {
            _ = try AnnotationStore.add(in: root, path: "/", selector: "#\(i)", text: "n", sourceFile: nil, now: now)
        }
        #expect(throws: AnnotationStore.AnnotationStoreError.limitReached(50)) {
            try AnnotationStore.add(in: root, path: "/", selector: "#over", text: "n", sourceFile: nil, now: now)
        }
        // Resolving one frees a slot.
        let id = AnnotationStore.list(in: root).first!.id
        _ = try AnnotationStore.resolve(in: root, id: id, now: now)
        #expect(throws: Never.self) {
            try AnnotationStore.add(in: root, path: "/", selector: "#ok", text: "n", sourceFile: nil, now: now)
        }
    }

    @Test("load tolerates the legacy bare-array format")
    func loadLegacyArray() throws {
        let root = makeRoot()
        let legacy = #"""
        [{"id":"abc12345","path":"/about","selector":"h1","text":"old","resolved":false,"createdAt":"2026-05-24T10:00:00.000Z"}]
        """#
        try Data(legacy.utf8).write(to: root.appendingPathComponent("annotations.json"))
        let loaded = AnnotationStore.load(in: root)
        #expect(loaded.count == 1)
        #expect(loaded[0].id == "abc12345")
        #expect(loaded[0].path == "/about")
    }

    @Test("save writes the exact versioned-wrapper bytes the Node store would")
    func saveByteFaithful() throws {
        let root = makeRoot()
        let annotation = Annotation(
            id: "fixedid0", path: "/about", selector: "h1", sourceFile: nil,
            text: "hello", resolved: false, createdAt: now, resolvedAt: nil
        )
        try AnnotationStore.save([annotation], in: root)
        let written = try String(contentsOf: root.appendingPathComponent("annotations.json"), encoding: .utf8)
        let expected = """
        {
          "version": 1,
          "annotations": [
            {
              "id": "fixedid0",
              "path": "/about",
              "selector": "h1",
              "text": "hello",
              "resolved": false,
              "createdAt": "2025-06-15T15:06:40.000Z"
            }
          ]
        }

        """
        #expect(written == expected)
    }

    @Test("empty annotations serialize to the inline empty array")
    func saveEmpty() throws {
        let root = makeRoot()
        try AnnotationStore.save([], in: root)
        let written = try String(contentsOf: root.appendingPathComponent("annotations.json"), encoding: .utf8)
        #expect(written == "{\n  \"version\": 1,\n  \"annotations\": []\n}\n")
    }

    @Test("string escaping matches JSON.stringify for tricky inputs")
    func escapingFaithful() {
        // (input, expected JSON literal incl. surrounding quotes) — mirrors JSON.stringify.
        let cases: [(String, String)] = [
            ("a\"b", "\"a\\\"b\""),                    // quote
            ("a\\b", "\"a\\\\b\""),                    // backslash
            ("line1\nline2", "\"line1\\nline2\""),     // newline → \n
            ("tab\there", "\"tab\\there\""),           // tab → \t
            ("a/b", "\"a/b\""),                          // forward slash NOT escaped
            ("café ☕️ 日本", "\"café ☕️ 日本\""),         // non-ASCII emitted raw
            ("bell\u{07}", "\"bell\\u0007\""),         // other control → \u00XX
        ]
        for (input, expected) in cases {
            #expect(AnnotationStore.escapeJSONString(input) == expected)
        }
    }
}
