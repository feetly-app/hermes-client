import Foundation
import HermesAPI
import Testing

@testable import HermesChat

@Suite("Stored image markers")
struct StoredImageMarkersTests {
    private let digest = "418ff2aae3eb452752ef0e7d1e7c06049ac0bf43f7736f483509f4fe1b4eb0bf"

    @Test("a message sent with an image loses its marker and placeholder, and names the image by digest")
    func pathMarker() {
        let content = """
            Can you parse these?

            [Image attached at: /opt/data/cache/documents/native-inputs/\(digest)/api_418ff2aae3eb452752ef0e7d1e7c0604.jpg]
            [screenshot]
            """

        let parsed = StoredImageMarkers.parse(content)

        #expect(parsed.text == "Can you parse these?")
        #expect(parsed.images.count == 1)
        #expect(parsed.images.first?.sha256 == digest)
    }

    @Test("several images each give a reference, in order")
    func severalImages() {
        let other = String(repeating: "a", count: 64)
        let content = """
            Two photos

            [Image attached at: /x/native-inputs/\(digest)/one.jpg]
            [Image attached at: /x/native-inputs/\(other)/two.png]
            [screenshot]
            [screenshot]
            """

        let parsed = StoredImageMarkers.parse(content)

        #expect(parsed.text == "Two photos")
        #expect(parsed.images.map(\.sha256) == [digest, other])
    }

    @Test("an image without text leaves empty text")
    func imageOnly() {
        let parsed = StoredImageMarkers.parse("[Image attached at: /x/native-inputs/\(digest)/a.jpg]\n[screenshot]")

        #expect(parsed.text.isEmpty)
        #expect(parsed.images.count == 1)
    }

    @Test("a remote image marker is a reference without a digest")
    func remoteMarker() {
        let parsed = StoredImageMarkers.parse("Look\n\n[Image attached: https://hermes.example.test/a.png]")

        #expect(parsed.text == "Look")
        #expect(parsed.images == [.init(location: "https://hermes.example.test/a.png", sha256: nil)])
    }

    @Test("a path whose folder is not a digest gives no digest")
    func pathWithoutDigest() {
        let parsed = StoredImageMarkers.parse("[Image attached at: /tmp/photo.jpg]")

        #expect(parsed.images == [.init(location: "/tmp/photo.jpg", sha256: nil)])
    }

    @Test("text without markers is kept, a [screenshot] line included")
    func noMarkers() {
        let parsed = StoredImageMarkers.parse("  Write [screenshot]\n[screenshot]  ")

        #expect(parsed.text == "Write [screenshot]\n[screenshot]")
        #expect(parsed.images.isEmpty)
    }

    @Test("a marker quoted inside a sentence is not taken out")
    func markerInsideLine() {
        let parsed = StoredImageMarkers.parse("The line [Image attached at: /a/b.jpg] appears")

        #expect(parsed.images.isEmpty)
    }
}

/// Answers from a dictionary of digests and counts the fetches.
private actor FakeImageFetcher: StoredImageFetching {
    var images: [String: ImageAttachment]
    var failing = false
    private(set) var fetches: [String] = []

    init(images: [String: ImageAttachment] = [:]) {
        self.images = images
    }

    func setFailing(_ value: Bool) { failing = value }

    func image(sha256: String) async throws -> ImageAttachment? {
        fetches.append(sha256)
        try await Task.sleep(for: .milliseconds(20))
        if failing { throw HermesAPIError.network }
        return images[sha256]
    }
}

@Suite("Stored image loader")
struct StoredImageLoaderTests {
    private let digest = String(repeating: "a", count: 64)

    private func image(_ text: String, mimeType: String = "image/png") throws -> ImageAttachment {
        try #require(ImageAttachment(mimeType: mimeType, data: Data(text.utf8)))
    }

    private func temporaryCache() -> StoredImageCache {
        StoredImageCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    @Test("an image is fetched once, kept in the cache, and found again by digest in any case")
    func fetchesThenCaches() async throws {
        let photo = try image("png bytes")
        let fetcher = FakeImageFetcher(images: [digest: photo])
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let loader = StoredImageLoader(fetcher: fetcher, cache: cache)

        #expect(await loader.image(sha256: digest.uppercased()) == photo)
        #expect(await loader.image(sha256: digest) == photo)
        #expect(await fetcher.fetches == [digest])
        #expect(cache.image(sha256: digest) == photo)
    }

    @Test("concurrent requests for one digest share a single fetch")
    func sharesInFlightFetch() async throws {
        let photo = try image("gif bytes", mimeType: "image/gif")
        let fetcher = FakeImageFetcher(images: [digest: photo])
        let loader = StoredImageLoader(fetcher: fetcher)

        async let first = loader.image(sha256: digest)
        async let second = loader.image(sha256: digest)
        let results = await [first, second]

        #expect(results == [photo, photo])
        #expect(await fetcher.fetches == [digest])
    }

    @Test("a missing image or a failure gives nil and is not cached; a later call tries again")
    func failuresAreNotCached() async throws {
        let photo = try image("webp bytes", mimeType: "image/webp")
        let fetcher = FakeImageFetcher(images: [digest: photo])
        let loader = StoredImageLoader(fetcher: fetcher, cache: nil)

        await fetcher.setFailing(true)
        #expect(await loader.image(sha256: digest) == nil)
        await fetcher.setFailing(false)
        #expect(await loader.image(sha256: digest) == photo)
        #expect(await loader.image(sha256: String(repeating: "b", count: 64)) == nil)
    }

    @Test("a text that is not a digest is never fetched")
    func invalidDigest() async {
        let fetcher = FakeImageFetcher()
        let loader = StoredImageLoader(fetcher: fetcher)

        #expect(await loader.image(sha256: "../etc/passwd") == nil)
        #expect(await loader.image(sha256: "abc") == nil)
        #expect(await fetcher.fetches.isEmpty)
    }

    @Test("the cache keeps image types and refuses other ones and invalid digests")
    func cacheRoundTrip() throws {
        let cache = temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache.directory) }
        let jpeg = try image("jpeg bytes", mimeType: "image/jpeg")
        let svg = try image("<svg/>", mimeType: "image/svg+xml")
        let other = String(repeating: "c", count: 64)

        cache.save(jpeg, sha256: digest)
        cache.save(svg, sha256: other)
        cache.save(jpeg, sha256: "../escape")

        #expect(cache.image(sha256: digest) == jpeg)
        #expect(cache.image(sha256: other) == nil)
        #expect(cache.image(sha256: "../escape") == nil)
    }
}
