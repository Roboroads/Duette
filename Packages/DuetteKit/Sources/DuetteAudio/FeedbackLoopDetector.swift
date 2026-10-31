import Darwin

/// Spots the feedback loop where the tapped app records "Duette": a caller on Discord would then
/// hear themselves, because Discord's own output is mixed into what Discord sends.
///
/// The driver lists the processes doing input IO on "Duette" ('dcli'). If any of them belongs to
/// the tapped app (helpers included), it is a loop. Duette's own process never counts. This only
/// warns; the audio is left alone.
public enum FeedbackLoopDetector {
    /// The app processes that are recording "Duette", sorted.
    public static func loopingPIDs(inputClients: [pid_t], appPIDs: Set<pid_t>, ownPID: pid_t) -> [pid_t] {
        Set(inputClients).subtracting([ownPID]).intersection(appPIDs).sorted()
    }

    public static func isLoop(inputClients: [pid_t], appPIDs: Set<pid_t>, ownPID: pid_t) -> Bool {
        !loopingPIDs(inputClients: inputClients, appPIDs: appPIDs, ownPID: ownPID).isEmpty
    }
}
