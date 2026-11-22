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

@Suite("Sent image store")
struct SentImageStoreTests {
    private func image(_ text: String, mimeType: String = "image/png") throws -> ImageAttachment {
        try #require(ImageAttachment(mimeType: mimeType, data: Data(text.utf8)))
    }

    @Test("SHA-256 matches known vectors")
    func digestVectors() {
        #expect(sha256Hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(sha256Hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let long = Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)
        #expect(sha256Hex(long) == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        #expect(
            sha256Hex(Data(repeating: 0x61, count: 1000))
                == "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    @Test("a saved image is found by the digest of its bytes, with its type")
    func directoryRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DirectorySentImageStore(directory: directory)
        let photo = try image("png bytes")

        store.save(photo)

        #expect(store.image(sha256: sha256Hex(photo.data)) == photo)
        #expect(store.image(sha256: String(repeating: "0", count: 64)) == nil)
        #expect(store.image(sha256: "../etc/passwd") == nil)
    }

    @Test("the in-memory store finds an image by digest, in any case")
    func inMemory() throws {
        let store = InMemorySentImageStore()
        let photo = try image("jpeg bytes", mimeType: "image/jpeg")

        store.save(photo)

        #expect(store.image(sha256: sha256Hex(photo.data).uppercased()) == photo)
    }
}
