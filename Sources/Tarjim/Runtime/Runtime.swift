import Foundation

/// One started SDK: the store, the engine, the reporter and the lookups, wired together. `Tarjim` holds one.
final class Runtime: Sendable {
    struct Environment: Sendable {
        let root: URL
        let transport: any Transport
        let appBundle: Bundle
        let preferences: @Sendable () -> [String]
        let appLanguage: @Sendable () -> String
        let now: @Sendable () -> Date
        let random: @Sendable () -> Double
        /// Waits between scheduled checks.
        let sleep: @Sendable (TimeInterval) async -> Void
        let sdkVersion: String
        let appVersion: String
        let osVersion: String
    }

    /// What `start` builds, read from synchronous lookups.
    private final class Parts: @unchecked Sendable {
        private let lock = NSLock()
        private var startedFlag = false
        private var engineValue: Engine?
        private var scheduleTask: Task<Void, Never>?
        private var probationTask: Task<Void, Never>?
        private var resignedAt: Date?

        /// True the first time only.
        func markStarted() -> Bool {
            lock.withLock {
                defer { startedFlag = true }
                return !startedFlag
            }
        }

        private var subscribers: [UUID: AsyncStream<TarjimUpdate>.Continuation] = [:]

        func subscribe(_ continuation: AsyncStream<TarjimUpdate>.Continuation) -> UUID {
            let id = UUID()
            lock.withLock { subscribers[id] = continuation }
            return id
        }

        func unsubscribe(_ id: UUID) {
            lock.withLock { _ = subscribers.removeValue(forKey: id) }
        }

        func broadcast(_ update: TarjimUpdate) {
            let live = lock.withLock { Array(subscribers.values) }
            for continuation in live { continuation.yield(update) }
        }

        var engine: Engine? {
            get { lock.withLock { engineValue } }
            set { lock.withLock { engineValue = newValue } }
        }

        /// Starts each task unless one runs.
        func startTasks(probation: () -> Task<Void, Never>, schedule: () -> Task<Void, Never>) {
            lock.withLock {
                if probationTask == nil { probationTask = probation() }
                if scheduleTask == nil { scheduleTask = schedule() }
            }
        }

        /// Cancels both tasks and records when the app resigned.
        func stopTasks(at now: Date) {
            let tasks: [Task<Void, Never>] = lock.withLock {
                defer { scheduleTask = nil; probationTask = nil; resignedAt = now }
                return [scheduleTask, probationTask].compactMap { $0 }
            }
            for task in tasks { task.cancel() }
        }

        /// Seconds since the app resigned, 0 when it never did; consumed.
        func timeAway(now: Date) -> TimeInterval {
            lock.withLock {
                defer { resignedAt = nil }
                return resignedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
            }
        }
    }

    let configuration: TarjimConfiguration
    private let environment: Environment
    private let endpoint: DeliveryEndpoint
    private let store: Store
    private let snapshots = SnapshotHolder()
    private let reporter: Reporter
    private let resolver: Resolver
    private let parts = Parts()

    init(configuration: TarjimConfiguration, environment: Environment) throws {
        self.configuration = configuration
        self.environment = environment
        endpoint = try DeliveryEndpoint(host: configuration.host, projectId: configuration.projectId, apiKey: configuration.apiKey)
        store = try Store(
            root: environment.root,
            identifier: StoreIdentifier.make(host: configuration.host, projectId: configuration.projectId, apiKey: configuration.apiKey),
            sdkVersion: environment.sdkVersion)
        reporter = Reporter(store: store, handler: configuration.onReport)
        // Lookups mean the same before and after `start`: the snapshot is empty until the engine has built one.
        let snapshots = self.snapshots
        resolver = Resolver(app: AppResources(bundle: environment.appBundle, language: environment.appLanguage()),
                            defaultBundle: configuration.defaultBundle, snapshot: { snapshots.current })
    }

    /// Launches the engine, cleans up, and reports a revert. Once per instance.
    func start(foreground: Bool) async {
        guard parts.markStarted() else { return }
        let identifier = configuration.sendsInstallIdentifier ? await installIdentifier() : nil
        let identity = ClientIdentity(sdkVersion: environment.sdkVersion, appVersion: environment.appVersion,
                                      osVersion: environment.osVersion, language: environment.appLanguage(),
                                      installIdentifier: identifier)
        let client = DeliveryClient(endpoint: endpoint, identity: identity, transport: environment.transport)
        let engine = Engine(EngineEnvironment(
            store: store, client: client, snapshots: snapshots, preferences: environment.preferences,
            appLanguage: environment.appLanguage, fallbackLanguage: configuration.fallbackLanguage,
            now: environment.now, random: environment.random))
        parts.engine = engine
        // The stream is opened before the launch so no event is missed.
        let events = engine.updates()
        let parts = self.parts
        Task.detached { for await update in events { parts.broadcast(update) } }
        await engine.launch(foreground: foreground)
        await reportRevert(of: engine)

        _ = try? await store.cleanup()
    }

    /// The identifier in state, else a new one saved there.
    private func installIdentifier() async -> String? {
        if let held = await store.state.installIdentifier { return held }
        let created = UUID().uuidString
        try? await store.update { state in
            if state.installIdentifier == nil { state.installIdentifier = created }
        }
        return await store.state.installIdentifier
    }

    private func reportRevert(of engine: Engine) async {
        if let checksum = await engine.revertedChecksum { await reporter.reverted(checksum: checksum) }
    }

    func string(_ key: String, bundle: TarjimBundle?) -> String {
        resolver.string(key, bundle: bundle)
    }

    func string(_ key: String, arguments: [CVarArg], bundle: TarjimBundle?) -> String {
        resolver.string(key, arguments: arguments, bundle: bundle)
    }

    var locale: Locale {
        if let first = snapshots.current.selection?.locales.first { return Locale(identifier: first) }
        return Locale(identifier: environment.appLanguage())
    }

    /// One check now, with its report passed to the reporter.
    @discardableResult
    func checkNow() async -> CycleReport {
        // Before `start` has built the engine there is nothing to check; try again in an hour.
        guard let engine = parts.engine else { return CycleReport(outcome: .failed, nextCheckIn: 3600) }
        let report = await engine.check()
        await reporter.cycleFinished(report)
        return report
    }

    func activatePendingUpdate() async -> Bool {
        guard let engine = parts.engine else { return false }
        return await engine.activatePendingUpdate()
    }

    /// Streams are the runtime's own, so one opened before `start` still hears what the engine reports afterwards.
    func updates() -> AsyncStream<TarjimUpdate> {
        let (stream, continuation) = AsyncStream<TarjimUpdate>.makeStream()
        let parts = self.parts
        let id = parts.subscribe(continuation)
        continuation.onTermination = { _ in parts.unsubscribe(id) }
        return stream
    }

    /// The app became active: a process the system launched in the background counts as launched now, and the
    /// probation timer and the update schedule run until `resignedActive()`.
    func becameActive() async {
        parts.startTasks(
            probation: {
                Task { [self] in
                    await environment.sleep(Engine.probationSeconds)
                    guard !Task.isCancelled else { return }
                    await parts.engine?.foregroundElapsed(Engine.probationSeconds)
                }
            },
            schedule: { Task { [self] in await runSchedule(iterations: nil) } })
        await didBecomeActive(afterBackground: parts.timeAway(now: environment.now()))
    }

    /// The app is no longer active: nothing runs until it is again.
    func resignedActive() async {
        parts.stopTasks(at: environment.now())
    }

    func didBecomeActive(afterBackground seconds: TimeInterval) async {
        guard let engine = parts.engine else { return }
        await engine.enteredForeground()
        await reportRevert(of: engine)
        await engine.didBecomeActive(afterBackground: seconds)
    }

    /// The timer while the app is active: the launch delay, then a check every `nextCheckIn`. Stops after
    /// `iterations` checks (nil: until cancelled).
    func runSchedule(iterations: Int?) async {
        await environment.sleep(Schedule.launchDelay(random: environment.random()))
        var done = 0
        while !Task.isCancelled {
            let report = await checkNow()
            done += 1
            if let iterations, done >= iterations { return }
            await environment.sleep(report.nextCheckIn)
        }
    }

    /// The app's active localization; a storyboard-only app reports "Base", which is never a language.
    static func appLanguage(of bundle: Bundle) -> String {
        if let first = bundle.preferredLocalizations.first, first != "Base" { return first }
        return bundle.infoDictionary?["CFBundleDevelopmentRegion"] as? String ?? "en"
    }
}
