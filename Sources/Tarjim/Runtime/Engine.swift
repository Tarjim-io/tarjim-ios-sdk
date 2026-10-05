import Foundation

/// What the app hears about, on a real change only.
public enum TarjimUpdate: Equatable, Sendable {
    /// A new release was downloaded; it is shown at the next cold start, on a return after a long time away, or when
    /// the app calls `activatePendingUpdate()`.
    case downloaded
    /// Lookups now read a different install.
    case activated
}

struct EngineEnvironment: Sendable {
    let store: Store
    let client: DeliveryClient
    let snapshots: SnapshotHolder
    /// The device's preferred languages, read at each selection.
    let preferences: @Sendable () -> [String]
    /// The app's active localization, read at each selection.
    let appLanguage: @Sendable () -> String
    let fallbackLanguage: String
    let now: @Sendable () -> Date
    let random: @Sendable () -> Double
}

/// Event streams and the language override, read from synchronous contexts.
private final class EngineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<TarjimUpdate>.Continuation] = [:]
    private var languageOverride: String?

    var override: String? {
        get { lock.withLock { languageOverride } }
        set { lock.withLock { languageOverride = newValue } }
    }

    func add(_ continuation: AsyncStream<TarjimUpdate>.Continuation) -> UUID {
        let id = UUID()
        lock.withLock { continuations[id] = continuation }
        return id
    }

    func remove(_ id: UUID) {
        lock.withLock { _ = continuations.removeValue(forKey: id) }
    }

    func send(_ update: TarjimUpdate) {
        let live = lock.withLock { Array(continuations.values) }
        for continuation in live { continuation.yield(update) }
    }
}

/// Decides what lookups read: activation, the launch-crash revert, events and the snapshot swap.
actor Engine {
    /// Foreground time after which a newly activated install is trusted.
    static let probationSeconds: TimeInterval = 10
    /// Time in the background after which a pending install is shown on return.
    static let longBackgroundSeconds: TimeInterval = 3600

    private let environment: EngineEnvironment
    private let cycle: UpdateCycle
    private let box = EngineBox()
    private var launched = false
    private var foregroundSeconds: TimeInterval = 0

    init(_ environment: EngineEnvironment) {
        self.environment = environment
        let box = self.box
        let preferences = environment.preferences, appLanguage = environment.appLanguage
        let fallback = environment.fallbackLanguage
        self.cycle = UpdateCycle(CycleEnvironment(
            client: environment.client, store: environment.store, now: environment.now, random: environment.random,
            selectLocales: { available in
                LocaleSelector.select(available: available, preferences: preferences(), appLanguage: appLanguage(),
                                      override: box.override, fallbackLanguage: fallback)?.locales ?? []
            }))
    }

    /// Once per process; a second call does nothing. A launch the system makes in the background neither activates
    /// nor counts toward a revert.
    func launch(foreground: Bool) async {
        guard !launched else { return }
        launched = true
        await refreshOverride()
        if foreground {
            await countLaunchAndSettle()
        }
        await rebuildSnapshot()
    }

    /// Runs one update cycle if due and acts on its result.
    @discardableResult
    func check() async -> CycleReport {
        await refreshOverride()
        let report = await cycle.run()
        await handle(report)
        return report
    }

    /// The selected locales may have changed: serve them if held, fetch them if the held manifest lists them.
    func selectionChanged() async {
        await refreshOverride()
        await rebuildSnapshot()
        let state = await environment.store.state
        guard let active = state.active, let selection = environment.snapshots.current.selection,
              !holds(active, locales: selection.locales, bundleIds: bundleIds(of: active)) else { return }
        await handle(await cycle.languageChanged())
    }

    /// Foreground time accumulated in this process.
    func foregroundElapsed(_ seconds: TimeInterval) async {
        foregroundSeconds += seconds
        guard foregroundSeconds >= Engine.probationSeconds else { return }
        var state = await environment.store.state
        guard state.probation != nil else { return }
        state.probation = nil
        state.launchCrashCount = 0
        try? await environment.store.save(state)
    }

    func didBecomeActive(afterBackground seconds: TimeInterval) async {
        guard seconds >= Engine.longBackgroundSeconds else { return }
        _ = await activatePendingUpdate()
    }

    func activatePendingUpdate() async -> Bool {
        guard let pending = await environment.store.state.pending else { return false }
        return await activate(pending)
    }

    nonisolated func updates() -> AsyncStream<TarjimUpdate> {
        let (stream, continuation) = AsyncStream<TarjimUpdate>.makeStream()
        let box = self.box
        let id = box.add(continuation)
        continuation.onTermination = { _ in box.remove(id) }
        return stream
    }

    /// The locales lookups currently serve, nil before the first install or when none matches.
    var selection: LocaleSelection? {
        environment.snapshots.current.selection
    }

    // MARK: Activation

    private func activate(_ install: InstallRecord) async -> Bool {
        let store = environment.store
        let state = await store.state
        guard !state.badChecksums.contains(install.checksum), isOnDisk(install) else { return false }
        do { try await store.activate(install) } catch { return false }
        var fresh = await store.state
        fresh.probation = install.directory
        fresh.launchCrashCount = 0
        try? await store.save(fresh)
        // The new install's probation starts from zero, whatever this process has already spent in the foreground.
        foregroundSeconds = 0
        await rebuildSnapshot()
        box.send(.activated)
        return true
    }

    private func countLaunchAndSettle() async {
        let store = environment.store
        var state = await store.state
        if state.probation != nil {
            state.launchCrashCount += 1
            try? await store.save(state)
        }
        if state.launchCrashCount >= 2 {
            await revert()
        } else if let pending = state.pending {
            _ = await activate(pending)
        }
    }

    private func revert() async {
        let store = environment.store
        var state = await store.state
        guard let active = state.active else { return }
        state.badChecksums.insert(active.checksum)
        if let previous = state.previous, !state.badChecksums.contains(previous.checksum), isOnDisk(previous) {
            state.active = previous
        } else {
            state.active = nil
        }
        state.previous = nil
        if let pending = state.pending, state.badChecksums.contains(pending.checksum) { state.pending = nil }
        state.probation = nil
        state.launchCrashCount = 0
        try? await store.save(state)
    }

    private func handle(_ report: CycleReport) async {
        guard case .installed(let install) = report.outcome else { return }
        box.send(.downloaded)
        let active = await environment.store.state.active
        guard let active else {
            _ = await activate(install)
            return
        }
        let ids = bundleIds(of: install)
        let locales = LocaleSelector.select(
            available: availableLocales(of: install), preferences: environment.preferences(),
            appLanguage: environment.appLanguage(), override: box.override,
            fallbackLanguage: environment.fallbackLanguage)?.locales ?? []
        if !holds(active, locales: locales, bundleIds: ids) { _ = await activate(install) }
    }

    // MARK: Snapshot

    private func rebuildSnapshot() async {
        let store = environment.store
        guard let active = await store.state.active else {
            environment.snapshots.replace(.empty)
            return
        }
        let manifest = readManifest(of: active)
        let entries = (manifest?.bundles ?? [:]).map { ManifestBundle(id: $0.key, type: $0.value.type, name: $0.value.name) }
            .sorted { $0.id < $1.id }
        let selection = LocaleSelector.select(
            available: manifest.map(Engine.locales) ?? [], preferences: environment.preferences(),
            appLanguage: environment.appLanguage(), override: box.override,
            fallbackLanguage: environment.fallbackLanguage)
        environment.snapshots.replace(Snapshot(installDirectory: store.url(of: active), entries: entries, selection: selection))
        await store.protect(active)
    }

    private func refreshOverride() async {
        box.override = await environment.store.state.languageOverride
    }

    // MARK: Install contents

    private func isOnDisk(_ install: InstallRecord) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: environment.store.url(of: install).path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func readManifest(of install: InstallRecord) -> Manifest? {
        guard let raw = try? Data(contentsOf: environment.store.url(of: install).appendingPathComponent("manifest.json"))
        else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: raw)
    }

    private static func locales(of manifest: Manifest) -> [String] {
        Set(manifest.slices.values.flatMap(\.keys)).sorted()
    }

    private func availableLocales(of install: InstallRecord) -> [String] {
        readManifest(of: install).map(Engine.locales) ?? []
    }

    private func bundleIds(of install: InstallRecord) -> [String] {
        readManifest(of: install).map { Array($0.bundles.keys) } ?? []
    }

    /// True when the install has a localization directory for at least one of the locales.
    private func holds(_ install: InstallRecord, locales: [String], bundleIds: [String]) -> Bool {
        let root = environment.store.url(of: install)
        return locales.contains { locale in
            bundleIds.contains { id in
                var isDirectory: ObjCBool = false
                let path = root.appendingPathComponent("\(id).bundle/\(locale).lproj").path
                return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
        }
    }
}
