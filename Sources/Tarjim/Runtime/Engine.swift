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
    /// Called synchronously, inside the activation lock, right after an install is activated.
    var activated: @Sendable () -> Void = {}
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
    private var launchTask: Task<Void, Never>?
    private var launchedInBackground = false
    private var foregroundLaunchCounted = false
    private var foregroundSeconds: TimeInterval = 0
    /// The checksum of the release the last foreground launch reverted, if any.
    private(set) var revertedChecksum: String?
    private var exclusiveBusy = false
    private var exclusiveWaiters: [CheckedContinuation<Void, Never>] = []

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

    /// Once per process; a second call only waits for the first. A launch the system makes in the background neither
    /// activates nor counts toward a revert.
    func launch(foreground: Bool) async {
        if launchTask == nil {
            launchedInBackground = !foreground
            launchTask = Task { await self.performLaunch(foreground: foreground) }
        }
        await launchTask?.value
    }

    /// Runs one update cycle if due and acts on its result.
    @discardableResult
    func check() async -> CycleReport {
        // Before launch has begun a cycle could install and activate ahead of the crash count.
        guard let launchTask else { return CycleReport(outcome: .notDue, nextCheckIn: 0) }
        await launchTask.value
        await refreshOverride()
        let state = await environment.store.state
        let known = (state.pending ?? state.active)?.checksum
        let report = await cycle.run()
        await handle(report, knownChecksum: known)
        return report
    }

    /// The selected locales may have changed: serve them if held, fetch them if the held manifest lists them.
    func selectionChanged() async {
        await launchTask?.value
        await refreshOverride()
        await exclusive { await rebuildSnapshot() }
        let state = await environment.store.state
        guard let active = state.active, let selection = environment.snapshots.current.selection,
              !holds(active, locales: selection.locales, bundleIds: bundleIds(of: active)) else { return }
        let known = (state.pending ?? active).checksum
        await handle(await cycle.languageChanged(), knownChecksum: known)
    }

    /// The process came to the foreground. The first time, for a process the system launched in the background, this
    /// counts as its foreground launch.
    func enteredForeground() async {
        await launchTask?.value
        guard launchedInBackground, !foregroundLaunchCounted else { return }
        foregroundLaunchCounted = true
        await exclusive {
            await foregroundLaunchSteps()
            await rebuildSnapshot()
        }
    }

    /// Foreground time accumulated in this process.
    func foregroundElapsed(_ seconds: TimeInterval) async {
        guard let launchTask else { return }
        await launchTask.value
        guard seconds.isFinite, seconds >= 0 else { return }
        // Inside the activation lock, so a tick never closes the probation of an install activated meanwhile.
        await exclusive {
            // A timer cancelled by an activation while this waited for the lock must not count toward the new install.
            guard !Task.isCancelled else { return }
            foregroundSeconds += seconds
            guard foregroundSeconds >= Engine.probationSeconds else { return }
            let store = environment.store
            guard let open = await store.state.probation else { return }
            try? await store.update { state in
                guard state.probation == open else { return }
                state.probation = nil
                state.launchCrashCount = 0
            }
        }
    }

    func didBecomeActive(afterBackground seconds: TimeInterval) async {
        await launchTask?.value
        guard seconds >= Engine.longBackgroundSeconds else { return }
        _ = await activatePendingUpdate()
    }

    func activatePendingUpdate() async -> Bool {
        // Before the launch has begun it would run ahead of the crash count and could hide a revert; the launch
        // itself shows a pending install.
        guard let launchTask else { return false }
        await launchTask.value
        return await exclusive {
            guard let pending = await environment.store.state.pending else { return false }
            return await activate(pending)
        }
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

    /// Activation, revert and the snapshot swap that follows them run one at a time, so none interleaves with another.
    private func exclusive<T>(_ body: () async -> T) async -> T {
        if exclusiveBusy {
            await withCheckedContinuation { exclusiveWaiters.append($0) }
        } else {
            exclusiveBusy = true
        }
        let result = await body()
        if exclusiveWaiters.isEmpty {
            exclusiveBusy = false
        } else {
            exclusiveWaiters.removeFirst().resume()
        }
        return result
    }

    private func performLaunch(foreground: Bool) async {
        await refreshOverride()
        await exclusive {
            if foreground {
                foregroundLaunchCounted = true
                await foregroundLaunchSteps()
            }
            await rebuildSnapshot()
        }
    }

    private func activate(_ install: InstallRecord) async -> Bool {
        let store = environment.store
        let current = await store.state
        // An install that is already the active one has nothing to show and must not restart its probation.
        guard !current.badChecksums.contains(install.checksum), current.active?.directory != install.directory,
              isOnDisk(install) else { return false }
        let directory = install.directory
        do {
            try await store.activate(install) { state in
                state.probation = directory
                state.launchCrashCount = 0
            }
        } catch { return false }
        // The new install's probation starts from zero, whatever this process has already spent in the foreground.
        foregroundSeconds = 0
        environment.activated()
        await rebuildSnapshot()
        box.send(.activated)
        return true
    }

    /// Counts a cut-short previous launch, reverts after two, otherwise shows a pending install.
    private func foregroundLaunchSteps() async {
        let store = environment.store
        var reverted = false
        var revertedChecksum: String?
        try? await store.update { state in
            guard let probation = state.probation else { return }
            // Probation naming anything but the active install is stale; nothing to blame.
            guard state.active?.directory == probation else {
                state.probation = nil
                state.launchCrashCount = 0
                return
            }
            state.launchCrashCount += 1
            guard state.launchCrashCount >= 2, let active = state.active else { return }
            reverted = true
            revertedChecksum = active.checksum
            state.badChecksums.insert(active.checksum)
            if let previous = state.previous, !state.badChecksums.contains(previous.checksum),
               Engine.isDirectory(store.url(of: previous)) {
                state.active = previous
                state.probation = previous.directory
            } else {
                state.active = nil
                state.probation = nil
            }
            state.previous = nil
            if let pending = state.pending, state.badChecksums.contains(pending.checksum) { state.pending = nil }
            state.launchCrashCount = 0
        }
        foregroundSeconds = 0
        if let revertedChecksum { self.revertedChecksum = revertedChecksum }
        if !reverted, let pending = await store.state.pending {
            _ = await activate(pending)
        }
    }

    private func handle(_ report: CycleReport, knownChecksum: String?) async {
        guard case .installed(let install) = report.outcome else { return }
        if install.checksum != knownChecksum { box.send(.downloaded) }
        await exclusive {
            if servesNothing() { _ = await activate(install) }
        }
    }

    /// True when the current snapshot gives the user nothing from the active install.
    private func servesNothing() -> Bool {
        let snapshot = environment.snapshots.current
        guard let directory = snapshot.installDirectory, let selection = snapshot.selection else { return true }
        return !Engine.holds(directory, locales: selection.locales, bundleIds: snapshot.entries.map(\.id))
    }

    // MARK: Snapshot

    private func rebuildSnapshot() async {
        let store = environment.store
        guard let active = await store.state.active else {
            environment.snapshots.replace(.empty)
            return
        }
        guard let manifest = readManifest(of: active) else {
            // The next check installs the release again; its files are reused by hash.
            try? await store.update { state in
                state.active = nil
                state.probation = nil
                state.launchCrashCount = 0
            }
            environment.snapshots.replace(.empty)
            return
        }
        let entries = manifest.bundles.map { ManifestBundle(id: $0.key, type: $0.value.type, name: $0.value.name) }
            .sorted { $0.id < $1.id }
        let selection = LocaleSelector.select(
            available: Engine.locales(of: manifest), preferences: environment.preferences(),
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
        Engine.isDirectory(environment.store.url(of: install))
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func readManifest(of install: InstallRecord) -> Manifest? {
        guard let raw = try? Data(contentsOf: environment.store.url(of: install).appendingPathComponent("manifest.json"))
        else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: raw)
    }

    private static func locales(of manifest: Manifest) -> [String] {
        Set(manifest.slices.values.flatMap(\.keys)).sorted()
    }

    private func bundleIds(of install: InstallRecord) -> [String] {
        readManifest(of: install).map { Array($0.bundles.keys) } ?? []
    }

    private func holds(_ install: InstallRecord, locales: [String], bundleIds: [String]) -> Bool {
        Engine.holds(environment.store.url(of: install), locales: locales, bundleIds: bundleIds)
    }

    /// True when the install has a localization directory for at least one of the locales.
    private static func holds(_ root: URL, locales: [String], bundleIds: [String]) -> Bool {
        locales.contains { locale in
            bundleIds.contains { id in isDirectory(root.appendingPathComponent("\(id).bundle/\(locale).lproj")) }
        }
    }
}
