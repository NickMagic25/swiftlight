import Combine
import CoreGraphics
import Foundation
import ImageIO
import SwiftlightHost

/// Host-scoped, memory-only artwork. Call `load` for visible/near-visible apps first
/// in large libraries; repeated batches reuse images and coalesce outstanding work.
@MainActor final class AppArtworkStore: ObservableObject {
    @Published private(set) var images: [Int: CGImage] = [:]
    /// Qt-compatible dimension heuristic; see `decode` for its known limitation.
    @Published private(set) var placeholderIDs: Set<Int> = []

    private let maximumConcurrent = 4
    private let maximumEntries = 128
    private let maximumBytes = 64 * 1024 * 1024
    private let maximumPending = 512
    private let maximumRetryEntries = 1024
    private var hostID: String?
    private var client: HostClient?
    private var generation = UUID()
    private var pending: [Int] = []
    private var pendingIDs: Set<Int> = []
    private var inFlight: [Int: UUID] = [:]
    // Cancelled tasks remain here until they actually retire. Switching hosts cannot
    // start another four operations while old fetches/decodes are still running.
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var retryAfter: [Int: ContinuousClock.Instant] = [:]
    private var costs: [Int: Int] = [:]
    private var recency: [Int: UInt64] = [:]
    private var accessSerial: UInt64 = 0
    private var cachedBytes = 0
    private let fetchArtwork: @Sendable (HostClient, Int) async throws -> Data

    init(fetchArtwork: @escaping @Sendable (HostClient, Int) async throws -> Data = { client, appID in
        try await client.artwork(appID: appID)
    }) {
        self.fetchArtwork = fetchArtwork
    }

    deinit { for task in tasks.values { task.cancel() } }

    func load(apps: [RemoteApp], using client: HostClient, hostID: String) {
        guard !hostID.isEmpty else { cancel(clear: true); return }
        if self.hostID != hostID {
            cancel(clear: true)
            self.hostID = hostID
        }
        self.client = client
        let now = ContinuousClock.now
        for app in apps {
            guard app.id > 0, app.id <= Int(Int32.max) else { continue }
            if images[app.id] != nil { touch(app.id); continue }
            guard inFlight[app.id] == nil, !pendingIDs.contains(app.id),
                  retryAfter[app.id].map({ $0 <= now }) ?? true else { continue }
            // Bound queued identifiers as well as decoded images. A subsequent
            // visible-app batch can request anything beyond this admission bound.
            guard pending.count < maximumPending else { break }
            pending.append(app.id); pendingIDs.insert(app.id)
        }
        pump()
    }

    /// Call with `clear: true` on unpair, host removal, or a trust change. Host changes
    /// inside `load` also clear immediately. Cancellation never publishes stale data.
    func cancel(clear: Bool = false) {
        generation = UUID()
        client = nil
        pending.removeAll(keepingCapacity: true); pendingIDs.removeAll(keepingCapacity: true)
        inFlight.removeAll(keepingCapacity: true)
        for task in tasks.values { task.cancel() }
        if clear {
            hostID = nil
            if !images.isEmpty { images = [:] }
            if !placeholderIDs.isEmpty { placeholderIDs = [] }
            costs.removeAll(); recency.removeAll(); retryAfter.removeAll()
            cachedBytes = 0; accessSerial = 0
        }
    }

    private func pump() {
        guard let client else { return }
        let fetchArtwork = fetchArtwork
        while tasks.count < maximumConcurrent, !pending.isEmpty {
            let appID = pending.removeFirst(); pendingIDs.remove(appID)
            guard images[appID] == nil, inFlight[appID] == nil else { continue }
            let token = UUID(), requestGeneration = generation
            inFlight[appID] = token
            tasks[token] = Task { [weak self] in
                var result = DecodedArtwork.unavailable
                do {
                    try Task.checkCancellation()
                    let data = try await fetchArtwork(client, appID)
                    try Task.checkCancellation()
                    // Image source inspection and decompression both run off MainActor.
                    // Keep this worker slot until even a noninterruptible ImageIO call
                    // finishes, and propagate cancellation to the detached operation.
                    let decodeTask = Task.detached(priority: .utility) {
                        autoreleasepool { Self.decode(data) }
                    }
                    result = await withTaskCancellationHandler {
                        await decodeTask.value
                    } onCancel: {
                        decodeTask.cancel()
                    }
                } catch {
                    // Artwork failure leaves the app's titled fallback usable. Do not
                    // log request URLs, credentials, or host response bodies here.
                }
                self?.finish(token: token, appID: appID, generation: requestGeneration,
                             result: result, cancelled: Task.isCancelled)
            }
        }
    }

    private func finish(token: UUID, appID: Int, generation: UUID, result: DecodedArtwork, cancelled: Bool) {
        tasks.removeValue(forKey: token)
        guard generation == self.generation else { pump(); return }
        if inFlight[appID] == token { inFlight.removeValue(forKey: appID) }
        if !cancelled {
            switch result {
            case .image(let image):
                retryAfter.removeValue(forKey: appID)
                placeholderIDs.remove(appID)
                insert(image, for: appID)
            case .placeholder:
                placeholderIDs.insert(appID)
                deferRetry(appID, seconds: 600)
            case .unavailable:
                deferRetry(appID, seconds: 60)
            }
        }
        pump()
    }

    private func deferRetry(_ appID: Int, seconds: Int64) {
        // No timers or automatic retries: a later explicit load may retry after this
        // cooldown. Missing artwork cannot generate a continuous request loop.
        retryAfter[appID] = ContinuousClock.now.advanced(by: .seconds(seconds))
        if retryAfter.count > maximumRetryEntries,
           let oldest = retryAfter.min(by: { $0.value < $1.value })?.key {
            retryAfter.removeValue(forKey: oldest); placeholderIDs.remove(oldest)
        }
    }

    private func touch(_ appID: Int) {
        accessSerial &+= 1; recency[appID] = accessSerial
    }

    private func insert(_ image: CGImage, for appID: Int) {
        let (cost, overflow) = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        guard !overflow, cost > 0, cost <= maximumBytes else { deferRetry(appID, seconds: 60); return }
        var updated = images
        cachedBytes -= costs[appID] ?? 0
        costs[appID] = cost; cachedBytes += cost; touch(appID)
        updated[appID] = image
        while updated.count > maximumEntries || cachedBytes > maximumBytes {
            guard let oldest = recency.min(by: { $0.value < $1.value })?.key else { break }
            cachedBytes -= costs.removeValue(forKey: oldest) ?? 0
            recency.removeValue(forKey: oldest); updated.removeValue(forKey: oldest)
        }
        images = updated
    }

    private enum DecodedArtwork: Sendable {
        case image(CGImage), placeholder, unavailable
    }

    nonisolated private static func decode(_ data: Data) -> DecodedArtwork {
        guard !Task.isCancelled, !data.isEmpty, data.count <= 4 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetStatus(source) == .statusComplete, CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              (1...4096).contains(width), (1...4096).contains(height), width * height <= 8_388_608 else { return .unavailable }
        // Moonlight Qt AppView.qml recognizes these exact original dimensions.
        // Its app-collector exemption cannot be reproduced because RemoteApp has no
        // such flag. Genuine covers with the same dimensions can be false positives;
        // expose the classification separately so the UI can revise that policy.
        if (width == 130 && height == 180) || (width == 628 && height == 888) || (width == 200 && height == 266) {
            return .placeholder
        }
        guard !Task.isCancelled else { return .unavailable }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width > 0, image.width <= 512, image.height > 0, image.height <= 512,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete, !Task.isCancelled else { return .unavailable }
        return .image(image)
    }
}
