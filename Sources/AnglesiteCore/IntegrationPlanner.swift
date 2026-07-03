import Foundation

public enum IntegrationPlanner {
    /// Pure: no writes. Reads `global.css` for derived tokens only.
    public static func plan(
        descriptor: IntegrationDescriptor,
        answers: Answers,
        sourceDirectory: URL,
        templateDirectory: URL,
        fileManager: FileManager = .default
    ) -> Result<OperationPlan, IntegrationError> {
        var warnings: [PlanWarning] = []

        // 1. Provider check.
        let providerID = answers["provider"]
        if !descriptor.providers.isEmpty {
            guard let p = providerID, !p.isEmpty else { return .failure(.providerRequired) }
            guard descriptor.providers.contains(where: { $0.id == p }) else {
                return .failure(.unknownProvider(p))
            }
        }

        // 2. Build effective answers: fill field defaults where answer is missing/empty.
        var effective = answers
        for field in descriptor.fields {
            if effective[field.key]?.isEmpty != false, let def = field.defaultValue {
                effective[field.key] = def
            }
        }

        // 3. Validate visible fields using effective answers.
        for field in descriptor.fields where isVisible(field.visibleWhen, answers: effective, providerID: providerID) {
            let value = effective[field.key] ?? ""
            if value.isEmpty {
                if field.isOptional { continue }
                return .failure(.missingRequiredField(key: field.key))
            }
            switch field.kind {
            case .email where !value.contains("@"):
                return .failure(.invalidValue(key: field.key, reason: "not an email address"))
            // Require a host (not just a parseable scheme) so a value like "https:" or
            // "mailto:foo@bar.com" fails here with a clear message, instead of silently
            // producing no CSP entry later for a descriptor that uses addCSPDomains(fromFieldHost:).
            case .url where URL(string: value)?.host == nil:
                return .failure(.invalidValue(key: field.key, reason: "not an absolute URL (needs a host, e.g. https://example.com)"))
            case .choice(let choices) where !choices.contains(where: { $0.value == value }):
                return .failure(.invalidValue(key: field.key, reason: "not one of the allowed choices"))
            default: break
            }
        }

        // 4. Tokens = effective answers + derived inputs.
        var tokens = effective
        if let brand = brandColor(sourceDirectory: sourceDirectory, fileManager: fileManager) {
            tokens["brandColor"] = brand
        } else {
            tokens["brandColor"] = "#000000"
            if descriptor.operations.contains(where: { operationReferences("brandColor", $0) }) {
                warnings.append(PlanWarning("Couldn't read the site's brand color; used a default."))
            }
        }

        // 5. Resolve operations into concrete steps using effective answers.
        var steps: [PlannedStep] = []
        for op in descriptor.operations {
            switch op {
            case .copyFile(let from, let to, let when):
                guard isVisible(when, answers: effective, providerID: providerID) else { continue }
                let dest = to.resolve(tokens)
                let src = templateDirectory.appendingPathComponent(from.path)
                guard let contents = try? String(contentsOf: src, encoding: .utf8) else {
                    // Hard-fail: skipping the copy would leave the descriptor's matching `import`
                    // injection pointing at a file that was never written — a deferred Astro build
                    // break. Surface it now as a clear, up-front error instead.
                    return .failure(.missingTemplateAsset(path: from.path))
                }
                steps.append(.createFile(relativePath: dest, contents: contents))
            case .writeConfig(let entries, let when):
                guard isVisible(when, answers: effective, providerID: providerID) else { continue }
                steps.append(.upsertConfig(entries.map { ConfigKV(key: $0.key, value: $0.value.resolve(tokens)) }))
            case .addCSPDomains(let fromProvider, let extra, let fromFieldHost, let when):
                guard isVisible(when, answers: effective, providerID: providerID) else { continue }
                var domains = extra
                if fromProvider, let p = providerID,
                   let provider = descriptor.providers.first(where: { $0.id == p }) {
                    domains = provider.cspDomains + extra
                }
                if let key = fromFieldHost, let value = effective[key], let host = URL(string: value)?.host {
                    domains.append(host)
                }
                if !domains.isEmpty { steps.append(.addCSP(domains)) }
            case .injectAtAnchor(let file, let anchor, let snippet, let when, let style):
                guard isVisible(when, answers: effective, providerID: providerID) else { continue }
                steps.append(.injectAnchor(
                    relativeFile: file.resolve(tokens),
                    anchor: anchor,
                    id: descriptor.id.rawValue,
                    snippet: snippet.resolve(tokens),
                    style: style
                ))
            }
        }

        return .success(OperationPlan(integrationID: descriptor.id, steps: steps, warnings: warnings))
    }

    // Internal (not private) so Task 9's wizard model can call it from the same module.
    static func isVisible(_ condition: Condition, answers: Answers, providerID: String?) -> Bool {
        switch condition {
        case .always: return true
        case .providerIs(let p): return providerID == p
        case .fieldEquals(let key, let value): return answers[key] == value
        case .fieldIn(let key, let values): return values.contains(answers[key] ?? "")
        }
    }

    private static func operationReferences(_ token: String, _ op: Operation) -> Bool {
        let needle = "{{\(token)}}"
        switch op {
        case .copyFile(_, let to, _): return to.raw.contains(needle)
        case .writeConfig(let entries, _): return entries.contains { $0.value.raw.contains(needle) }
        case .injectAtAnchor(let file, _, let snippet, _, _): return file.raw.contains(needle) || snippet.raw.contains(needle)
        case .addCSPDomains: return false
        }
    }

    private static func brandColor(sourceDirectory: URL, fileManager: FileManager) -> String? {
        let css = sourceDirectory.appendingPathComponent("src/styles/global.css")
        guard let text = try? String(contentsOf: css, encoding: .utf8) else { return nil }
        guard let r = text.range(of: "--color-primary:") else { return nil }
        let rest = text[r.upperBound...]
        guard let semi = rest.firstIndex(of: ";") else { return nil }
        return rest[..<semi].trimmingCharacters(in: .whitespaces)
    }
}
