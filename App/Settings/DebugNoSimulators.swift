#if DEBUG
import Foundation
import CleanoriCore

/// Debug builds only. The `SimulatorControl` a Debug build uses when `CLEANORI_HOME` names a scratch home: there are
/// no simulators, and deleting one always fails. The live control would list the machine's real simulators and could
/// delete a real unavailable one, which Developer Junk ticks by default, so a manual check on a scratch home must not
/// have it.
///
/// Release builds do not contain this type.
struct DebugNoSimulators: SimulatorControl {
    struct Refused: LocalizedError {
        var errorDescription: String? { "Simulators are switched off in a Debug build that uses CLEANORI_HOME." }
    }

    func listDevices() async throws -> [SimulatorDevice] { [] }

    func delete(udid: String) async throws { throw Refused() }
}
#endif
