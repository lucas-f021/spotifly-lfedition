//
//  LocalFileManager.swift
//  Spotifly
//
//  Manages local audio files: folder selection, scanning, and matching to spotify:local: URIs.
//

import AVFoundation
import Foundation

@MainActor
@Observable
final class LocalFileManager {
    static let shared = LocalFileManager()

    /// Path to the user's local files folder
    var folderPath: String? {
        didSet {
            if let path = folderPath {
                UserDefaults.standard.set(path, forKey: "localFilesFolderPath")
                // Save security-scoped bookmark for sandbox access
                if let url = URL(string: path) ?? URL(fileURLWithPath: path) as URL? {
                    saveBookmark(for: url)
                }
            } else {
                UserDefaults.standard.removeObject(forKey: "localFilesFolderPath")
                UserDefaults.standard.removeObject(forKey: "localFilesFolderBookmark")
            }
            Task { await rescan() }
        }
    }

    /// Indexed local files: normalized key → file URL
    private(set) var fileIndex: [String: URL] = [:]

    /// Number of indexed files
    var indexedFileCount: Int { fileIndex.count }

    /// Whether a scan is in progress
    private(set) var isScanning = false

    private init() {
        // Restore saved folder
        folderPath = UserDefaults.standard.string(forKey: "localFilesFolderPath")
        if folderPath != nil {
            Task { await rescan() }
        }
    }

    // MARK: - Folder Selection

    /// Sets the local files folder from a URL (e.g., from NSOpenPanel).
    func setFolder(_ url: URL) {
        folderPath = url.path
        saveBookmark(for: url)
    }

    /// Clears the local files folder.
    func clearFolder() {
        folderPath = nil
        fileIndex = [:]
    }

    // MARK: - File Scanning

    /// Rescans the local files folder and rebuilds the index.
    func rescan() async {
        guard let path = folderPath else {
            fileIndex = [:]
            return
        }

        isScanning = true
        defer { isScanning = false }

        let folderURL: URL
        if let bookmarkData = UserDefaults.standard.data(forKey: "localFilesFolderBookmark") {
            var isStale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                _ = resolved.startAccessingSecurityScopedResource()
                folderURL = resolved
            } else {
                folderURL = URL(fileURLWithPath: path)
            }
        } else {
            folderURL = URL(fileURLWithPath: path)
        }

        let audioExtensions: Set<String> = ["mp3", "m4a", "flac", "wav", "aac", "ogg", "aiff"]

        var newIndex: [String: URL] = [:]

        let scanURL = folderURL
        let exts = audioExtensions
        let result: [String: URL] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var index: [String: URL] = [:]
                let fm = FileManager.default
                guard let enumerator = fm.enumerator(
                    at: scanURL,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else {
                    continuation.resume(returning: index)
                    return
                }

                for case let fileURL as URL in enumerator {
                    let ext = fileURL.pathExtension.lowercased()
                    guard exts.contains(ext) else { continue }

                    // Index by filename (without extension), normalized
                    let filename = fileURL.deletingPathExtension().lastPathComponent
                    let key = LocalFileManager.normalizeForMatch(filename)
                    index[key] = fileURL

                    // Also try to read ID3 metadata for better matching
                    let asset = AVURLAsset(url: fileURL)
                    let metadata = asset.commonMetadata
                    let title = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle)
                        .first?.stringValue
                    let artist = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtist)
                        .first?.stringValue

                    if let title {
                        let metadataKey = LocalFileManager.normalizeForMatch(
                            artist.map { "\($0) \(title)" } ?? title
                        )
                        index[metadataKey] = fileURL
                    }
                }
                continuation.resume(returning: index)
            }
        }

        fileIndex = result
        debugLog("LocalFileManager", "Indexed \(newIndex.count) entries from \(folderURL.path)")
    }

    // MARK: - Matching

    /// Finds a local audio file matching a spotify:local: track.
    func findFile(artist: String, title: String) -> URL? {
        // Try exact match: "artist title"
        let key1 = Self.normalizeForMatch("\(artist) \(title)")
        if let url = fileIndex[key1] { return url }

        // Try title only
        let key2 = Self.normalizeForMatch(title)
        if let url = fileIndex[key2] { return url }

        // Try fuzzy: find best match by checking if any key contains the title
        let normalizedTitle = Self.normalizeForMatch(title)
        if normalizedTitle.count >= 3 {
            for (key, url) in fileIndex {
                if key.contains(normalizedTitle) || normalizedTitle.contains(key) {
                    return url
                }
            }
        }

        return nil
    }

    /// Finds a local audio file matching a Track entity.
    func findFile(for track: Track) -> URL? {
        guard track.isLocalFile else { return nil }
        return findFile(artist: track.artistName, title: track.name)
    }

    // MARK: - Helpers

    /// Normalizes a string for fuzzy matching: lowercase, strip punctuation/spaces.
    nonisolated static func normalizeForMatch(_ s: String) -> String {
        s.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .filter { $0.isLetter || $0.isNumber || $0 == " " }
            .split(separator: " ")
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Security-Scoped Bookmarks

    private func saveBookmark(for url: URL) {
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(bookmark, forKey: "localFilesFolderBookmark")
        } catch {
            debugLog("LocalFileManager", "Failed to save bookmark: \(error)")
        }
    }
}
