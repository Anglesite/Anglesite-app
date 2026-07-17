import Testing
@testable import AnglesiteCore

struct ComponentViewportPresetTests {
    @Test("fill has no fixed width")
    func fillHasNoWidth() {
        #expect(ComponentViewportPreset.fill.width == nil)
    }

    @Test("mobile, tablet, and desktop have distinct, increasing widths")
    func devicePresetsHaveIncreasingWidths() throws {
        let mobile = try #require(ComponentViewportPreset.mobile.width)
        let tablet = try #require(ComponentViewportPreset.tablet.width)
        let desktop = try #require(ComponentViewportPreset.desktop.width)
        #expect(mobile < tablet)
        #expect(tablet < desktop)
    }

    @Test("every case has a non-empty label and system image")
    func allCasesHaveLabelAndImage() {
        for preset in ComponentViewportPreset.allCases {
            #expect(!preset.label.isEmpty)
            #expect(!preset.systemImage.isEmpty)
        }
    }

    @Test("id matches the raw value, for SwiftUI ForEach identity")
    func idMatchesRawValue() {
        for preset in ComponentViewportPreset.allCases {
            #expect(preset.id == preset.rawValue)
        }
    }
}
