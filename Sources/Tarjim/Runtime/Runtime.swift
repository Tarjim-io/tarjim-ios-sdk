import Foundation

/// Opened once; `wait` blocks a plain thread (never a task) until it is open or the bound passes.
final class ReadyLatch: @unchecked Sendable {
    // An NSCondition rather than a semaphore: any number of waiters, and opening is idempotent.
    private let condition = NSCondition()
    private var opened = false

    var isOpen: Bool {
        condition.lock()
        defer { condition.unlock() }
        return opened
    }

    func open() {
        condition.lock()
        opened = true
        condition.broadcast()
        condition.unlock()
    }

    /// Whether the latch was open by the bound.
    func wait(upTo bound: TimeInterval) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        // The remaining time is recomputed from a monotonic clock on every wakeup: a wall-clock change must not stretch
        // the bound, and a spurious wakeup must not end it early.
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, bound) * 1_000_000_000)
        while !opened {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline else { break }
            _ = condition.wait(until: Date(timeIntervalSinceNow: Double(deadline - now) / 1_000_000_000))
        }
        return opened
    }
}

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
        private var startFinished = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var launchBegun = false
        private var proxyInstalled = false
        let readiness = ReadyLatch()

        /// The timers run exactly while the app is active.
        var isActive: Bool { lock.withLock { probationTask != nil } }

        /// True the first time only.
        func markLaunchBegun() -> Bool {
            lock.withLock {
                defer { launchBegun = true }
                return !launchBegun
            }
        }

        /// True the first time only.
        func markProxyInstalled() -> Bool {
            lock.withLock {
                defer { proxyInstalled = true }
                return !proxyInstalled
            }
        }

        func finishStart() {
            let waiters = lock.withLock {
                startFinished = true
                defer { startWaiters = [] }
                return startWaiters
            }
            for waiter in waiters { waiter.resume() }
        }

        func waitForStart() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let ready = lock.withLock { () -> Bool in
                    if !startFinished { startWaiters.append(continuation) }
                    return startFinished
                }
                if ready { continuation.resume() }
            }
        }

        /// Replaces the probation timer, only while the app is active (a timer exists).
        func restartProbation(_ make: () -> Task<Void, Never>) {
            lock.withLock {
                guard let running = probationTask else { return }
                running.cancel()
                probationTask = make()
            }
        }

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
    private let lifecycle = LifecycleQueue()

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
        let queue = lifecycle
        resolver = Resolver(app: AppResources(bundle: environment.appBundle, language: environment.appLanguage()),
                            defaultBundle: configuration.defaultBundle, snapshot: { snapshots.current })
        // Weak, so a runtime nobody holds can end; its deinit finishes the stream.
        Task { [weak self] in
            for await _ in queue.wakeups {
                // Changes that arrived together net out: a resign straight followed by a become leaves the app active.
                guard let self, let latest = queue.takeLatest() else { continue }
                guard latest != parts.isActive else { continue }
                if latest { await becameActive() } else { await resignedActive() }
            }
        }
    }

    deinit { lifecycle.finish() }

    /// The longest `launch` holds its caller: a stuck disk must not hold the main thread until the system ends the launch.
    static let launchBound: TimeInterval = 1

    /// For `Tarjim.start` on the main thread: installs the main-bundle proxy, starts `start(foreground:)`, and waits up
    /// to `bound` seconds until lookups serve what this launch shows. Returns whether they do; past the bound they
    /// catch up in the background. A second call starts nothing.
    func launch(foreground: Bool, waitingUpTo bound: TimeInterval) -> Bool {
        installMainBundleProxy()
        if parts.markLaunchBegun() {
            // The caller blocks below, so the launch must not run at a lower priority than the thread it holds up.
            Task.detached(priority: .userInitiated) { [self] in await start(foreground: foreground) }
        }
        return parts.readiness.wait(upTo: bound)
    }

    /// Returns once the launch has finished, so what follows it sees the engine.
    func waitForLaunch() async { await parts.waitForStart() }

    /// Whichever entry runs first installs it; the main bundle is patched once.
    private func installMainBundleProxy() {
        guard configuration.interceptsMainBundle, parts.markProxyInstalled() else { return }
        let resolver = resolver
        MainBundleProxy.install(on: environment.appBundle) { key, table in resolver.downloaded(key, table: table) }
    }

    /// Launches the engine, cleans up, and reports a revert. Once per instance.
    func start(foreground: Bool) async {
        guard parts.markStarted() else { return }
        // `ready` is idempotent; this covers a launch that ends without the engine reaching it.
        defer { parts.finishStart(); parts.readiness.open() }
        installMainBundleProxy()
        let identifier = configuration.sendsInstallIdentifier ? await installIdentifier() : nil
        let identity = ClientIdentity(sdkVersion: environment.sdkVersion, appVersion: environment.appVersion,
                                      osVersion: environment.osVersion, language: environment.appLanguage(),
                                      installIdentifier: identifier)
        let client = DeliveryClient(endpoint: endpoint, identity: identity, transport: environment.transport)
        let parts = self.parts
        let engine = Engine(EngineEnvironment(
            store: store, client: client, snapshots: snapshots, preferences: environment.preferences,
            appLanguage: environment.appLanguage, fallbackLanguage: configuration.fallbackLanguage,
            now: environment.now, random: environment.random,
            // An install shown mid-session is proven by the foreground time after it, not before.
            activated: { [self] in parts.restartProbation(makeProbationTask) },
            ready: { parts.readiness.open() }))
        parts.engine = engine
        // The stream is opened before the launch so no event is missed.
        let events = engine.updates()
        Task.detached {
            for await update in events {
                parts.broadcast(update)
            }
        }
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

    func setLanguage(_ identifier: String?) async {
        guard let engine = parts.engine else {
            // The launch that follows reads the stored choice.
            do {
                try await store.update { $0.languageOverride = identifier }
            } catch {
                Log.debug("The language choice could not be saved (\(error))")
            }
            return
        }
        await engine.setLanguageOverride(identifier)
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
        parts.startTasks(probation: makeProbationTask, schedule: { Task { [self] in await runSchedule(iterations: nil) } })
        await didBecomeActive(afterBackground: parts.timeAway(now: environment.now()))
    }

    private func makeProbationTask() -> Task<Void, Never> {
        Task { [self] in
            await environment.sleep(Engine.probationSeconds)
            guard !Task.isCancelled else { return }
            await parts.engine?.foregroundElapsed(Engine.probationSeconds)
        }
    }

    /// For the system's notifications, which arrive in order but would run as unordered tasks: queues the change and
    /// returns at once; queued changes are applied one at a time, in the order they were noted.
    func noteBecameActive() { lifecycle.note(true) }

    func noteResignedActive() { lifecycle.note(false) }

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
        // A check before `start` has built the engine would find nothing to run.
        await parts.waitForStart()
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

/// The key stays out of anything that prints or dumps a runtime.
extension Runtime: CustomReflectable {
    var customMirror: Mirror { Mirror(self, children: []) }
}

/// Lifecycle changes noted in order from any thread; the runtime applies them from one task.
private final class LifecycleQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Bool] = []
    private let signal: AsyncStream<Void>.Continuation
    let wakeups: AsyncStream<Void>

    init() {
        (wakeups, signal) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func note(_ active: Bool) {
        lock.withLock { pending.append(active) }
        signal.yield()
    }

    /// The last change noted since the previous call.
    func takeLatest() -> Bool? {
        lock.withLock {
            defer { pending = [] }
            return pending.last
        }
    }

    func finish() { signal.finish() }
}
