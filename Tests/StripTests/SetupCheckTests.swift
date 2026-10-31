import Testing
@testable import StripEngine

@Suite struct SetupCheckTests {
    @Test func stageManagerIsOffUnlessSet() {
        #expect(SetupCheck.stageManager(settings: [:]).ok)
        #expect(SetupCheck.stageManager(settings: ["GloballyEnabled": 0]).ok)
        #expect(!SetupCheck.stageManager(settings: ["GloballyEnabled": 1]).ok)
    }

    @Test func edgeTilingIsOnUnlessBothDragsAreOff() {
        #expect(!SetupCheck.edgeTiling(settings: [:]).ok)
        #expect(!SetupCheck.edgeTiling(settings: ["EnableTilingByEdgeDrag": 0]).ok)
        #expect(!SetupCheck.edgeTiling(settings: ["EnableTilingByEdgeDrag": 0, "EnableTopTilingByEdgeDrag": 1]).ok)
        #expect(SetupCheck.edgeTiling(settings: ["EnableTilingByEdgeDrag": 0, "EnableTopTilingByEdgeDrag": 0,
                                                 "EnableTilingOptionAccelerator": 1]).ok)
    }

    @Test func clickWallpaperIsOnUnlessOnlyInStageManager() {
        #expect(!SetupCheck.clickWallpaper(settings: [:]).ok)
        #expect(!SetupCheck.clickWallpaper(settings: ["EnableStandardClickToShowDesktop": 1]).ok)
        #expect(SetupCheck.clickWallpaper(settings: ["EnableStandardClickToShowDesktop": 0]).ok)
    }

    @Test func otherWindowManagersMatchAppsByBundleAndDaemonsByName() {
        #expect(SetupCheck.otherWindowManagers(bundleIDs: ["com.apple.finder"], processNames: ["yabai-helper"]).ok)
        let one = SetupCheck.otherWindowManagers(bundleIDs: ["com.knollsoft.Rectangle"], processNames: [])
        #expect(one == SetupCheck.Result(ok: false, status: "Rectangle is running. Quit it so windows stay where tinywm puts them."))
        let three = SetupCheck.otherWindowManagers(bundleIDs: ["com.crowdcafe.windowmagnet", "bobko.aerospace"],
                                                   processNames: ["yabai"])
        #expect(three.status.hasPrefix("Magnet, AeroSpace and yabai are running. Quit them"))
    }
}
