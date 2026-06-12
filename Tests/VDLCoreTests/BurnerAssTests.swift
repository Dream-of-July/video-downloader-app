@testable import VDLCore
import XCTest

final class BurnerAssTests: XCTestCase {
    private func cue(_ text: String) -> SubtitleCue {
        SubtitleCue(index: 1, start: "00:00:01,000", end: "00:00:02,500", text: text)
    }

    func testLandscape169LayoutUsesReadableSubtitleWidth() {
        let layout = FFmpegBurner.ASSLayout(aspect: 16.0 / 9.0)

        XCTAssertEqual(layout.playResX, 512)
        XCTAssertEqual(layout.playResY, 288)
        XCTAssertEqual(layout.chineseSize, 15)
        XCTAssertEqual(layout.originalSize, 11)
        XCTAssertEqual(layout.marginH, 61)
        XCTAssertEqual(layout.marginV, 20)
        XCTAssertEqual(layout.cjkWrapCapacity, 26)
    }

    func testLandscape169LongChineseLinePreWrappedForReadableWidth() {
        let ass = FFmpegBurner.makeASS(cues: [
            cue("今天，我会介绍如何使用Xcode中的一些强大新工具，在早期探索应用设计时快速尝试不同的界面方向。")
        ])

        XCTAssertTrue(ass.contains(#"今天，我会介绍如何使用Xcode中的一些强大新工具，\N在早期探索应用设计时快速尝试不同的界面方向。"#))
    }

    func testPortrait916StillKeepsUsefulCapacity() {
        let layout = FFmpegBurner.ASSLayout(aspect: 9.0 / 16.0)

        XCTAssertEqual(layout.playResX, 162)
        XCTAssertEqual(layout.chineseSize, 8)
        XCTAssertEqual(layout.originalSize, 6)
        XCTAssertEqual(layout.marginH, 5)
        XCTAssertEqual(layout.cjkWrapCapacity, 19)
    }

    func testUltraWideCapsReadingLength() {
        let layout = FFmpegBurner.ASSLayout(aspect: 10.0)

        XCTAssertEqual(layout.playResX, 1152)
        XCTAssertEqual(layout.chineseSize, 15)
        XCTAssertEqual(layout.marginH, 351)
        XCTAssertEqual(layout.cjkWrapCapacity, 30)
    }
}
