// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import CryptoKit
import Foundation

enum FilterListKind: String, Codable {
    case preset
    case custom
}

enum FilterListDownloadState: String, Codable {
    case neverDownloaded
    case downloading
    case downloaded
    case failed
}

enum FilterListCompileState: String, Codable {
    case neverCompiled
    case compiling
    case compiled
    case failed
}

struct FilterListRecord: Codable, Equatable {
    let id: String
    var name: String
    var sourceURL: URL
    var kind: FilterListKind
    var isEnabled: Bool
    var downloadState: FilterListDownloadState
    var lastUpdated: Date?
    var lastFailure: String?
    var localFileName: String?
    var byteCount: Int?
    var contentHash: String?
    var compileState: FilterListCompileState?
    var compileFailure: String?
    var compiledRuleListIdentifier: String?
    var compiledContentHash: String?
    var compiledAt: Date?
    var compiledRuleCount: Int?
}

enum FilterListManagerError: LocalizedError {
    case invalidURL
    case invalidResponse
    case emptyResponse
    case responseTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter an HTTP or HTTPS filter-list URL."
        case .invalidResponse:
            return "The server did not return a successful response."
        case .emptyResponse:
            return "The downloaded filter list was empty."
        case .responseTooLarge:
            return "The downloaded filter list is larger than the Phase 2 safety limit."
        }
    }
}

@MainActor
final class FilterListManager {
    static let shared = FilterListManager()

    private struct UX {
        static let directoryName = "PersonalFilterLists"
        static let manifestFileName = "filter-lists.json"
        static let maxDownloadedBytes = 15 * 1024 * 1024
    }

    private let fileManager: FileManager
    private let urlSession: URLSession
    private var cachedRecords: [FilterListRecord]?

    private let presetRecords: [FilterListRecord] = [
        FilterListRecord(
            id: "preset-easylist",
            name: "EasyList",
            sourceURL: URL(string: "https://easylist.to/easylist/easylist.txt")!,
            kind: .preset,
            isEnabled: false,
            downloadState: .neverDownloaded,
            lastUpdated: nil,
            lastFailure: nil,
            localFileName: nil,
            byteCount: nil,
            contentHash: nil,
            compileState: .neverCompiled,
            compileFailure: nil,
            compiledRuleListIdentifier: nil,
            compiledContentHash: nil,
            compiledAt: nil,
            compiledRuleCount: nil
        ),
        FilterListRecord(
            id: "preset-easyprivacy",
            name: "EasyPrivacy",
            sourceURL: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!,
            kind: .preset,
            isEnabled: false,
            downloadState: .neverDownloaded,
            lastUpdated: nil,
            lastFailure: nil,
            localFileName: nil,
            byteCount: nil,
            contentHash: nil,
            compileState: .neverCompiled,
            compileFailure: nil,
            compiledRuleListIdentifier: nil,
            compiledContentHash: nil,
            compiledAt: nil,
            compiledRuleCount: nil
        )
    ]

    init(fileManager: FileManager = .default, urlSession: URLSession = .shared) {
        self.fileManager = fileManager
        self.urlSession = urlSession
    }

    func records() -> [FilterListRecord] {
        if let cachedRecords {
            return cachedRecords
        }

        let loadedRecords = loadRecordsFromDisk()
        let mergedRecords = mergePresetRecords(with: loadedRecords)
        cachedRecords = mergedRecords
        saveRecords(mergedRecords)
        return mergedRecords
    }

    @discardableResult
    func addCustomList(from urlString: String) async -> Result<FilterListRecord, Error> {
        guard let url = normalizedURL(from: urlString) else {
            return .failure(FilterListManagerError.invalidURL)
        }

        var allRecords = records()
        if let existingIndex = allRecords.firstIndex(where: { $0.sourceURL == url }) {
            allRecords[existingIndex].isEnabled = true
            cachedRecords = allRecords
            saveRecords(allRecords)
            return await refreshList(id: allRecords[existingIndex].id)
        }

        let host = url.host ?? "Custom List"
        let record = FilterListRecord(
            id: "custom-\(UUID().uuidString)",
            name: host,
            sourceURL: url,
            kind: .custom,
            isEnabled: true,
            downloadState: .neverDownloaded,
            lastUpdated: nil,
            lastFailure: nil,
            localFileName: nil,
            byteCount: nil,
            contentHash: nil,
            compileState: .neverCompiled,
            compileFailure: nil,
            compiledRuleListIdentifier: nil,
            compiledContentHash: nil,
            compiledAt: nil,
            compiledRuleCount: nil
        )
        allRecords.append(record)
        cachedRecords = allRecords
        saveRecords(allRecords)

        return await refreshList(id: record.id)
    }

    func setEnabled(_ isEnabled: Bool, for id: String) {
        var allRecords = records()
        guard let index = allRecords.firstIndex(where: { $0.id == id }) else { return }
        allRecords[index].isEnabled = isEnabled
        cachedRecords = allRecords
        saveRecords(allRecords)
    }

    func enabledCompiledRuleListIdentifiers() -> [String] {
        return records().compactMap { record in
            guard record.isEnabled,
                  record.downloadState == .downloaded,
                  record.compileState == .compiled,
                  record.compiledContentHash == record.contentHash else { return nil }
            return record.compiledRuleListIdentifier
        }
    }

    func downloadedText(for record: FilterListRecord) throws -> String? {
        guard let localFileName = record.localFileName else { return nil }
        let fileURL = storageDirectory().appendingPathComponent(localFileName)
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    func markCompiling(id: String) {
        updateRecord(id: id) { record in
            record.compileState = .compiling
            record.compileFailure = nil
        }
    }

    func markCompiled(id: String, ruleListIdentifier: String, ruleCount: Int) {
        updateRecord(id: id) { record in
            record.compileState = .compiled
            record.compileFailure = nil
            record.compiledRuleListIdentifier = ruleListIdentifier
            record.compiledContentHash = record.contentHash
            record.compiledAt = Date()
            record.compiledRuleCount = ruleCount
        }
    }

    func markCompileFailed(id: String, error: String) {
        updateRecord(id: id) { record in
            record.compileState = .failed
            record.compileFailure = error
        }
    }

    func contentRuleListIdentifier(for record: FilterListRecord) -> String? {
        guard let contentHash = record.contentHash else { return nil }
        let hashPrefix = String(contentHash.prefix(16))
        return "personal-filter-list-\(record.id)-\(hashPrefix)"
    }

    @discardableResult
    func refreshEnabledLists() async -> [Result<FilterListRecord, Error>] {
        var results: [Result<FilterListRecord, Error>] = []
        for record in records() where record.isEnabled {
            results.append(await refreshList(id: record.id))
        }
        return results
    }

    @discardableResult
    func refreshList(id: String) async -> Result<FilterListRecord, Error> {
        var allRecords = records()
        guard let index = allRecords.firstIndex(where: { $0.id == id }) else {
            return .failure(FilterListManagerError.invalidURL)
        }

        allRecords[index].downloadState = .downloading
        allRecords[index].lastFailure = nil
        cachedRecords = allRecords
        saveRecords(allRecords)

        do {
            let updatedRecord = try await download(record: allRecords[index])
            allRecords = records()
            if let updatedIndex = allRecords.firstIndex(where: { $0.id == updatedRecord.id }) {
                allRecords[updatedIndex] = updatedRecord
            }
            cachedRecords = allRecords
            saveRecords(allRecords)
            return .success(updatedRecord)
        } catch {
            allRecords = records()
            if let failedIndex = allRecords.firstIndex(where: { $0.id == id }) {
                allRecords[failedIndex].downloadState = .failed
                allRecords[failedIndex].lastFailure = error.localizedDescription
                cachedRecords = allRecords
                saveRecords(allRecords)
                return .success(allRecords[failedIndex])
            }
            return .failure(error)
        }
    }

    private func download(record: FilterListRecord) async throws -> FilterListRecord {
        let (data, response) = try await urlSession.data(from: record.sourceURL)
        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw FilterListManagerError.invalidResponse
        }
        guard !data.isEmpty else { throw FilterListManagerError.emptyResponse }
        guard data.count <= UX.maxDownloadedBytes else { throw FilterListManagerError.responseTooLarge }

        try ensureStorageDirectoryExists()

        var updatedRecord = record
        let localFileName = record.localFileName ?? "\(record.id).txt"
        let fileURL = storageDirectory().appendingPathComponent(localFileName)
        try data.write(to: fileURL, options: .atomic)

        updatedRecord.downloadState = .downloaded
        updatedRecord.lastUpdated = Date()
        updatedRecord.lastFailure = nil
        updatedRecord.localFileName = localFileName
        updatedRecord.byteCount = data.count
        updatedRecord.contentHash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        updatedRecord.compileState = .neverCompiled
        updatedRecord.compileFailure = nil
        updatedRecord.compiledRuleListIdentifier = nil
        updatedRecord.compiledContentHash = nil
        updatedRecord.compiledAt = nil
        updatedRecord.compiledRuleCount = nil
        return updatedRecord
    }

    private func normalizedURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return nil }
        guard scheme == "https" || scheme == "http" else { return nil }
        return url
    }

    private func mergePresetRecords(with loadedRecords: [FilterListRecord]) -> [FilterListRecord] {
        var mergedRecords = loadedRecords
        for preset in presetRecords where !mergedRecords.contains(where: { $0.id == preset.id }) {
            mergedRecords.insert(preset, at: 0)
        }
        return mergedRecords
    }

    private func loadRecordsFromDisk() -> [FilterListRecord] {
        guard let data = try? Data(contentsOf: manifestURL()) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([FilterListRecord].self, from: data)) ?? []
    }

    private func saveRecords(_ records: [FilterListRecord]) {
        do {
            try ensureStorageDirectoryExists()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(records)
            try data.write(to: manifestURL(), options: .atomic)
        } catch {
            assertionFailure("Unable to save filter-list metadata: \(error)")
        }
    }

    private func updateRecord(id: String, update: (inout FilterListRecord) -> Void) {
        var allRecords = records()
        guard let index = allRecords.firstIndex(where: { $0.id == id }) else { return }
        update(&allRecords[index])
        cachedRecords = allRecords
        saveRecords(allRecords)
    }

    private func ensureStorageDirectoryExists() throws {
        try fileManager.createDirectory(at: storageDirectory(), withIntermediateDirectories: true)
    }

    private func manifestURL() -> URL {
        return storageDirectory().appendingPathComponent(UX.manifestFileName)
    }

    private func storageDirectory() -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport.appendingPathComponent(UX.directoryName, isDirectory: true)
    }
}
