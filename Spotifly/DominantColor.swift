//
//  DominantColor.swift
//  Spotifly
//
//  Extracts the dominant color from an album art URL using Core Image's
//  CIAreaAverage filter. Used to tint the Now Playing bar background.
//

import AppKit
import CoreImage
import SwiftUI

/// Extracts and caches dominant colors for album art URLs.
@MainActor
final class DominantColorCache {
    static let shared = DominantColorCache()

    fileprivate var cache: [String: Color] = [:]
    fileprivate var inflight: Set<String> = []

    /// Returns a cached color if available; otherwise nil and kicks off a fetch.
    /// The completion fires on the main thread when extraction is done.
    func color(for url: URL, completion: @MainActor @escaping (Color) -> Void) {
        let key = url.absoluteString
        if let cached = cache[key] {
            completion(cached)
            return
        }
        guard !inflight.contains(key) else { return }
        inflight.insert(key)

        Task.detached(priority: .userInitiated) {
            let color = await Self.extractColor(from: url)
            await MainActor.run {
                DominantColorCache.shared.inflight.remove(key)
                if let color {
                    DominantColorCache.shared.cache[key] = color
                    completion(color)
                }
            }
        }
    }

    /// Downloads the image and computes its average color via CIAreaAverage.
    /// Bumps saturation so the tint reads as a real color rather than gray.
    nonisolated private static func extractColor(from url: URL) async -> Color? {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let nsImage = NSImage(data: data),
              let tiff = nsImage.tiffRepresentation,
              let ciImage = CIImage(data: tiff)
        else { return nil }

        let extent = ciImage.extent
        let extentVector = CIVector(x: extent.origin.x, y: extent.origin.y, z: extent.size.width, w: extent.size.height)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: ciImage,
            kCIInputExtentKey: extentVector,
        ]),
            let output = filter.outputImage
        else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let ctx = CIContext(options: [.workingColorSpace: NSNull()])
        ctx.render(
            output,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil,
        )

        let r = Double(bitmap[0]) / 255
        let g = Double(bitmap[1]) / 255
        let b = Double(bitmap[2]) / 255

        // Boost saturation so the tint isn't washed-out gray.
        let nsColor = NSColor(red: r, green: g, blue: b, alpha: 1)
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        nsColor.usingColorSpace(.sRGB)?.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha)
        let boosted = NSColor(
            hue: hue,
            saturation: min(1, sat * 1.6),
            brightness: max(0.35, min(0.7, bri)),
            alpha: 1,
        )

        return Color(nsColor: boosted)
    }
}
