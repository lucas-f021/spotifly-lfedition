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
    /// Ages (in seconds) of all requests in the rolling telemetry window (60s).
    /// 0 = now, larger = older. Used by the rate limiter chip's bar graph.
    let historyAges: [Double]
    /// Length of the telemetry window in seconds (always >= windowSeconds).
    let historyWindowSeconds: Double
}

/// Rolling-window rate limiter — caps outgoing Spotify requests to avoid 429s.
/// Tracks timestamps of recent requests and delays when the limit is reached.
actor SpotifyRateLimiter {
    let maxRequests: Int
    let windowSeconds: Double
    /// Window kept for the bar-graph telemetry. Larger than windowSeconds so the
    /// chip can show what was happening before the active limiter window started.
    let historyWindowSeconds: Double = 60
    private var timestamps: [Date] = []
    private var _waitingCount: Int = 0

    init(maxRequests: Int, windowSeconds: Double) {
        self.maxRequests = maxRequests
        self.windowSeconds = windowSeconds
    }

    func wait() async throws {
        _waitingCount += 1
        defer { _waitingCount -= 1 }

        for _ in 0 ..< 300 { // safety: max 300 iterations (~30s at 0.1s each)
            let now = Date()
            // Drop entries outside the telemetry window — limiter logic filters
            // its own (shorter) window below.
            let historyStart = now.addingTimeInterval(-historyWindowSeconds)
            timestamps.removeAll { $0 < historyStart }

            let limiterStart = now.addingTimeInterval(-windowSeconds)
            let activeCount = timestamps.reduce(0) { $1 >= limiterStart ? $0 + 1 : $0 }

            if activeCount < maxRequests {
                timestamps.append(now)
                return
            }

            // Wait until the oldest request inside the limiter window exits
            let oldestActive = timestamps.first { $0 >= limiterStart }!
            let timeUntilExpiry = windowSeconds - now.timeIntervalSince(oldestActive)
            let delay = max(min(timeUntilExpiry, 2.0), 0.1) // clamp between 0.1s and 2s
            try await Task.sleep(for: .seconds(delay))
        }
    }

    func snapshot() -> RateLimiterSnapshot {
        let now = Date()
        let historyStart = now.addingTimeInterval(-historyWindowSeconds)
        // Drop stale telemetry entries on every snapshot so the chip stays accurate
        // even when no new requests are firing.
        timestamps.removeAll { $0 < historyStart }

        let limiterStart = now.addingTimeInterval(-windowSeconds)
        let active = timestamps.filter { $0 >= limiterStart }
        let oldestAge = active.first.map { now.timeIntervalSince($0) }
        let newestAge = active.last.map { now.timeIntervalSince($0) }
        let historyAges = timestamps.map { now.timeIntervalSince($0) }

        return RateLimiterSnapshot(
            requestsInWindow: active.count,
            maxRequests: maxRequests,
            windowSeconds: windowSeconds,
            oldestRequestAge: oldestAge,
            newestRequestAge: newestAge,
            waitingCount: _waitingCount,
            historyAges: historyAges,
            historyWindowSeconds: historyWindowSeconds,
        )
    }
}

/// Single shared rate limiter for ALL Spotify requests (Web API + spclient).
/// Spotify enforces 30 req / 30s in dev mode across the entire app.
/// We use 20 to leave headroom — spclient calls (SpTrack::get) may make multiple
/// internal HTTP requests that we can't track from Swift.
let spotifyRateLimiter = SpotifyRateLimiter(maxRequests: 20, windowSeconds: 30)

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
