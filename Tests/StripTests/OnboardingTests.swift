import Testing
@testable import StripEngine

@Suite struct OnboardingTests {
    @Test func restartOnlyWhenScreenRecordingArrivedAfterLaunchInBundle() {
        #expect(Onboarding.needsRestart(screenRecordingAtLaunch: false, screenRecordingNow: true, inBundle: true))
        #expect(!Onboarding.needsRestart(screenRecordingAtLaunch: true, screenRecordingNow: true, inBundle: true))
        #expect(!Onboarding.needsRestart(screenRecordingAtLaunch: false, screenRecordingNow: false, inBundle: true))
        #expect(!Onboarding.needsRestart(screenRecordingAtLaunch: false, screenRecordingNow: true, inBundle: false))
    }

    @Test func loginItemStatesMapToActions() {
        #expect(LoginItemState.off.action == .register)
        #expect(LoginItemState.on.action == .unregister)
        #expect(LoginItemState.needsApproval.action == .openSettings)
        #expect(LoginItemState.unavailable.action == .none)
        #expect(LoginItemState.on.isChecked)
        #expect(LoginItemState.needsApproval.isChecked)
        #expect(!LoginItemState.off.isChecked)
        #expect(!LoginItemState.unavailable.isChecked)
    }
}
