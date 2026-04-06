//
//  SpotifyAPI.swift
//  Spotifly
//
//  Spotify Web API client - base definitions and utilities.
//

import Foundation

/// Spotify item types for generating external URLs
enum SpotifyItemType: String {
    case track
    case album
    case artist
    case playlist
    case user
}

/// Generates a Spotify external URL from item type and ID
func spotifyExternalUrl(type: SpotifyItemType, id: String) -> String {
    "https://open.spotify.com/\(type.rawValue)/\(id)"
}

// MARK: - Rate Limiter

/// Snapshot of a rate limiter's current state
struct RateLimiterSnapshot: Sendable {
    let requestsInWindow: Int
    let maxRequests: Int
    let windowSeconds: Double
    let oldestRequestAge: Double? // seconds since oldest request in window
    let newestRequestAge: Double? // seconds since newest request in window
    let waitingCount: Int
}

/// Rolling-window rate limiter — caps outgoing Spotify requests to avoid 429s.
/// Tracks timestamps of recent requests and delays when the limit is reached.
actor SpotifyRateLimiter {
    let maxRequests: Int
    let windowSeconds: Double
    private var timestamps: [Date] = []
    private var _waitingCount: Int = 0

    init(maxRequests: Int, windowSeconds: Double) {
        self.maxRequests = maxRequests
        self.windowSeconds = windowSeconds
    }

    func wait() async throws {
        _waitingCount += 1
        defer { _waitingCount -= 1 }

        while true {
            let now = Date()
            let windowStart = now.addingTimeInterval(-windowSeconds)
            timestamps.removeAll { $0 < windowStart }

            if timestamps.count < maxRequests {
                timestamps.append(now)
                return
            }

            // Wait until the oldest request exits the window
            let oldest = timestamps.first!
            let delay = oldest.timeIntervalSince(windowStart)
            try await Task.sleep(for: .seconds(max(delay, 0.1)))
        }
    }

    func snapshot() -> RateLimiterSnapshot {
        let now = Date()
        let windowStart = now.addingTimeInterval(-windowSeconds)
        let active = timestamps.filter { $0 >= windowStart }
        let oldestAge = active.first.map { now.timeIntervalSince($0) }
        let newestAge = active.last.map { now.timeIntervalSince($0) }
        return RateLimiterSnapshot(
            requestsInWindow: active.count,
            maxRequests: maxRequests,
            windowSeconds: windowSeconds,
            oldestRequestAge: oldestAge,
            newestRequestAge: newestAge,
            waitingCount: _waitingCount,
        )
    }
}

/// Single shared rate limiter for ALL Spotify requests (Web API + spclient).
/// Spotify enforces 30 req / 30s in dev mode across the entire app — we use 27 for headroom.
let spotifyRateLimiter = SpotifyRateLimiter(maxRequests: 27, windowSeconds: 30)

// MARK: - Spotify API

/// Spotify Web API client
enum SpotifyAPI {
    static let baseURL = "https://api.spotify.com/v1"

    /// Performs a URL request with automatic retry on 429 (rate limit).
    ///
    /// When Spotify returns 429, reads the `Retry-After` header and waits that many seconds
    /// before retrying. Falls back to exponential backoff if the header is missing.
    /// After maxRetries exhausted, returns the final 429 response for the caller to handle.
    static func data(for request: URLRequest, maxRetries: Int = 3) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            try await spotifyRateLimiter.wait()
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SpotifyAPIError.invalidResponse
            }

            guard httpResponse.statusCode == 429 else {
                return (data, httpResponse)
            }

            attempt += 1
            if attempt > maxRetries {
                debugLog("SpotifyAPI", "[RATE LIMITED] Max retries (\(maxRetries)) exceeded for \(request.url?.path ?? "?")")
                return (data, httpResponse)
            }

            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                .flatMap(Double.init) ?? Double(attempt * 2)
            debugLog("SpotifyAPI", "[RATE LIMITED] 429 received — Retry-After: \(retryAfter)s (attempt \(attempt)/\(maxRetries)) for \(request.url?.path ?? "?")")

            // If Spotify wants us to wait more than 30s, the rate limit window is too large
            // to retry transparently — fail immediately so the UI stays responsive.
            guard retryAfter <= 30 else {
                debugLog("SpotifyAPI", "[RATE LIMITED] Retry-After \(retryAfter)s exceeds 30s cap — failing immediately")
                return (data, httpResponse)
            }
            try await Task.sleep(for: .seconds(retryAfter))
        }
    }

    /// Helper to throw appropriate error from API error response data
    static func throwAPIError(data: Data, statusCode: Int) throws -> Never {
        let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
        debugLog("SpotifyAPI", "[HTTP \(statusCode)] \(body)")
        if let errorResponse = try? JSONDecoder().decode(SpotifyErrorResponse.self, from: data) {
            throw SpotifyAPIError.apiError(errorResponse.error.message)
        }
        throw SpotifyAPIError.apiError("HTTP \(statusCode)")
    }

    /// Parses a Spotify URI (spotify:track:xxx) and returns the track ID
    static func parseTrackURI(_ uri: String) -> String? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)

        // Handle spotify:track:ID format
        if trimmed.hasPrefix("spotify:track:") {
            return String(trimmed.dropFirst("spotify:track:".count))
        }

        // Handle open.spotify.com/track/ID format
        if trimmed.contains("open.spotify.com/track/") {
            if let range = trimmed.range(of: "open.spotify.com/track/") {
                var trackId = String(trimmed[range.upperBound...])
                // Remove query parameters if present
                if let queryIndex = trackId.firstIndex(of: "?") {
                    trackId = String(trackId[..<queryIndex])
                }
                return trackId.isEmpty ? nil : trackId
            }
        }

        return nil
    }
}
