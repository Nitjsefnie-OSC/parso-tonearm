import XCTest
@testable import TonearmCore

final class LocalAudioMetadataProviderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func flac(rate: Int = 44100, channels: Int = 2, frames: UInt64, seekTable: Bool = false,
                      truncate: Bool = false) -> Data {
        var d = Data("fLaC".utf8)
        d.append(seekTable ? 0x00 : 0x80)
        d.append(contentsOf: [0, 0, 34])
        d.append(contentsOf: [0x10, 0, 0x10, 0, 0, 0, 0, 0, 0, 0])
        let packed = (UInt64(rate) << 44) | (UInt64(channels - 1) << 41) | (UInt64(15) << 36) | frames
        for shift in stride(from: 56, through: 0, by: -8) { d.append(UInt8((packed >> UInt64(shift)) & 0xFF)) }
        d.append(Data(repeating: 0, count: 16))
        if seekTable { d.append(contentsOf: [0x83, 0, 0, 18]); d.append(Data(repeating: 0, count: 18)) }
        return truncate ? d.prefix(20) : d
    }

    private func write(_ data: Data, _ name: String = "a.flac") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func asset(_ url: URL, id: Int64 = 1) -> Asset {
        Asset(id: id, trackId: id, kind: .managedCopy, bookmark: nil, relPath: url.lastPathComponent,
              remoteURL: nil, altRemoteURL: nil, sizeBytes: nil, unsupportedReason: nil)
    }

    private func resolver() -> LocalAssetResolver {
        var r = LocalAssetResolver.live
        let base = dir!
        r.managedBase = { base }
        return r
    }

    func testMultiHourMonoFLACReadsHeaderOnly() throws {
        let frames = UInt64(44100) * 3600 * 5
        let url = try write(flac(channels: 1, frames: frames, seekTable: true))
        let m = try FLACHeaderProbe.probe(url: url)
        XCTAssertEqual(m.channelCount, 1)
        XCTAssertEqual(m.frameCount, Int64(frames))
        XCTAssertEqual(m.durationSeconds, 18000, accuracy: 0.001)
        XCTAssertTrue(m.isSeekable)
    }

    func testMultichannelUsesActualValue() throws {
        let m = try FLACHeaderProbe.probe(url: try write(flac(rate: 96000, channels: 6, frames: 96000)))
        XCTAssertEqual(m.channelCount, 6)
        XCTAssertEqual(m.sampleRate, 96000)
        XCTAssertFalse(m.isSeekable)
    }

    func testMalformedRejected() throws {
        XCTAssertThrowsError(try FLACHeaderProbe.probe(url: try write(flac(frames: 100, truncate: true), "t.flac")))
        XCTAssertThrowsError(try FLACHeaderProbe.probe(url: try write(flac(rate: 0, frames: 100), "r.flac")))
        XCTAssertThrowsError(try FLACHeaderProbe.probe(url: try write(flac(frames: 0), "z.flac")))
        XCTAssertThrowsError(try FLACHeaderProbe.probe(url: try write(Data("RIFFxxxxxxxx".utf8), "w.flac")))
    }

    func testCoalescesCachesAndInvalidatesOnReplacement() async throws {
        let url = try write(flac(frames: 44100 * 10))
        let cache = dir.appendingPathComponent("cache.json")
        let a = asset(url)
        let provider = LocalAudioMetadataProvider(resolver: resolver(), cacheURL: cache)
        async let r1 = provider.metadata(for: a)
        async let r2 = provider.metadata(for: a)
        async let r3 = provider.metadata(for: a)
        let results = await [r1, r2, r3]
        for r in results {
            guard case .available(let m) = r else { return XCTFail("\(r)") }
            XCTAssertEqual(m.durationSeconds, 10, accuracy: 0.001)
        }
        let first = await provider.probeCount
        XCTAssertEqual(first, 1)

        // Relaunch: a new provider reads the persisted cache without probing.
        let relaunched = LocalAudioMetadataProvider(resolver: resolver(), cacheURL: cache,
                                                    probe: { _ in throw CocoaError(.fileReadCorruptFile) })
        let cached = await relaunched.metadata(for: a)
        guard case .available = cached else { return XCTFail("cache lost: \(cached)") }

        // Replacement with a different file invalidates the cache.
        try flac(frames: 44100 * 99, seekTable: true).write(to: url)
        let replaced = await provider.metadata(for: a)
        guard case .available(let m) = replaced else { return XCTFail("\(replaced)") }
        XCTAssertEqual(m.durationSeconds, 99, accuracy: 0.001)
        let count = await provider.probeCount
        XCTAssertEqual(count, 2)
    }

    func testFailuresAreTypedAndNeverThrow() async throws {
        let provider = LocalAudioMetadataProvider(resolver: resolver())
        let missing = await provider.metadata(for: asset(dir.appendingPathComponent("nope.flac")))
        XCTAssertEqual(missing, .temporarilyInaccessible)
        let bad = try write(Data("not audio at all".utf8), "b.flac")
        let unsupported = await provider.metadata(for: asset(bad, id: 2))
        XCTAssertEqual(unsupported, .unsupported)
    }

    func testFillingMissingKeepsDescriptiveMetadata() {
        let m = LocalAudioTechnicalMetadata(durationSeconds: 5, sampleRate: 48000, channelCount: 2,
                                            frameCount: 240000, isSeekable: false)
        let t = Track(id: 1, albumId: nil, sourceId: 1, title: "Edited", trackNo: nil, discNo: nil,
                      durationSec: nil, codec: nil, sampleRate: nil, bitDepthOrBitrate: nil, sortKey: "e")
        let filled = m.fillingMissing(of: t)
        XCTAssertEqual(filled.title, "Edited")
        XCTAssertEqual(filled.durationSec, 5)
        XCTAssertEqual(filled.sampleRate, 48000)
    }
}
