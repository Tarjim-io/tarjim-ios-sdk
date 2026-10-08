import Foundation

/// Everything a cycle talks to, injected.
struct CycleEnvironment: Sendable {
    let client: DeliveryClient
    let store: Store
    let now: @Sendable () -> Date
    /// In 0..<1; the jitter source.
    let random: @Sendable () -> Double
    /// The manifest's locale keys → the ones to serve, most specific first.
    let selectLocales: @Sendable ([String]) -> [String]
    /// Seconds on a clock that never goes back. It pauses while the device sleeps, so a wait measured on it can
    /// only last longer than the server asked, never shorter.
    let uptime: @Sendable () -> TimeInterval
}

/// A clock for waits that must not follow the user's date.
enum MonotonicClock {
    static func seconds() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

enum RejectionReason: Equatable, Sendable {
    /// A `schemaVersion` this SDK does not know.
    case unknownSchema(Int)
    /// No `strings` file anywhere in the manifest.
    case noStrings
    /// The bytes match `meta.checksum` but do not decode.
    case unreadable
}

enum CycleOutcome: Equatable, Sendable {
    /// `meta` is not due; nothing was requested.
    case notDue
    /// `meta` names what the device already has (a 304 included); owed slots were retried without result.
    case unchanged
    /// A new install was built and recorded as pending.
    case installed(InstallRecord)
    /// `meta` names the active install again while a newer one was pending: the pending one was dropped (a rollback).
    case discardedPending
    /// The manifest was kept out; its checksum is marked rejected.
    case rejected(checksum: String, RejectionReason)
    /// `meta` names a checksum already rejected or marked bad; nothing was fetched.
    case skipped
    /// 404 with nothing released to this stage yet.
    case unreleased
    /// A key or binding problem (400, 401, 403, a missing track or stage): reported to the app; polling continues.
    case configurationError(code: String)
    /// A 5xx, a 429, a network failure, an unreadable `meta` or a manifest that failed its checksum: backing off.
    case failed
}

/// What a cycle observed besides its outcome; reports are derived from these.
enum CycleSignal: Equatable, Sendable {
    /// `meta` answered 200 or 304.
    case metaAnswered
    /// The manifest's bytes did not hash to the checksum `meta` named.
    case manifestChecksumMismatch(metaChecksum: String)
    /// A downloaded file did not hash to the hash the manifest listed.
    case fileHashMismatch(hash: String)
    /// The owed slots' hashes of the newest install known when the cycle ended.
    case owed(hashes: Set<String>)
    /// A new install was built from a manifest of this schema version.
    case installed(schemaVersion: Int, hasStrings: Bool, checksum: String)
    /// `meta` named a checksum that was rejected earlier; nothing was fetched.
    case stillRejected(checksum: String)
}

struct CycleReport: Equatable, Sendable {
    let outcome: CycleOutcome
    /// When to run again, jitter included.
    let nextCheckIn: TimeInterval
    var signals: [CycleSignal] = []
}

/// The update cycle. Records what it builds as pending; activation is not its job.
actor UpdateCycle {
    fileprivate enum Kind { case poll, change }

    private let environment: CycleEnvironment
    private var running: (kind: Kind, task: Task<CycleReport, Never>)?
    /// The cadence of this process. A save that fails must not turn every call into a `meta` read. `backoffUntil` is
    /// on the uptime clock: a request may not read before it, whatever the disk or the date says.
    fileprivate var remembered: (lastCheck: Date, interval: Int, backoffUntil: TimeInterval?)?
    /// What the running cycle has seen; cycles never overlap, so one buffer serves them all.
    fileprivate var seen: [CycleSignal] = []

    init(_ environment: CycleEnvironment) {
        self.environment = environment
    }

    /// A cycle's report, and whether the caller joined a cycle another caller started. Only the starter handles and
    /// reports it: a joiner doing so as well would count one cycle twice.
    struct Shared: Sendable {
        let report: CycleReport
        let joined: Bool
    }

    /// What the starter does with its report; it runs inside the cycle, so a joiner is answered only after it.
    typealias Handling = @Sendable (CycleReport) async -> Void

    /// One cycle if `meta` is due. Concurrent calls share one cycle; one arriving during a language change waits for it.
    func run() async -> CycleReport { await runShared().report }

    func runShared(handling: Handling? = nil) async -> Shared {
        while let current = running {
            if current.kind == .poll { return Shared(report: await current.task.value, joined: true) }
            _ = await current.task.value
        }
        return Shared(report: await start(.poll, handling: handling) { await $0.execute() }, joined: false)
    }

    /// Like `runShared()`, but reads `meta` even when the cadence says it is not due. A failure backoff still holds:
    /// while it runs, this reports `.notDue` without a request.
    func runNowShared(handling: Handling? = nil) async -> Shared {
        while let current = running {
            if current.kind == .poll {
                let report = await current.task.value
                // A scheduled cycle that found nothing due read nothing; this caller still gets its own read.
                if report.outcome == .notDue { continue }
                return Shared(report: report, joined: true)
            }
            _ = await current.task.value
        }
        return Shared(report: await start(.poll, handling: handling) { await $0.execute(ignoringCadence: true) }, joined: false)
    }

    /// The selected locales changed; fetch what the newest manifest held lists for them.
    func languageChanged() async -> CycleReport {
        while let current = running { _ = await current.task.value }
        return await start(.change) { await $0.executeLanguageChange() }
    }

    private func start(_ kind: Kind, handling: Handling? = nil,
                       _ work: @escaping @Sendable (UpdateCycle) async -> CycleReport) async -> CycleReport {
        let task = Task { [self] in
            clearSignals()
            var report = await work(self)
            report.signals = await finalSignals()
            await handling?(report)
            finished()
            return report
        }
        running = (kind, task)
        return await task.value
    }

    /// Cleared by the task itself: waiters resuming later must not clear a newer cycle's slot.
    private func finished() {
        running = nil
    }
}

// MARK: - Types private to the cycle

/// The `meta` the files are fetched with: its URLs and signature.
private struct Signature {
    var meta: Meta
    var raw: Data
    var etag: String?
    /// An expired signature allows one extra read of `meta` per cycle.
    var reread = false
}

private struct Abort {
    let retryAfter: Int?
}

private struct Fetched {
    var obtained = 0
    var abort: Abort?
    /// The re-read named another release: this cycle's work is moot.
    var superseded = false
}

private enum Finish {
    case settled(CycleOutcome, interval: Int)
    case backoff(retryAfter: Int?)
    /// `meta` named another release while the cycle worked: nothing is recorded, and it counts as a failure.
    case superseded
}

/// What a cycle step decided; `conclude` turns it into persisted state.
private struct Verdict {
    var finish: Finish
    var held: Signature?
    var rejected: String?
    var pollAfter: Int?
    /// The interval this answer put the schedule on; a backoff wait never is one.
    var pollInForce: Int?
}

/// A manifest read once: the listed files and the slots to hold, computed a single time per cycle.
private struct Layout {
    let manifest: Manifest
    let raw: Data
    let entries: [Slot: SliceEntry]
    let wanted: [Slot]
}

/// Server numbers are clamped before any arithmetic on them.
enum Bounds {
    static let day = 86_400

    static func poll(_ value: Int) -> Int { min(max(value, 60), day) }
    static func retry(_ value: Int?) -> Int? { value.map { min(max($0, 0), day) } }
    static func interval(_ value: Int) -> Int { min(max(value, 0), day) }
}

private enum Manifests {
    static func hasStrings(_ manifest: Manifest) -> Bool {
        manifest.slices.values.contains { $0.values.contains { $0.keys.contains("strings") } }
    }
}

// MARK: - The cycle

extension UpdateCycle {
    fileprivate func execute(ignoringCadence: Bool = false) async -> CycleReport {
        let now = environment.now()
        let start = await environment.store.state
        // `backoffStep` stays above 0 until a cycle settles, so it marks a wait that a request must not cut short.
        // `isDue` is true when `lastCheck` lies ahead of the clock, which would end that wait early.
        let mayRead: Bool
        // Held in memory too: a failed save leaves the step at 0, and a changed date makes `isDue` lie.
        if ignoringCadence, let until = remembered?.backoffUntil, environment.uptime() < until {
            mayRead = false
        } else if ignoringCadence && start.backoffStep <= 0 {
            mayRead = true
        } else if ignoringCadence {
            mayRead = (scheduled(start).lastCheck ?? .distantPast) <= now && isDue(start, now: now)
        } else {
            mayRead = isDue(start, now: now)
        }
        guard mayRead else {
            return CycleReport(outcome: .notDue, nextCheckIn: remaining(start, now: now))
        }
        let newest = newestInstall(start)
        switch await environment.client.fetchMeta(ifNoneMatch: conditional(start, newest: newest)) {
        case let .received(meta, etag, raw):
            seen.append(.metaAnswered)
            let pollAfter = Bounds.poll(meta.pollAfter)
            var verdict = await decide(Signature(meta: meta, raw: raw, etag: etag), state: start, interval: pollAfter)
            verdict.pollAfter = pollAfter
            verdict.pollInForce = pollAfter
            return await conclude(verdict, now: now, start: start)
        case .notModified:
            seen.append(.metaAnswered)
            let interval = Bounds.poll(start.lastPollAfter ?? 1800)
            guard let held = heldSignature(start) else {
                return await conclude(Verdict(finish: .settled(.unchanged, interval: interval), pollInForce: interval),
                                      now: now, start: start)
            }
            var verdict = await decide(held, state: start, interval: interval)
            verdict.pollInForce = interval
            return await conclude(verdict, now: now, start: start)
        case .unreadable, .networkFailure:
            return await conclude(Verdict(finish: .backoff(retryAfter: nil)), now: now, start: start)
        case let .throttled(retryAfter), let .serverError(retryAfter):
            return await conclude(Verdict(finish: .backoff(retryAfter: retryAfter)), now: now, start: start)
        case let .configurationError(code, pollAfter):
            let interval = Bounds.poll(pollAfter ?? start.lastPollAfter ?? 1800)
            return await conclude(Verdict(finish: .settled(.configurationError(code: code), interval: interval), pollInForce: interval),
                                  now: now, start: start)
        case let .unreleased(pollAfter):
            let interval = Bounds.poll(pollAfter ?? 60)
            return await conclude(Verdict(finish: .settled(.unreleased, interval: interval), pollAfter: pollAfter.map(Bounds.poll), pollInForce: interval),
                                  now: now, start: start)
        }
    }

    // MARK: Signals

    fileprivate func clearSignals() { seen = [] }

    /// `owed` is read after the cycle's own writes, so it describes the install the cycle ended with.
    fileprivate func finalSignals() async -> [CycleSignal] {
        var signals = seen
        guard signals.contains(.metaAnswered) else { return signals }
        let state = await environment.store.state
        var hashes: Set<String> = []
        if let newest = state.pending ?? state.active, !newest.owedSlots.isEmpty, let layout = installedLayout(newest) {
            hashes = Set(newest.owedSlots.compactMap { layout.entries[$0]?.hash })
        }
        signals.append(.owed(hashes: hashes))
        return signals
    }

    // MARK: Cadence

    /// The later of what this process remembers and what is on disk.
    private func scheduled(_ state: StoreState) -> StoreState {
        var state = state
        if let remembered, remembered.lastCheck > state.lastCheck ?? .distantPast {
            state.lastCheck = remembered.lastCheck
            state.checkInterval = remembered.interval
        }
        return state
    }

    private func isDue(_ state: StoreState, now: Date) -> Bool {
        let state = scheduled(state)
        return state.isCheckDue(now: now, pollAfter: Bounds.interval(state.checkInterval ?? 0))
    }

    private func remaining(_ state: StoreState, now: Date) -> TimeInterval {
        guard !isDue(state, now: now) else { return 0 }
        let state = scheduled(state)
        guard let lastCheck = state.lastCheck else { return 0 }
        let due = lastCheck.addingTimeInterval(TimeInterval(Bounds.interval(state.checkInterval ?? 0)))
        return min(max(0, due.timeIntervalSince(now)), TimeInterval(Bounds.day))
    }

    /// Persists the verdict onto the Store's current state: only the fields this cycle changed. `lastCheck` moves
    /// in every case; the backoff step restarts unless the cycle failed.
    private func conclude(_ verdict: Verdict, now: Date, start: StoreState) async -> CycleReport {
        var interval = 0
        var backedOff = false
        var report = CycleReport(outcome: .failed, nextCheckIn: 0)
        let random = environment.random()
        try? await environment.store.update { state in
            state.lastCheck = now
            if let pollAfter = verdict.pollAfter { state.lastPollAfter = pollAfter }
            if let inForce = verdict.pollInForce { state.pollInForce = inForce }
            if let held = verdict.held {
                state.heldMeta = held.raw
                state.metaETag = held.etag
            }
            if let rejected = verdict.rejected { state.rejectedChecksums.insert(rejected) }
            switch verdict.finish {
            case let .settled(outcome, settledInterval):
                interval = Bounds.interval(settledInterval)
                state.backoffStep = 0
                let delay = min(Schedule.pollDelay(pollAfter: interval, random: random), TimeInterval(Bounds.day))
                report = CycleReport(outcome: outcome, nextCheckIn: delay)
            case .backoff, .superseded:
                // The step counts from where the cycle began; 1 000 doublings is far past any cap.
                state.backoffStep = min(max(start.backoffStep, 0), 1_000) + 1
                let known = Bounds.poll(verdict.pollAfter ?? start.lastPollAfter ?? 1800)
                var retryAfter: Int?
                if case let .backoff(value) = verdict.finish { retryAfter = value }
                var wait = Schedule.backoff(step: state.backoffStep, pollAfter: known, retryAfter: Bounds.retry(retryAfter))
                var outcome = CycleOutcome.failed
                if case .superseded = verdict.finish {
                    wait = max(wait, 60)
                    outcome = .unchanged
                }
                interval = Bounds.interval(Int(wait.rounded(.up)))
                backedOff = true
                report = CycleReport(outcome: outcome, nextCheckIn: TimeInterval(interval))
            }
            state.checkInterval = interval
        }
        remembered = (now, interval, backedOff ? environment.uptime() + TimeInterval(interval) : nil)
        return report
    }

    // MARK: Known state

    private func heldSignature(_ state: StoreState) -> Signature? {
        guard let raw = state.heldMeta, let meta = try? JSONDecoder().decode(Meta.self, from: raw) else { return nil }
        return Signature(meta: meta, raw: raw, etag: state.metaETag)
    }

    /// An ETag is only worth sending when the held `meta` names what is installed.
    private func conditional(_ state: StoreState, newest: InstallRecord?) -> String? {
        guard let held = heldSignature(state), held.meta.checksum == newest?.checksum else { return nil }
        return state.metaETag
    }

    /// An install whose checksum was marked bad is not what the device holds.
    private func newestInstall(_ state: StoreState) -> InstallRecord? {
        [state.pending, state.active].compactMap { $0 }.first { !state.badChecksums.contains($0.checksum) }
    }

    // MARK: Identity: `meta.checksum` against the newest install known

    private func decide(_ signature: Signature, state: StoreState, interval: Int) async -> Verdict {
        let meta = signature.meta
        if let newest = newestInstall(state), newest.checksum == meta.checksum {
            return await retryMissing(newest, signature, interval: interval)
        }
        if state.pending != nil, state.active?.checksum == meta.checksum {
            try? await environment.store.setPending(nil)
            return Verdict(finish: .settled(.discardedPending, interval: interval), held: signature)
        }
        if state.rejectedChecksums.contains(meta.checksum) || state.badChecksums.contains(meta.checksum) {
            if state.rejectedChecksums.contains(meta.checksum) { seen.append(.stillRejected(checksum: meta.checksum)) }
            return Verdict(finish: .settled(.skipped, interval: interval))
        }
        return await install(changed: signature, interval: interval)
    }

    private func install(changed signature: Signature, interval: Int) async -> Verdict {
        let meta = signature.meta
        func reject(_ reason: RejectionReason) -> Verdict {
            Verdict(finish: .settled(.rejected(checksum: meta.checksum, reason), interval: interval), rejected: meta.checksum)
        }
        switch await environment.client.fetchManifest(meta) {
        case let .verified(manifest, raw):
            guard manifest.schemaVersion == 1 else { return reject(.unknownSchema(manifest.schemaVersion)) }
            guard Manifests.hasStrings(manifest) else { return reject(.noStrings) }
            let layout = layout(of: manifest, raw: raw)
            var signature = signature
            let fetched = await fetch(layout.wanted, layout: layout, signature: &signature)
            if let abort = fetched.abort { return Verdict(finish: .backoff(retryAfter: abort.retryAfter)) }
            if fetched.superseded { return supersededVerdict() }
            return await build(layout, checksum: meta.checksum, releaseId: meta.releaseId, signature: signature, interval: interval)
        case .unreadable:
            return reject(.unreadable)
        case .checksumMismatch:
            seen.append(.manifestChecksumMismatch(metaChecksum: meta.checksum))
            return Verdict(finish: .backoff(retryAfter: nil))
        case .refused, .networkFailure:
            return Verdict(finish: .backoff(retryAfter: nil))
        case let .throttled(retryAfter), let .serverError(retryAfter), let .unfetchable(_, retryAfter):
            return Verdict(finish: .backoff(retryAfter: retryAfter))
        }
    }

    /// The newest install's missing wanted slots (owed or newly selected), and no install unless one arrived.
    private func retryMissing(_ newest: InstallRecord, _ signature: Signature, interval: Int) async -> Verdict {
        let unchanged = Verdict(finish: .settled(.unchanged, interval: interval), held: signature)
        guard let layout = installedLayout(newest) else { return unchanged }
        let missing = missingSlots(layout, in: newest, includingOwed: true)
        guard !missing.isEmpty else { return unchanged }
        var signature = signature
        let fetched = await fetch(missing, layout: layout, signature: &signature)
        if let abort = fetched.abort { return Verdict(finish: .backoff(retryAfter: abort.retryAfter)) }
        if fetched.superseded { return supersededVerdict() }
        guard fetched.obtained > 0 else { return Verdict(finish: unchanged.finish, held: signature) }
        return await build(layout, checksum: newest.checksum, releaseId: signature.meta.releaseId, signature: signature, interval: interval)
    }

    private func supersededVerdict() -> Verdict {
        Verdict(finish: .superseded)
    }

    // MARK: Language change

    fileprivate func executeLanguageChange() async -> CycleReport {
        let now = environment.now()
        let state = await environment.store.state
        let wait = remaining(state, now: now)
        let unchanged = CycleReport(outcome: .unchanged, nextCheckIn: wait)
        guard let newest = newestInstall(state), let layout = installedLayout(newest) else { return unchanged }
        let missing = missingSlots(layout, in: newest, includingOwed: false)
        guard !missing.isEmpty else { return unchanged }

        var signature: Signature
        if let held = heldSignature(state), held.meta.checksum == newest.checksum {
            signature = held
        } else {
            switch await environment.client.fetchMeta(ifNoneMatch: nil) {
            case let .received(meta, etag, raw) where meta.checksum == newest.checksum:
                seen.append(.metaAnswered)
                signature = Signature(meta: meta, raw: raw, etag: etag, reread: true)
            case .throttled, .serverError, .networkFailure:
                return CycleReport(outcome: .failed, nextCheckIn: wait)
            default:
                return unchanged
            }
        }
        let fetched = await fetch(missing, layout: layout, signature: &signature)
        if fetched.superseded { return unchanged }
        // A renewed signature is worth keeping even when nothing else came of this call.
        await keepSignature(signature)
        if fetched.abort != nil { return CycleReport(outcome: .failed, nextCheckIn: wait) }
        guard fetched.obtained > 0 else { return unchanged }
        let verdict = await build(layout, checksum: newest.checksum, releaseId: newest.releaseId, signature: signature, interval: 0)
        guard case let .settled(outcome, _) = verdict.finish else { return CycleReport(outcome: .failed, nextCheckIn: wait) }
        return CycleReport(outcome: outcome, nextCheckIn: wait)
    }

    private func keepSignature(_ signature: Signature) async {
        try? await environment.store.update { state in
            guard signature.raw != state.heldMeta else { return }
            state.heldMeta = signature.raw
            state.metaETag = signature.etag
        }
    }

    // MARK: Download and build

    private func layout(of manifest: Manifest, raw: Data) -> Layout {
        var entries: [Slot: SliceEntry] = [:]
        for (bundle, locales) in manifest.slices {
            for (locale, files) in locales {
                for (fileType, entry) in files { entries[Slot(bundleId: bundle, locale: locale, fileType: fileType)] = entry }
            }
        }
        let selected = environment.selectLocales(Set(manifest.slices.values.flatMap(\.keys)).sorted())
        var wanted: [Slot] = []
        // A case-insensitive volume would give a twin the same file as the first; the first in sorted order wins.
        var seen: Set<Slot> = []
        for bundle in manifest.bundles.keys.sorted() {
            for locale in selected {
                for fileType in ["strings", "stringsdict"] {
                    let slot = Slot(bundleId: bundle, locale: locale, fileType: fileType)
                    let folded = Slot(bundleId: bundle.lowercased(), locale: locale.lowercased(), fileType: fileType)
                    if entries[slot] != nil, Store.canInstall(slot), seen.insert(folded).inserted { wanted.append(slot) }
                }
            }
        }
        return Layout(manifest: manifest, raw: raw, entries: entries, wanted: wanted)
    }

    private func installedLayout(_ install: InstallRecord) -> Layout? {
        guard let raw = try? Data(contentsOf: environment.store.url(of: install).appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: raw) else { return nil }
        return layout(of: manifest, raw: raw)
    }

    private func missingSlots(_ layout: Layout, in install: InstallRecord, includingOwed: Bool) -> [Slot] {
        // An owed slot may carry the active install's older file, so having a file does not mean it is held.
        layout.wanted.filter { slot in
            if install.owedSlots.contains(slot) { return includingOwed }
            return environment.store.fileURL(of: install, slot: slot) == nil
        }
    }

    /// Obtains what is not already held. `obtained` counts slots fetched now or found held.
    private func fetch(_ slots: [Slot], layout: Layout, signature: inout Signature) async -> Fetched {
        var result = Fetched()
        var absent: [Slot] = []
        // Held lookups come first: staging a file invalidates the Store's index, so interleaving them is quadratic.
        for slot in slots {
            guard let entry = layout.entries[slot] else { continue }
            if await environment.store.heldObject(hash: entry.hash, fileType: slot.fileType) != nil {
                result.obtained += 1
            } else {
                absent.append(slot)
            }
        }
        let first = await pass(absent, layout: layout, signature: signature)
        result.obtained += first.obtained
        result.abort = first.abort
        guard result.abort == nil, !first.unfetchable.isEmpty, !signature.reread else { return result }
        signature.reread = true
        // The signature may have expired; one fresh read, ignoring any cached answer, is all the contract allows.
        guard case let .received(meta, etag, raw) = await environment.client.fetchMeta(ifNoneMatch: nil) else { return result }
        seen.append(.metaAnswered)
        guard meta.checksum == signature.meta.checksum else {
            result.superseded = true
            return result
        }
        // An unchanged signature means the object is gone, not expired.
        let retry = meta.signedQuery != nil && meta.signedQuery != signature.meta.signedQuery
        signature = Signature(meta: meta, raw: raw, etag: etag, reread: true)
        guard retry else { return result }
        let again = await pass(first.unfetchable, layout: layout, signature: signature)
        result.obtained += again.obtained
        result.abort = again.abort
        return result
    }

    private func pass(_ slots: [Slot], layout: Layout, signature: Signature) async -> (obtained: Int, unfetchable: [Slot], abort: Abort?) {
        let checksum = signature.meta.checksum
        var obtained = 0
        var unfetchable: [Slot] = []
        // Slots of different bundles can share one object.
        var staged: Set<String> = []
        for slot in slots {
            guard let entry = layout.entries[slot] else { continue }
            if staged.contains("\(entry.hash).\(slot.fileType)") {
                obtained += 1
                continue
            }
            switch await environment.client.fetchObject(signature.meta, hash: entry.hash, fileType: slot.fileType, expectedSize: entry.size) {
            case let .verified(data):
                do {
                    try await environment.store.stage(checksum: checksum, hash: entry.hash, fileType: slot.fileType, verifiedBytes: data)
                    obtained += 1
                    staged.insert("\(entry.hash).\(slot.fileType)")
                } catch {
                    return (obtained, unfetchable, Abort(retryAfter: nil))
                }
            case .unfetchable:
                unfetchable.append(slot)
            case .hashMismatch:
                seen.append(.fileHashMismatch(hash: entry.hash))
            case .refused, .tooLarge:
                break
            case let .throttled(retryAfter), let .serverError(retryAfter):
                return (obtained, unfetchable, Abort(retryAfter: retryAfter))
            case .networkFailure:
                return (obtained, unfetchable, Abort(retryAfter: nil))
            }
        }
        return (obtained, unfetchable, nil)
    }

    private func build(_ layout: Layout, checksum: String, releaseId: Int?, signature: Signature, interval: Int) async -> Verdict {
        let plan = InstallPlan(checksum: checksum, releaseId: releaseId, baseLocale: layout.manifest.baseLocale,
                               manifestRaw: layout.raw, listed: layout.entries.mapValues(\.hash), wanted: Set(layout.wanted))
        do {
            let install = try await environment.store.makeInstall(plan)
            try await environment.store.setPending(install)
            seen.append(.installed(schemaVersion: layout.manifest.schemaVersion,
                                   hasStrings: Manifests.hasStrings(layout.manifest), checksum: checksum))
            return Verdict(finish: .settled(.installed(install), interval: interval), held: signature)
        } catch {
            return Verdict(finish: .backoff(retryAfter: nil))
        }
    }
}
