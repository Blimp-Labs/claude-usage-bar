import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Time abstraction so `StatusMonitor`'s poll loop can be driven by a virtual clock in tests.
public protocol StatusClock: Sendable {
    func now() -> Date
    func sleep(for interval: TimeInterval) async throws
}

public struct SystemStatusClock: StatusClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(for interval: TimeInterval) async throws {
        let nanos = UInt64(max(0, interval) * 1_000_000_000)
        try await Task.sleep(nanoseconds: nanos)
    }
}

/// `@MainActor @Observable` polling service for `status.claude.com`. Mirrors the `UsageService`
/// pattern (single root-level @MainActor service, observed by the icon renderer + popover).
///
/// Lifecycle: `start()` is idempotent. `stop()` cancels the in-flight task. Sleep/wake events
/// from `NSWorkspace.shared.notificationCenter` flip `isPaused`; `refresh()` always runs.
@MainActor
@Observable
public final class StatusMonitor {
    public private(set) var snapshot: StatusSnapshot?
    public private(set) var lastError: StatusError?
    public private(set) var isPaused: Bool = false
    public private(set) var isRunning: Bool = false
    public private(set) var currentInterval: TimeInterval

    private let client: StatusPageClient
    private var filter: StatusComponentFilter
    private let clock: any StatusClock
    private var baseInterval: TimeInterval
    private let maxBackoff: TimeInterval
    private let notificationCenter: NotificationCenter

    private var pollTask: Task<Void, Never>?
    // nonisolated(unsafe) lets deinit read these tokens without a MainActor hop.
    // Safety invariant: only MainActor-isolated methods mutate these vars; deinit
    // reads them during teardown when no concurrent access to the object is possible.
    nonisolated(unsafe) private var sleepObserver: (any NSObjectProtocol)?
    nonisolated(unsafe) private var wakeObserver: (any NSObjectProtocol)?

    /// Notification names — defaulting to `NSWorkspace.willSleepNotification` / `didWakeNotification`
    /// when AppKit is available; falling back to private names so tests can post via an injected center.
    private let sleepNotification: Notification.Name
    private let wakeNotification: Notification.Name

    public init(
        client: StatusPageClient,
        filter: StatusComponentFilter = .default,
        clock: any StatusClock = SystemStatusClock(),
        baseInterval: TimeInterval = 5 * 60,
        maxBackoff: TimeInterval = 30 * 60,
        notificationCenter: NotificationCenter? = nil,
        sleepNotification: Notification.Name? = nil,
        wakeNotification: Notification.Name? = nil
    ) {
        self.client = client
        self.filter = filter
        self.clock = clock
        self.baseInterval = baseInterval
        self.maxBackoff = maxBackoff
        self.currentInterval = baseInterval
        #if canImport(AppKit)
        self.notificationCenter = notificationCenter ?? NSWorkspace.shared.notificationCenter
        self.sleepNotification = sleepNotification ?? NSWorkspace.willSleepNotification
        self.wakeNotification = wakeNotification ?? NSWorkspace.didWakeNotification
        #else
        self.notificationCenter = notificationCenter ?? NotificationCenter.default
        self.sleepNotification = sleepNotification ?? Notification.Name("StatusMonitor.willSleep")
        self.wakeNotification = wakeNotification ?? Notification.Name("StatusMonitor.didWake")
        #endif
    }

    deinit {
        // Remove sleep/wake observers defensively. NotificationCenter.removeObserver(_:) is
        // thread-safe and requires no actor hop, so this is safe from the nonisolated deinit.
        // The poll task holds weak self and will exit on its own; observer tokens need explicit
        // removal to avoid dangling registrations in the injected NotificationCenter.
        if let sleepObserver { notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { notificationCenter.removeObserver(wakeObserver) }
    }

    // MARK: - Lifecycle

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        currentInterval = baseInterval
        installSleepWakeObservers()
        pollTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        isRunning = false
        pollTask?.cancel()
        pollTask = nil
        if let sleepObserver {
            notificationCenter.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
        if let wakeObserver {
            notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        isPaused = false
    }

    /// Manual one-shot fetch. Bypasses `isPaused` so the popover Retry button always works.
    public func refresh() async {
        await fetchOnce()
    }

    public func updateFilter(_ filter: StatusComponentFilter) {
        self.filter = filter
        // Re-derive the snapshot from the most recent fetch if available — but we don't
        // cache the raw summary here, so simplest: trigger a refresh.
        if isRunning {
            Task { await self.refresh() }
        }
    }

    public func updateInterval(_ minutes: Int) {
        // Mirror UsageService.updatePollingInterval: update baseInterval and currentInterval,
        // then cancel the in-flight task so the loop re-arms immediately from the new cadence.
        let newInterval = TimeInterval(minutes * 60)
        baseInterval = newInterval
        currentInterval = newInterval
        guard isRunning else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    // MARK: - Loop

    private func runLoop() async {
        while isRunning, !Task.isCancelled {
            // Honour pause: if paused, wait until resumed (or stop()).
            while isPaused, isRunning, !Task.isCancelled {
                // Sleep in 1-second chunks; the wake notification flips isPaused back to false.
                do {
                    try await clock.sleep(for: 1)
                } catch {
                    return
                }
            }
            if !isRunning || Task.isCancelled { return }

            await fetchOnce()

            do {
                try await clock.sleep(for: currentInterval)
            } catch {
                return
            }
        }
    }

    private func fetchOnce() async {
        do {
            let summary = try await client.fetchSummary()
            let snap = StatusSnapshot.make(from: summary, filter: filter, now: clock.now())
            self.snapshot = snap
            self.lastError = nil
            // Reset the backoff on any success.
            self.currentInterval = baseInterval
        } catch let error as StatusError {
            self.lastError = error
            // Exponential backoff doubles, capped at maxBackoff.
            self.currentInterval = min(currentInterval * 2, maxBackoff)
        } catch {
            self.lastError = .transport(.unknown)
            self.currentInterval = min(currentInterval * 2, maxBackoff)
        }
    }

    // MARK: - Sleep / Wake

    private func installSleepWakeObservers() {
        // Remove any prior observer (idempotent).
        if let sleepObserver { notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { notificationCenter.removeObserver(wakeObserver) }

        sleepObserver = notificationCenter.addObserver(
            forName: sleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The closure runs on .main; hop to the actor to mutate state safely.
            Task { @MainActor [weak self] in
                self?.isPaused = true
            }
        }
        wakeObserver = notificationCenter.addObserver(
            forName: wakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isPaused = false
            }
        }
    }
}
