import XCTest
@testable import ZennoxCore

final class QualityFormatterTests: XCTestCase {
    func testSummaryAndBadges() {
        XCTAssertEqual(QualityFormatter.summary(codec: .flac, bitDepth: 24, sampleRate: 96_000, channels: 2), "FLAC · 24-bit · 96 kHz · Stereo")
        XCTAssertEqual(QualityFormatter.summary(codec: .alac, bitDepth: 16, sampleRate: 44_100, channels: 1), "ALAC · 16-bit · 44.1 kHz · Mono")
        XCTAssertEqual(QualityFormatter.summary(codec: .mp3, bitDepth: 16, sampleRate: 44_100, channels: 2), "MP3 · 44.1 kHz · Stereo")
        XCTAssertEqual(QualityFormatter.summary(codec: .opus, bitDepth: nil, sampleRate: 48_000, channels: 6), "Opus · 48 kHz · 5.1")
        XCTAssertEqual(QualityFormatter.summary(codec: .unknown, bitDepth: nil, sampleRate: nil, channels: nil), "Unknown")
        XCTAssertEqual(QualityFormatter.badge(.pcm), "Lossless")
        XCTAssertEqual(QualityFormatter.badge(.aac), "AAC")
        XCTAssertEqual(QualityFormatter.kilohertz(88_200), "88.2 kHz")
        XCTAssertEqual(QualityFormatter.kilohertz(22_050), "22.1 kHz")
    }

    func testDurations() {
        XCTAssertEqual(QualityFormatter.duration(ms: 185_000), "3:05")
        XCTAssertEqual(QualityFormatter.duration(ms: 3_723_000), "1:02:03")
        XCTAssertEqual(QualityFormatter.duration(ms: 0), "0:00")
        XCTAssertEqual(QualityFormatter.duration(ms: nil), "–:––")
    }
}
