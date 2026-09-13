// Appended to exact production source. These extensions expose private state only
// inside this standalone executable; no testing API enters the app binary.
private extension AppArtworkStore {
    var harnessIdle: Bool { tasks.isEmpty && pending.isEmpty }
    var harnessSlotCount: Int { tasks.count }
    var harnessCost: Int { cachedBytes }
    var harnessRetryCount: Int { retryAfter.count }
    func harnessInsert(_ image: CGImage, id: Int) { insert(image, for: id) }
    func harnessTouch(_ id: Int) { touch(id) }
    func harnessFailures(_ count: Int) { for id in 1...count { deferRetry(id, seconds: 60) } }
    nonisolated static func harnessDecode(_ data: Data) -> (kind: String, width: Int, height: Int) {
        switch decode(data) {
        case .image(let image): return ("image", image.width, image.height)
        case .placeholder: return ("placeholder", 0, 0)
        case .unavailable: return ("unavailable", 0, 0)
        }
    }
}
private struct ArtworkHarnessFailure: Error, CustomStringConvertible { let description: String }
private actor ArtworkGate {
    private struct Pending {
        let host: ObjectIdentifier
        let continuation: CheckedContinuation<Data, Never>
    }
    private var pending: [Pending] = []
    private var started = 0, highWater = 0
    func fetch(_ client: HostClient, _ appID: Int) async throws -> Data {
        started += 1
        return await withCheckedContinuation { continuation in
            // Intentionally ignore task cancellation until released, like a slow
            // operation that has not yet retired after its caller cancels it.
            pending.append(Pending(host: ObjectIdentifier(client), continuation: continuation))
            highWater = max(highWater, pending.count)
        }
    }
    func snapshot() -> (waiting: Int, started: Int, highWater: Int) { (pending.count, started, highWater) }
    func release(_ client: HostClient, data: Data) {
        let selected = pending.filter { $0.host == ObjectIdentifier(client) }
        pending.removeAll { $0.host == ObjectIdentifier(client) }
        for item in selected { item.continuation.resume(returning: data) }
    }
}
private actor ArtworkFailureCounter {
    var calls = 0
    func fetch() throws -> Data { calls += 1; throw ArtworkHarnessFailure(description: "injected artwork failure") }
}
@main private struct ArtworkStoreHarness {
    @MainActor static func require(_ value: @autoclosure () -> Bool, _ reason: String) throws {
        if !value() { throw ArtworkHarnessFailure(description: reason) }
    }
    @MainActor static func until(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw ArtworkHarnessFailure(description: "Artwork lifecycle wait timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    static func image(_ width: Int, _ height: Int) throws -> CGImage {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let image = context.makeImage()
        else { throw ArtworkHarnessFailure(description: "Cannot construct in-memory raster fixture") }
        return image
    }
    static func png(_ width: Int, _ height: Int) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
        else { throw ArtworkHarnessFailure(description: "Cannot encode in-memory raster fixture") }
        CGImageDestinationAddImage(destination, try image(width, height), nil)
        guard CGImageDestinationFinalize(destination) else { throw ArtworkHarnessFailure(description: "PNG fixture failed") }
        return data as Data
    }
    @MainActor static func main() async {
        do {
            // Construction is inert: injected closures never call the client's HTTP,
            // serverInfo, artwork, identity, pairing, or Keychain methods.
            let hostA = HostClient(address: try HostAddress(host: "artwork-a.invalid"))
            let hostB = HostClient(address: try HostAddress(host: "artwork-b.invalid"))
            let gate = ArtworkGate()
            let store = AppArtworkStore { client, appID in try await gate.fetch(client, appID) }
            let apps = (1...12).map { RemoteApp(id: $0, name: "Fixture \($0)") }
            let firstFour = Array(apps.prefix(4))
            let a = try png(100, 150), b = try png(160, 240)
            store.load(apps: apps, using: hostA, hostID: "A")
            try await until { await gate.snapshot().waiting == 4 }
            for _ in 0..<20 { store.load(apps: apps, using: hostA, hostID: "A") }
            let coalesced = await gate.snapshot()
            try require(coalesced.started == 4 && store.harnessSlotCount == 4, "Repeated loads exceeded four slots or duplicated requests")
            await gate.release(hostA, data: a)
            try await until {
                let state = await gate.snapshot()
                return store.images.count == 4 && state.waiting == 4
            }
            store.load(apps: firstFour, using: hostB, hostID: "B")
            try require(store.images.isEmpty && store.harnessSlotCount == 4, "Host switch retained images or forgot running operations")
            try await Task.sleep(for: .milliseconds(30))
            let switching = await gate.snapshot()
            try require(switching.started == 8 && switching.waiting == 4, "New host bypassed cancelled operations still occupying slots")
            await gate.release(hostA, data: a)
            try await until { (await gate.snapshot()).started == 12 }
            try require(store.images.isEmpty, "Cancelled old-host image was published")
            await gate.release(hostB, data: b)
            try await until { store.harnessIdle }
            try require(Set(store.images.keys) == Set(1...4), "Old-host queued/result IDs leaked into the new cache")
            try require(store.images.values.allSatisfy { $0.width == 160 && $0.height == 240 }, "Old-host pixels survived host switch")
            let complete = await gate.snapshot()
            for _ in 0..<20 { store.load(apps: firstFour, using: hostB, hostID: "B") }
            try await Task.sleep(for: .milliseconds(30))
            let reused = await gate.snapshot()
            try require(reused.started == complete.started && complete.highWater == 4, "Cached images refetched or global fetch bound exceeded")
            store.cancel(clear: true)
            try require(store.images.isEmpty && store.harnessCost == 0 && store.placeholderIDs.isEmpty, "Clear did not release owned cache")

            let entries = AppArtworkStore()
            let small = try image(8, 8)
            for id in 1...128 { entries.harnessInsert(small, id: id) }
            entries.harnessTouch(1); entries.harnessInsert(small, id: 129)
            try require(entries.images.count == 128 && entries.images[1] != nil && entries.images[2] == nil,
                        "128-cover LRU bound failed")
            let bytes = AppArtworkStore(), large = try image(512, 512)
            for id in 1...80 { bytes.harnessInsert(large, id: id) }
            try require(bytes.harnessCost <= 64 * 1024 * 1024 && bytes.images.count == 64,
                        "64 MiB decoded-byte accounting bound failed")
            let failures = ArtworkFailureCounter()
            let missing = AppArtworkStore { _, _ in try await failures.fetch() }
            missing.load(apps: firstFour, using: hostB, hostID: "B")
            try await until { missing.harnessIdle }
            for _ in 0..<20 { missing.load(apps: firstFour, using: hostB, hostID: "B") }
            let failureCalls = await failures.calls
            try require(failureCalls == 4 && missing.harnessIdle, "Missing-artwork refresh ignored retry cooldown")
            missing.harnessFailures(2048)
            try require(missing.harnessRetryCount == 1024, "Retry metadata exceeded its bound")
            missing.cancel(clear: true)
            try require(missing.harnessRetryCount == 0, "Trust reset retained retry metadata")

            for (width, height) in [(130,180), (628,888), (200,266)] {
                let data = try png(width, height)
                let decoded = await Task.detached { AppArtworkStore.harnessDecode(data) }.value
                try require(decoded.kind == "placeholder", "Known original placeholder dimensions were missed")
            }
            let realCover = try png(200,267), fullCover = try png(2048,1024)
            let real = await Task.detached { AppArtworkStore.harnessDecode(realCover) }.value
            let thumbnail = await Task.detached { AppArtworkStore.harnessDecode(fullCover) }.value
            try require(real.kind == "image" && real.width == 200 && real.height == 267, "Genuine 200x267 cover was suppressed")
            try require(thumbnail.kind == "image" && thumbnail.width == 512 && thumbnail.height == 256, "ImageIO thumbnail bound/aspect ratio failed")
            let invalid = await Task.detached { AppArtworkStore.harnessDecode(Data([0,1,2])) }.value
            try require(invalid.kind == "unavailable", "Invalid raster bytes were accepted")
            let report: [String: Any] = ["status":"PASS", "sourceSHA256":ProcessInfo.processInfo.environment["SWIFTLIGHT_ARTWORK_SOURCE_SHA256"] ?? "",
                "checks":["four slots and coalescing", "four slots across noncooperative cancellation", "stale host pixels rejected", "cache reuse", "clear releases cache", "128-cover LRU", "64 MiB decoded-byte accounting", "missing-cover retry cooldown", "bounded retry metadata", "three placeholder dimensions", "200x267 genuine cover", "512px aspect-preserving ImageIO thumbnail", "invalid raster rejection"],
                "fetchHighWater":complete.highWater, "cacheMaximumBytes":64*1024*1024,
                "hostUsed":false, "keychainUsed":false, "windowOpened":false, "residentMemoryMeasured":false]
            print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]), as: UTF8.self))
        } catch {
            print(String(decoding: try! JSONSerialization.data(withJSONObject: ["status":"FAIL", "reason":String(describing:error)]), as: UTF8.self))
            exit(1)
        }
    }
}
