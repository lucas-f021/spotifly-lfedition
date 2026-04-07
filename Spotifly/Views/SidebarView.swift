//
//  SidebarView.swift
//  Spotifly
//
//  Navigation sidebar for authenticated view
//

import SwiftUI

enum NavigationItem: Hashable, Identifiable {
    case startpage
    case searchResults
    case favorites
    case playlists
    case albums
    case artists
    case queue
    case speakers
    case equalizer
    case profile

    var id: String {
        switch self {
        case .startpage: "startpage"
        case .searchResults: "searchResults"
        case .favorites: "favorites"
        case .playlists: "playlists"
        case .albums: "albums"
        case .artists: "artists"
        case .queue: "queue"
        case .speakers: "speakers"
        case .equalizer: "equalizer"
        case .profile: "profile"
        }
    }

    var title: String {
        switch self {
        case .startpage:
            String(localized: "nav.startpage")
        case .searchResults:
            String(localized: "nav.search_results")
        case .favorites:
            String(localized: "nav.favorites")
        case .playlists:
            String(localized: "nav.playlists")
        case .albums:
            String(localized: "nav.albums")
        case .artists:
            String(localized: "nav.artists")
        case .queue:
            String(localized: "nav.queue")
        case .speakers:
            String(localized: "nav.speakers")
        case .equalizer:
            String(localized: "nav.equalizer")
        case .profile:
            String(localized: "nav.profile")
        }
    }

    var icon: String {
        switch self {
        case .startpage:
            "house.fill"
        case .searchResults:
            "magnifyingglass"
        case .favorites:
            "heart.fill"
        case .playlists:
            "music.note.list"
        case .albums:
            "square.stack.fill"
        case .artists:
            "mic.fill"
        case .queue:
            "list.bullet"
        case .speakers:
            "hifispeaker.2.fill"
        case .equalizer:
            "slider.horizontal.3"
        case .profile:
            "person.circle.fill"
        }
    }
}

struct SidebarView: View {
    @Binding var selection: NavigationItem?
    let onLogout: () -> Void
    var hasSearchResults: Bool = false
    var userProfile: UserProfile?

    /// Navigation items in the main section
    private var mainNavItems: [NavigationItem] {
        [.startpage, .queue, .speakers, .equalizer]
    }

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(mainNavItems) { item in
                    NavigationLink(value: item) {
                        Label(item.title, systemImage: item.icon)
                    }
                }
            } header: {
                HStack {
                    Image(systemName: "music.note.list")
                        .foregroundStyle(.green)
                    Text("app.name")
                        .font(.headline)
                }
                .padding(.bottom, 8)
            }

            if hasSearchResults {
                Section {
                    NavigationLink(value: NavigationItem.searchResults) {
                        Label(String(localized: "nav.search_results"), systemImage: "magnifyingglass")
                    }
                }
            }

            Section {
                ForEach([NavigationItem.favorites, NavigationItem.playlists, NavigationItem.albums, NavigationItem.artists]) { item in
                    NavigationLink(value: item) {
                        Label(item.title, systemImage: item.icon)
                    }
                }
            } header: {
                Text("nav.library")
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 4) {
                RateLimiterStatusView()
                Button {
                    selection = .profile
                } label: {
                    HStack(spacing: 8) {
                        ProfileAvatarView(userProfile: userProfile, size: 28)
                        Text(userProfile?.displayName ?? String(localized: "nav.profile"))
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selection == .profile ? AnyShapeStyle(.selection.opacity(0.8)) : AnyShapeStyle(.clear)),
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        }
        .navigationTitle("app.name")
    }
}

// MARK: - Rate Limiter Status

struct RateLimiterStatusView: View {
    @State private var snap = RateLimiterSnapshot(
        requestsInWindow: 0,
        maxRequests: 20,
        windowSeconds: 30,
        oldestRequestAge: nil,
        newestRequestAge: nil,
        waitingCount: 0,
        historyAges: [],
        historyWindowSeconds: 60,
    )

    /// Bucketed counts: index 0 = oldest second (60s ago), index N-1 = newest (now).
    private var buckets: [Int] {
        let count = Int(snap.historyWindowSeconds)
        var result = [Int](repeating: 0, count: count)
        for age in snap.historyAges {
            // age 0 → newest bucket (count - 1); age 59.x → oldest bucket (0)
            let bucketFromNewest = Int(age.rounded(.down))
            let idx = count - 1 - bucketFromNewest
            if idx >= 0, idx < count { result[idx] += 1 }
        }
        return result
    }

    private var usageColor: Color {
        let ratio = Double(snap.requestsInWindow) / Double(max(1, snap.maxRequests))
        if ratio >= 0.8 { return .red }
        if ratio >= 0.5 { return .yellow }
        return .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            counterRow
            barGraph
            xAxis
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.black)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
        .task {
            while !Task.isCancelled {
                snap = await spotifyRateLimiter.snapshot()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Active 30s window count (left) and queued indicator (right).
    private var counterRow: some View {
        HStack(spacing: 4) {
            Text("\(snap.requestsInWindow)")
                .foregroundStyle(usageColor)
            Text("/\(snap.maxRequests) reqs")
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            if snap.waitingCount > 0 {
                Text("\(snap.waitingCount) queued")
                    .foregroundStyle(.orange)
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
    }

    /// 60-column histogram with one stacked unit per request. Each request in a
    /// 1s bucket renders as a separate small rectangle so concurrent calls are
    /// individually visible. Newest column on the right.
    private var barGraph: some View {
        GeometryReader { geo in
            let bucketCount = buckets.count
            let totalGapWidth = CGFloat(bucketCount - 1) * 1
            let barWidth = max(1, (geo.size.width - totalGapWidth) / CGFloat(bucketCount))
            let maxHeight = geo.size.height
            let unitHeight: CGFloat = 4
            let unitGap: CGFloat = 1

            ZStack {
                HStack(alignment: .bottom, spacing: 1) {
                    ForEach(0 ..< bucketCount, id: \.self) { i in
                        let count = buckets[i]
                        VStack(spacing: unitGap) {
                            ForEach(0 ..< count, id: \.self) { _ in
                                Rectangle()
                                    .fill(Color.green)
                                    .frame(width: barWidth, height: unitHeight)
                            }
                        }
                    }
                }
                .frame(width: geo.size.width, height: maxHeight, alignment: .bottom)

                // 30s vertical marker — centered at width/2 via .position so it
                // shares an unambiguous anchor with the "30" x-axis label.
                Rectangle()
                    .fill(Color.white.opacity(0.4))
                    .frame(width: 1, height: maxHeight)
                    .position(x: geo.size.width * 0.5, y: maxHeight / 2)
            }
        }
        .frame(height: 56)
    }

    /// Tick labels at 60, 45, 30, 15, 0 seconds (left → right).
    private var xAxis: some View {
        GeometryReader { geo in
            let labels: [(offset: Int, text: String)] = [
                (60, "60s"), (45, "45"), (30, "30"), (15, "15"), (0, "0"),
            ]
            let h = geo.size.height
            ZStack {
                ForEach(labels, id: \.offset) { label in
                    // 60s on the left (x=0), 0s on the right (x=width).
                    let x = geo.size.width * CGFloat(60 - label.offset) / 60
                    Text(label.text)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .fixedSize()
                        .position(x: x, y: h / 2)
                }
            }
        }
        .frame(height: 12)
    }
}

// MARK: - Profile Avatar

struct ProfileAvatarView: View {
    let userProfile: UserProfile?
    var size: CGFloat = 32

    var body: some View {
        if let imageURL = userProfile?.imageURL {
            AsyncImage(url: imageURL) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                initialsView(for: userProfile?.displayName)
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else if let displayName = userProfile?.displayName {
            initialsView(for: displayName)
        } else {
            Circle()
                .fill(.quaternary)
                .frame(width: size, height: size)
        }
    }

    private func initialsView(for name: String?) -> some View {
        let initials = String((name ?? "?").prefix(2)).uppercased()
        return Circle()
            .fill(.green.gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}
