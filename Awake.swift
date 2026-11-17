import IOKit.pwr_mgt

/// Keeps the display from idle-sleeping while lyrics are showing.
final class AwakeAssertion {
    private var id: IOPMAssertionID = 0
    private var active = false

    func enable() {
        guard !active else { return }
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Neko Lyrics showing lyrics" as CFString,
            &id
        )
        active = (result == kIOReturnSuccess)
    }

    func disable() {
        guard active else { return }
        IOPMAssertionRelease(id)
        active = false
    }
}
