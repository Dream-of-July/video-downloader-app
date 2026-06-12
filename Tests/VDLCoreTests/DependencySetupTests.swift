@testable import VDLCore
import XCTest

final class DependencySetupTests: XCTestCase {
    func testFfmpegDependencyUsesFullBuildForSubtitleBurning() {
        let components = DependencySetup.components(
            ytDlpInstalled: true,
            subtitleRendererFfmpegInstalled: false,
            jsRuntimeInstalled: true
        )

        let ffmpeg = components.first { $0.id == "ffmpeg" }
        XCTAssertEqual(ffmpeg?.formula, "ffmpeg-full")
        XCTAssertEqual(ffmpeg?.isInstalled, false)
    }

    func testNeedsSetupFollowsSharedMissingComponentList() {
        let ready = DependencySetup.components(
            ytDlpInstalled: true,
            subtitleRendererFfmpegInstalled: true,
            jsRuntimeInstalled: true
        )
        let missingDeno = DependencySetup.components(
            ytDlpInstalled: true,
            subtitleRendererFfmpegInstalled: true,
            jsRuntimeInstalled: false
        )

        XCTAssertFalse(DependencySetup.needsSetup(ready))
        XCTAssertTrue(DependencySetup.needsSetup(missingDeno))
        XCTAssertEqual(DependencySetup.missing(from: missingDeno).map(\.id), ["deno"])
    }

    func testBurnerSkipsFfmpegWithoutSubtitleRenderer() {
        let chosen = FFmpegBurner.locateSubtitleRendererFFmpeg(
            candidates: ["/opt/homebrew/bin/ffmpeg", "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg"],
            environment: [:],
            fileIsExecutable: { _ in true },
            supportsSubtitleRendering: { path in path.contains("ffmpeg-full") }
        )

        XCTAssertEqual(chosen, "/opt/homebrew/opt/ffmpeg-full/bin/ffmpeg")
    }
}
