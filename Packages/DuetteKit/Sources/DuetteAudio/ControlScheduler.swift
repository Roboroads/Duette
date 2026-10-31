import Foundation

/// A piece of scheduled work that can be called off.
public final class ScheduledWork {
    private let onCancel: () -> Void

    public init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    public func cancel() {
        onCancel()
    }
}

/// Where EngineController runs: one serial context for all control work. The real one is a
/// DispatchQueue; tests use a manual clock so debounce and retry timing are exact.
public protocol ControlScheduler: AnyObject {
    /// Runs `work` in the control context, after anything already queued.
    func async(_ work: @escaping () -> Void)
    /// Runs `work` in the control context after `delay` seconds, unless cancelled first.
    @discardableResult
    func after(_ delay: TimeInterval, _ work: @escaping () -> Void) -> ScheduledWork
}

/// The production scheduler: a serial dispatch queue.
public final class QueueScheduler: ControlScheduler {
    public let queue: DispatchQueue

    public init(queue: DispatchQueue = DispatchQueue(label: "me.roboroads.duette.control")) {
        self.queue = queue
    }

    public func async(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    @discardableResult
    public func after(_ delay: TimeInterval, _ work: @escaping () -> Void) -> ScheduledWork {
        let item = DispatchWorkItem(block: work)
        queue.asyncAfter(deadline: .now() + delay, execute: item)
        return ScheduledWork { item.cancel() }
    }
}
