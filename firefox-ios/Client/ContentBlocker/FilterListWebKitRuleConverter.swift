// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Foundation

struct FilterListConversionResult {
    let jsonString: String
    let ruleCount: Int
}

enum FilterListConversionError: LocalizedError {
    case noSupportedRules
    case invalidJSON

    var errorDescription: String? {
        switch self {
        case .noSupportedRules:
            return "The filter list did not contain supported network-blocking rules."
        case .invalidJSON:
            return "The converted content-blocker JSON was invalid."
        }
    }
}

final class FilterListWebKitRuleConverter {
    private struct UX {
        static let maxRulesPerList = 45_000
    }

    private let separatorRegex = "[^A-Za-z0-9_\\-.%]"
    private let supportedResourceTypes: [String: String] = [
        "image": "image",
        "script": "script",
        "stylesheet": "style-sheet",
        "font": "font",
        "media": "media",
        "xmlhttprequest": "raw",
        "xhr": "raw"
    ]

    func convert(filterListText: String) throws -> FilterListConversionResult {
        var rules: [[String: Any]] = []
        for rawLine in filterListText.components(separatedBy: .newlines) {
            guard rules.count < UX.maxRulesPerList, let rule = convertLine(rawLine) else { continue }
            rules.append(rule)
        }

        guard !rules.isEmpty else { throw FilterListConversionError.noSupportedRules }

        let data = try JSONSerialization.data(withJSONObject: rules)
        guard let jsonString = String(data: data, encoding: .utf8) else {
            throw FilterListConversionError.invalidJSON
        }
        return FilterListConversionResult(jsonString: jsonString, ruleCount: rules.count)
    }

    private func convertLine(_ rawLine: String) -> [String: Any]? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty,
              !line.hasPrefix("!"),
              !line.hasPrefix("["),
              !line.hasPrefix("@@"),
              !line.contains("##"),
              !line.contains("#@#"),
              !line.contains("#?#"),
              !line.contains("#$#") else { return nil }

        let parts = line.split(separator: "$", maxSplits: 1, omittingEmptySubsequences: false)
        let pattern = String(parts[0])
        let optionString = parts.count > 1 ? String(parts[1]) : nil
        guard !pattern.isEmpty, isSupportedOptions(optionString) else { return nil }
        guard let urlFilter = urlFilter(from: pattern) else { return nil }

        var trigger: [String: Any] = ["url-filter": urlFilter]
        let resourceTypes = resourceTypes(from: optionString)
        if !resourceTypes.isEmpty {
            trigger["resource-type"] = resourceTypes
        }

        return [
            "trigger": trigger,
            "action": ["type": "block"]
        ]
    }

    private func isSupportedOptions(_ optionString: String?) -> Bool {
        guard let optionString, !optionString.isEmpty else { return true }
        let options = optionString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        let unsupportedPrefixes = ["domain=", "denyallow=", "redirect=", "replace=", "csp=", "removeparam="]
        let unsupportedOptions: Set<String> = [
            "badfilter", "elemhide", "generichide", "genericblock", "important", "popup",
            "document", "subdocument", "object", "object-subrequest", "ping", "websocket",
            "webrtc", "other", "third-party", "~third-party"
        ]

        for option in options {
            if unsupportedOptions.contains(option) || unsupportedPrefixes.contains(where: { option.hasPrefix($0) }) {
                return false
            }
            if option.hasPrefix("~") {
                return false
            }
        }
        return true
    }

    private func resourceTypes(from optionString: String?) -> [String] {
        guard let optionString else { return [] }
        let options = optionString
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }

        return options.compactMap { supportedResourceTypes[$0] }
    }

    private func urlFilter(from pattern: String) -> String? {
        if pattern.hasPrefix("||") {
            let hostPattern = String(pattern.dropFirst(2))
            return domainAnchoredFilter(from: hostPattern)
        }

        if pattern.hasPrefix("|") {
            return "^" + regexEscapedPattern(String(pattern.dropFirst()))
        }

        let regex = regexEscapedPattern(pattern)
        return regex.isEmpty ? nil : regex
    }

    private func domainAnchoredFilter(from pattern: String) -> String? {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let rawHost = String(parts[0]).trimmingCharacters(in: CharacterSet(charactersIn: "^"))
        guard !rawHost.isEmpty else { return nil }

        let hostRegex = NSRegularExpression.escapedPattern(for: rawHost).replacingOccurrences(of: "\\*", with: ".*")
        let pathRegex: String
        if parts.count > 1 {
            pathRegex = "/" + regexEscapedPattern(String(parts[1]))
        } else {
            pathRegex = "([/:?&]|$)"
        }

        return "^https?://([^/]+\\.)?" + hostRegex + pathRegex
    }

    private func regexEscapedPattern(_ pattern: String) -> String {
        var output = ""
        for character in pattern {
            switch character {
            case "*":
                output += ".*"
            case "^":
                output += separatorRegex
            default:
                output += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        return output
    }
}
