import Foundation

/// Everything a cycle talks to, injected.
struct CycleEnvironment: Sendable {
    let client: DeliveryClient
    let store: Store
    let now: @Sendable () -> Date
    /// In 0..<1; the jitter source.
    let random: @Sendable () -> Double
    /// The manifest's locale keys → the ones to serve, most specific first (chunk 5 wires LocaleSelector).
    let selectLocales: @Sendable ([String]) -> [String]
}

enum RejectionReason: Equatable, Sendable {
    /// C21: a `schemaVersion` this SDK does not know.
    case unknownSchema(Int)
    /// C22: no `strings` file anywhere in the manifest.
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
    /// The manifest was kept out (C21, C22); its checksum is marked rejected.
    case rejected(checksum: String, RejectionReason)
    /// `meta` names a checksum already rejected or marked bad; nothing was fetched.
    case skipped
    /// 404 with nothing released to this stage yet.
    case unreleased
    /// The configuration class (§2): reported by chunk 5; polling continues.
    case configurationError(code: String)
    /// A 5xx, a 429, a network failure, an unreadable `meta` or a manifest that failed its checksum: backing off.
    case failed
}

struct CycleReport: Equatable, Sendable {
    let outcome: CycleOutcome
    /// When to run again, jitter included.
    let nextCheckIn: TimeInterval
}

/// §6.2's update cycle. Records what it builds as pending; activation is not its job.
actor UpdateCycle {
    private let environment: CycleEnvironment
    private var running: Task<CycleReport, Never>?

    init(_ environment: CycleEnvironment) {
        self.environment = environment
    }

    /// One cycle if `meta` is due. Concurrent calls share one cycle.
    func run() async -> CycleReport {
        if let running { return await running.value }
        return await start { await $0.execute() }
    }

    /// §6.2 step A: the selected locales changed; fetch what the newest manifest held lists for them.
    func languageChanged() async -> CycleReport {
        while let running { _ = await running.value }
        return await start { await $0.executeLanguageChange() }
    }

    private func start(_ work: @escaping @Sendable (UpdateCycle) async -> CycleReport) async -> CycleReport {
        let task = Task { [self] in
            let report = await work(self)
            finished()
            return report
        }
        running = task
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
    /// C14 allows one extra read of `meta` per cycle.
    var reread = false
}

private struct Abort {
    let retryAfter: Int?
}

private struct Fetched {
    var obtained = 0
    var abort: Abort?
}

private enum Finish {
    case settled(CycleOutcome, interval: Int)
    case backoff(retryAfter: Int?)
}

/// What a cycle step decided; `conclude` turns it into persisted state.
private struct Verdict {
    var finish: Finish
    var held: Signature?
    var rejected: String?
}

private enum Manifests {
    static func hasStrings(_ manifest: Manifest) -> Bool {
        manifest.slices.values.contains { $0.values.contains { $0.keys.contains("strings") } }
    }
}

// MARK: - The cycle

extension UpdateCycle {
    fileprivate func execute() async -> CycleReport {
        let now = environment.now()
        let state = await environment.store.state
        guard state.isCheckDue(now: now, pollAfter: state.checkInterval ?? 0) else {
            return CycleReport(outcome: .notDue, nextCheckIn: remaining(state, now: now))
        }
        let etag = state.heldMeta != nil ? state.metaETag : nil
        switch await environment.client.fetchMeta(ifNoneMatch: etag) {
        case let .received(meta, etag, raw):
            let verdict = await decide(Signature(meta: meta, raw: raw, etag: etag), state: state, interval: meta.pollAfter)
            return await conclude(verdict, now: now, pollAfter: meta.pollAfter)
        case .notModified:
            let interval = state.lastPollAfter ?? 1800
            guard let held = heldSignature(state) else {
                return await conclude(Verdict(finish: .settled(.unchanged, interval: interval)), now: now, pollAfter: nil)
            }
            return await conclude(await decide(held, state: state, interval: interval), now: now, pollAfter: nil)
        case .unreadable, .networkFailure:
            return await conclude(Verdict(finish: .backoff(retryAfter: nil)), now: now, pollAfter: nil, resetStep: false)
        case let .throttled(retryAfter), let .serverError(retryAfter):
            return await conclude(Verdict(finish: .backoff(retryAfter: retryAfter)), now: now, pollAfter: nil, resetStep: false)
        case let .configurationError(code, pollAfter):
            let interval = pollAfter ?? state.lastPollAfter ?? 1800
            return await conclude(Verdict(finish: .settled(.configurationError(code: code), interval: interval)),
                                  now: now, pollAfter: nil, resetStep: false)
        case let .unreleased(pollAfter):
            return await conclude(Verdict(finish: .settled(.unreleased, interval: pollAfter ?? 60)),
                                  now: now, pollAfter: nil, resetStep: false)
        }
    }

    /// Persists the verdict. `lastCheck` moves in every case; `resetStep` is false for answers that are not a
    /// successful read of `meta`.
    private func conclude(_ verdict: Verdict, now: Date, pollAfter: Int?, resetStep: Bool = true) async -> CycleReport {
        var state = await environment.store.state
        state.lastCheck = now
        if let pollAfter { state.lastPollAfter = pollAfter }
        if resetStep { state.backoffStep = 0 }
        if let held = verdict.held {
            state.heldMeta = held.raw
            state.metaETag = held.etag
        }
        if let rejected = verdict.rejected { state.rejectedChecksums.insert(rejected) }
        let report: CycleReport
        switch verdict.finish {
        case let .settled(outcome, interval):
            state.checkInterval = interval
            report = CycleReport(outcome: outcome, nextCheckIn: Schedule.pollDelay(pollAfter: interval, random: environment.random()))
        case let .backoff(retryAfter):
            state.backoffStep += 1
            let wait = Schedule.backoff(step: state.backoffStep, pollAfter: state.lastPollAfter ?? 1800, retryAfter: retryAfter)
            state.checkInterval = Int(wait.rounded(.up))
            report = CycleReport(outcome: .failed, nextCheckIn: wait)
        }
        try? await environment.store.save(state)
        return report
    }

    private func remaining(_ state: StoreState, now: Date) -> TimeInterval {
        guard let lastCheck = state.lastCheck else { return 0 }
        return max(0, lastCheck.addingTimeInterval(TimeInterval(state.checkInterval ?? 0)).timeIntervalSince(now))
    }

    private func heldSignature(_ state: StoreState) -> Signature? {
        guard let raw = state.heldMeta, let meta = try? JSONDecoder().decode(Meta.self, from: raw) else { return nil }
        return Signature(meta: meta, raw: raw, etag: state.metaETag)
    }

    /// An install whose checksum was marked bad is not what the device holds.
    private func newestInstall(_ state: StoreState) -> InstallRecord? {
        [state.pending, state.active].compactMap { $0 }.first { !state.badChecksums.contains($0.checksum) }
    }

    // MARK: Identity (D-19)

    private func decide(_ signature: Signature, state: StoreState, interval: Int) async -> Verdict {
        let meta = signature.meta
        if let newest = newestInstall(state), newest.checksum == meta.checksum {
            return await retryOwed(newest, signature, interval: interval)
        }
        if state.pending != nil, state.active?.checksum == meta.checksum {
            try? await environment.store.setPending(nil)
            return Verdict(finish: .settled(.discardedPending, interval: interval), held: signature)
        }
        if state.rejectedChecksums.contains(meta.checksum) || state.badChecksums.contains(meta.checksum) {
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
            var signature = signature
            let fetched = await fetch(wanted(manifest), manifest: manifest, signature: &signature)
            if let abort = fetched.abort { return Verdict(finish: .backoff(retryAfter: abort.retryAfter)) }
            return await build(checksum: meta.checksum, releaseId: meta.releaseId, manifest: manifest, manifestRaw: raw,
                               signature: signature, interval: interval)
        case .unreadable:
            return reject(.unreadable)
        case .checksumMismatch, .refused, .unfetchable, .networkFailure:
            return Verdict(finish: .backoff(retryAfter: nil))
        case let .throttled(retryAfter), let .serverError(retryAfter):
            return Verdict(finish: .backoff(retryAfter: retryAfter))
        }
    }

    /// Only the owed slots of the newest install, and no install unless one of them arrived (I38).
    private func retryOwed(_ newest: InstallRecord, _ signature: Signature, interval: Int) async -> Verdict {
        let unchanged = Verdict(finish: .settled(.unchanged, interval: interval), held: signature)
        guard !newest.owedSlots.isEmpty, let (manifest, raw) = installedManifest(newest) else { return unchanged }
        var signature = signature
        let fetched = await fetch(Array(newest.owedSlots), manifest: manifest, signature: &signature)
        if let abort = fetched.abort { return Verdict(finish: .backoff(retryAfter: abort.retryAfter)) }
        guard fetched.obtained > 0 else { return Verdict(finish: unchanged.finish, held: signature) }
        return await build(checksum: newest.checksum, releaseId: signature.meta.releaseId, manifest: manifest, manifestRaw: raw,
                           signature: signature, interval: interval)
    }

    // MARK: Step A (I30)

    fileprivate func executeLanguageChange() async -> CycleReport {
        let now = environment.now()
        var state = await environment.store.state
        let wait = remaining(state, now: now)
        let unchanged = CycleReport(outcome: .unchanged, nextCheckIn: wait)
        guard let newest = newestInstall(state), let (manifest, raw) = installedManifest(newest) else { return unchanged }
        let missing = wanted(manifest).filter { environment.store.fileURL(of: newest, slot: $0) == nil }
        guard !missing.isEmpty else { return unchanged }

        var signature: Signature
        if let held = heldSignature(state), held.meta.checksum == newest.checksum {
            signature = held
        } else {
            switch await environment.client.fetchMeta(ifNoneMatch: nil) {
            case let .received(meta, etag, raw) where meta.checksum == newest.checksum:
                signature = Signature(meta: meta, raw: raw, etag: etag, reread: true)
            case .throttled, .serverError, .networkFailure:
                return CycleReport(outcome: .failed, nextCheckIn: wait)
            default:
                return unchanged
            }
        }
        let fetched = await fetch(missing, manifest: manifest, signature: &signature)
        // A renewed signature is worth keeping even when nothing else came of this call.
        if signature.raw != state.heldMeta {
            state.heldMeta = signature.raw
            state.metaETag = signature.etag
            try? await environment.store.save(state)
        }
        if fetched.abort != nil { return CycleReport(outcome: .failed, nextCheckIn: wait) }
        guard fetched.obtained > 0 else { return unchanged }
        let verdict = await build(checksum: newest.checksum, releaseId: newest.releaseId, manifest: manifest, manifestRaw: raw,
                                  signature: signature, interval: 0)
        guard case let .settled(outcome, _) = verdict.finish else { return CycleReport(outcome: .failed, nextCheckIn: wait) }
        return CycleReport(outcome: outcome, nextCheckIn: wait)
    }

    // MARK: Download and build

    /// The slots to hold: every bundle × selected locale × the two Apple formats, as far as the manifest lists them.
    private func wanted(_ manifest: Manifest) -> [Slot] {
        let locales = Set(manifest.slices.values.flatMap(\.keys)).sorted()
        let selected = environment.selectLocales(locales)
        var slots: [Slot] = []
        for bundle in manifest.bundles.keys.sorted() {
            for locale in selected {
                for fileType in ["strings", "stringsdict"] where manifest.slices[bundle]?[locale]?[fileType] != nil {
                    slots.append(Slot(bundleId: bundle, locale: locale, fileType: fileType))
                }
            }
        }
        return slots
    }

    private func installedManifest(_ install: InstallRecord) -> (Manifest, Data)? {
        guard let raw = try? Data(contentsOf: environment.store.url(of: install).appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: raw) else { return nil }
        return (manifest, raw)
    }

    /// Stages what is not already held. `obtained` counts slots that are now available, fetched or already held.
    private func fetch(_ slots: [Slot], manifest: Manifest, signature: inout Signature) async -> Fetched {
        let ordered = slots.sorted { ($0.bundleId, $0.locale, $0.fileType) < ($1.bundleId, $1.locale, $1.fileType) }
        var result = await pass(ordered, manifest: manifest, signature: signature)
        var unfetchable = result.unfetchable
        if result.fetched.abort == nil, !unfetchable.isEmpty, !signature.reread {
            signature.reread = true
            // The signature may have expired; one fresh read, ignoring any cached answer, is all C14 allows.
            if case let .received(meta, etag, raw) = await environment.client.fetchMeta(ifNoneMatch: nil),
               meta.checksum == signature.meta.checksum {
                signature = Signature(meta: meta, raw: raw, etag: etag, reread: true)
                let again = await pass(unfetchable, manifest: manifest, signature: signature)
                result.fetched.obtained += again.fetched.obtained
                result.fetched.abort = again.fetched.abort
                unfetchable = again.unfetchable
            }
        }
        return result.fetched
    }

    private func pass(_ slots: [Slot], manifest: Manifest, signature: Signature) async -> (fetched: Fetched, unfetchable: [Slot]) {
        let store = environment.store
        let checksum = signature.meta.checksum
        var fetched = Fetched()
        var unfetchable: [Slot] = []
        let staged = await store.stagedObjects(checksum: checksum)
        for slot in slots {
            guard let entry = manifest.slices[slot.bundleId]?[slot.locale]?[slot.fileType] else { continue }
            if staged.contains("\(entry.hash).\(slot.fileType)") { fetched.obtained += 1; continue }
            if await store.heldObject(hash: entry.hash, fileType: slot.fileType) != nil { fetched.obtained += 1; continue }
            switch await environment.client.fetchObject(signature.meta, hash: entry.hash, fileType: slot.fileType, expectedSize: entry.size) {
            case let .verified(data):
                do {
                    try await store.stage(checksum: checksum, hash: entry.hash, fileType: slot.fileType, verifiedBytes: data)
                    fetched.obtained += 1
                } catch {
                    fetched.abort = Abort(retryAfter: nil)
                    return (fetched, unfetchable)
                }
            case .unfetchable:
                unfetchable.append(slot)
            case .refused, .hashMismatch, .tooLarge:
                break
            case let .throttled(retryAfter), let .serverError(retryAfter):
                fetched.abort = Abort(retryAfter: retryAfter)
                return (fetched, unfetchable)
            case .networkFailure:
                fetched.abort = Abort(retryAfter: nil)
                return (fetched, unfetchable)
            }
        }
        return (fetched, unfetchable)
    }

    private func build(checksum: String, releaseId: Int?, manifest: Manifest, manifestRaw: Data,
                       signature: Signature, interval: Int) async -> Verdict {
        var listed: [Slot: String] = [:]
        for (bundle, locales) in manifest.slices {
            for (locale, files) in locales {
                for (fileType, entry) in files { listed[Slot(bundleId: bundle, locale: locale, fileType: fileType)] = entry.hash }
            }
        }
        let plan = InstallPlan(checksum: checksum, releaseId: releaseId, baseLocale: manifest.baseLocale,
                               manifestRaw: manifestRaw, listed: listed, wanted: Set(wanted(manifest)))
        do {
            let install = try await environment.store.makeInstall(plan)
            try await environment.store.setPending(install)
            return Verdict(finish: .settled(.installed(install), interval: interval), held: signature)
        } catch {
            return Verdict(finish: .backoff(retryAfter: nil))
        }
    }
}
