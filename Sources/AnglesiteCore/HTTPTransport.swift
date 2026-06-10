import Foundation

/// Parses Server-Sent Events framing into the `data:` payloads. MCP Streamable HTTP carries one
/// JSON-RPC message per SSE event. We only need the `data` field; `event:`/`id:`/`retry:` are
/// ignored. A blank line dispatches the accumulated event; a trailing event without a final blank
/// line is still emitted.
enum SSEFrameParser {
    static func dataPayloads(in text: String) -> [String] {
        var payloads: [String] = []
        var dataLines: [String] = []

        func flush() {
            if !dataLines.isEmpty {
                payloads.append(dataLines.joined(separator: "\n"))
                dataLines.removeAll()
            }
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : String(rawLine)
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("data:") {
                let value = line.dropFirst("data:".count)
                dataLines.append(value.hasPrefix(" ") ? String(value.dropFirst()) : String(value))
            }
            // Other fields (event:, id:, retry:, comments starting with ':') are ignored.
        }
        flush()
        return payloads
    }
}
