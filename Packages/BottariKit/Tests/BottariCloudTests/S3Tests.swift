import BottariCore
import BottariTransfer
import Foundation
import Testing
@testable import BottariCloud

@Suite struct AWSSignerTests {
    /// The examples from AWS's "Signature Calculations for the Authorization Header" page.
    let signer = AWSSigner(accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", region: "us-east-1")
    let date = AWSSigner.timestamp.date(from: "20130524T000000Z")!

    @Test func getObjectExample() {
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!)
        request.setValue("bytes=0-9", forHTTPHeaderField: "Range")
        signer.sign(&request, payloadHash: AWSSigner.emptyPayloadHash, date: date)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    @Test func listObjectsExampleWithQuery() {
        var request = URLRequest(url: URL(string: "https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J")!)
        signer.sign(&request, payloadHash: AWSSigner.emptyPayloadHash, date: date)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.hasSuffix("Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7") == true)
    }

    @Test func urlsForAWSAndCompatibleStores() throws {
        #expect(try S3Configuration(bucket: "b", region: "ap-northeast-2", accessKey: "k").url(for: "a b/한.txt").absoluteString
                == "https://b.s3.ap-northeast-2.amazonaws.com/a%20b/%ED%95%9C.txt")
        #expect(try S3Configuration(bucket: "b", endpoint: "http://minio.local:9000", accessKey: "k", usesPathStyle: true).url(for: "x", query: [("uploads", "")]).absoluteString
                == "http://minio.local:9000/b/x?uploads=")
        #expect(try S3Configuration(bucket: "b", endpoint: "https://acct.r2.cloudflarestorage.com", accessKey: "k").url(for: "x").absoluteString
                == "https://b.acct.r2.cloudflarestorage.com/x")
    }
}

@Suite struct S3ProviderTests {
    let bucket = "bucket-\(UUID().uuidString.prefix(8).lowercased())"

    var provider: S3Provider {
        S3Provider(configuration: S3Configuration(bucket: bucket, accessKey: FakeS3.signer.accessKey), secretKey: "bottari-secret", session: FakeS3.session())
    }

    @Test func writesListsAndReads() async throws {
        let provider = provider
        try await provider.makeDirectory("/site")
        try await provider.write("/site/index.html", data: Data("<h1>hi</h1>".utf8))
        try await provider.write("/site/css/app.css", data: Data("body{}".utf8))
        try await provider.write("/readme.md", data: Data("# 보따리".utf8))
        try await provider.write("/공백 있는 이름 & 기호+.txt", data: Data("ok".utf8))

        #expect(try await provider.list(.root).map(\.name) == ["site", "readme.md", "공백 있는 이름 & 기호+.txt"])
        #expect(try await provider.list("/site").map(\.name) == ["css", "index.html"])
        #expect(try await provider.readData("/site/index.html") == Data("<h1>hi</h1>".utf8))
        #expect(try await provider.readData("/site/index.html", range: 4..<6) == Data("hi".utf8))
        #expect(try await provider.readData("/공백 있는 이름 & 기호+.txt") == Data("ok".utf8))
        #expect(try await provider.stat("/readme.md").size == Int64("# 보따리".utf8.count))
        #expect(try await provider.stat("/site").isDirectory)
        await #expect(throws: ProviderError.notFound("/missing")) { try await provider.stat("/missing") }
    }

    @Test func bigFilesGoUpInParts() async throws {
        let provider = provider
        let payload = Data((0..<(S3Provider.chunkSize * 2 + 1234)).map { UInt8(truncatingIfNeeded: $0 &* 13) })
        try await provider.write("/backup.tar", from: AsyncThrowingStream { continuation in
            var offset = 0
            while offset < payload.count {
                let end = min(offset + 3_000_000, payload.count)
                continuation.yield(payload.subdata(in: offset..<end))
                offset = end
            }
            continuation.finish()
        })

        let log = FakeS3.bucket(bucket).log
        #expect(log.filter { $0.hasPrefix("PUT backup.tar?partNumber&uploadId") }.count == 3)
        #expect(log.contains("POST backup.tar?uploadId"))
        #expect(try await provider.readData("/backup.tar") == payload)
    }

    @Test func copiesMovesAndDeletesFoldersOnTheServer() async throws {
        let provider = provider
        try await provider.write("/v1/app.js", data: Data("1".utf8))
        try await provider.write("/v1/lib/util.js", data: Data("2".utf8))

        try await provider.copy("/v1", to: "/v2")
        #expect(try await provider.readData("/v2/lib/util.js") == Data("2".utf8))
        #expect(FakeS3.bucket(bucket).log.filter { $0.hasPrefix("GET v1") }.isEmpty, "copies without downloading")

        try await provider.move("/v2", to: "/v3")
        #expect(try await provider.list(.root).map(\.name) == ["v1", "v3"])

        try await provider.delete("/v1")
        #expect(try await provider.list(.root).map(\.name) == ["v3"])
        await #expect(throws: ProviderError.alreadyExists("/v3")) { try await provider.copy("/v3", to: "/v3") }
    }

    @Test func aFileWrittenIntoAFolderWhileItMovesIsKept() async throws {
        let provider = provider
        try await provider.write("/a/1.txt", data: Data("1".utf8))
        FakeS3.land("a/late.txt", Data("late".utf8), duringNextCopyIn: bucket)

        try await provider.move("/a", to: "/b")
        #expect(try await provider.readData("/b/1.txt") == Data("1".utf8))
        let names = try await provider.list("/a").map(\.name) + provider.list("/b").map(\.name)
        #expect(names.contains("late.txt"))
    }

    @Test func aCopyThatFailsAfterAnsweringKeepsTheOriginal() async throws {
        let provider = provider
        try await provider.write("/only.txt", data: Data("precious".utf8))
        FakeS3.failCopies(in: bucket, true)
        await #expect(throws: ProviderError.self) { try await provider.move("/only.txt", to: "/moved.txt") }
        FakeS3.failCopies(in: bucket, false)
        #expect(try await provider.readData("/only.txt") == Data("precious".utf8))
    }

    @Test func bigObjectsAreCopiedInParts() async throws {
        let small = S3Provider(configuration: S3Configuration(bucket: bucket, accessKey: FakeS3.signer.accessKey), secretKey: "bottari-secret", session: FakeS3.session(), largestSingleCopy: 10)
        let payload = Data((0..<(Int(S3Provider.copyPartSize) / 1024 / 1024 + 37)).map { UInt8(truncatingIfNeeded: $0) })
        try await small.write("/big.bin", data: payload)
        try await small.copy("/big.bin", to: "/copy.bin")
        #expect(try await small.readData("/copy.bin") == payload)
        #expect(FakeS3.bucket(bucket).log.contains("PUT copy.bin?partNumber&uploadId"))
    }

    @Test func uploadsSayWhatKindOfFileTheyAre() {
        #expect(S3Provider.contentType(of: "/site/index.html") == "text/html")
        #expect(S3Provider.contentType(of: "/img/logo.png") == "image/png")
        #expect(S3Provider.contentType(of: "/blob") == "application/octet-stream")
    }

    @Test func keysThatAreNotPathsAreLeftOut() async throws {
        FakeS3.put("a//x.txt", Data("x".utf8), in: bucket)
        FakeS3.put("a/./y.txt", Data("y".utf8), in: bucket)
        FakeS3.put("a/z.txt", Data("z".utf8), in: bucket)
        // "/a" must not list itself, or walking it would never end.
        #expect(try await provider.list("/a").map(\.name) == ["z.txt"])
    }

    @Test func anObjectAndAFolderOfOneNameAreTwoItemsThatActionsTellApart() async throws {
        let provider = provider
        FakeS3.put("docs", Data("file".utf8), in: bucket)
        FakeS3.put("docs/index.html", Data("<h1>".utf8), in: bucket)
        FakeS3.put("notes", Data("file".utf8), in: bucket)
        FakeS3.put("notes/a.txt", Data("a".utf8), in: bucket)
        func keys() -> Set<String> { Set(FakeS3.bucket(bucket).objects.keys) }

        let items = try await provider.list(.root)
        #expect(items.map(\.name) == ["docs", "notes", "docs", "notes"])
        #expect(Set(items.map(\.id)).count == 4)
        let docsFolder = try #require(items.first { $0.name == "docs" && $0.isDirectory })
        let notesFolder = try #require(items.first { $0.name == "notes" && $0.isDirectory })
        let notesFile = try #require(items.first { $0.name == "notes" && !$0.isDirectory })
        #expect(try await provider.readData(notesFile.path) == Data("file".utf8))
        #expect(try await provider.list(notesFolder.path).map(\.name) == ["a.txt"])

        try await provider.copy(notesFolder, to: "/copied")
        #expect(keys() == ["docs", "docs/index.html", "notes", "notes/a.txt", "copied/", "copied/a.txt"])
        try await provider.move(docsFolder, to: "/site")
        #expect(keys() == ["docs", "site/", "site/index.html", "notes", "notes/a.txt", "copied/", "copied/a.txt"])
        try await provider.delete(notesFolder)
        #expect(keys() == ["docs", "site/", "site/index.html", "notes", "copied/", "copied/a.txt"])
        try await provider.write("/notes/b.txt", data: Data("b".utf8))
        try await provider.delete(notesFile)
        #expect(keys() == ["docs", "site/", "site/index.html", "notes/b.txt", "copied/", "copied/a.txt"])
    }

    @MainActor @Test func movingAFolderToTheMacLeavesTheFileOfItsName() async throws {
        let provider = provider
        FakeS3.put("docs", Data("file".utf8), in: bucket)
        FakeS3.put("docs/index.html", Data("<h1>".utf8), in: bucket)
        let mac = FileManager.default.temporaryDirectory.appending(path: "bottari-s3-move-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: mac) }
        try FileManager.default.createDirectory(at: mac, withIntermediateDirectories: true)
        let folder = try #require(try await provider.list(.root).first(where: \.isDirectory))
        let queue = TransferQueue()

        let job = queue.enqueue(.move, [folder], from: TransferEndpoint(provider), to: TransferEndpoint(LocalFileProvider()), into: RemotePath(mac.path))
        let deadline = ContinuousClock.now + .seconds(10)
        while !job.state.hasEnded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        #expect(job.state == .finished)
        #expect((try? String(contentsOf: mac.appending(path: "docs/index.html"), encoding: .utf8)) == "<h1>")
        #expect(Set(FakeS3.bucket(bucket).objects.keys) == ["docs"])
    }

    @Test func aPastedSpaceOrNewlineInTheAddressStillConnects() async {
        await #expect(processExitsWith: .success) {
            let aws = S3Configuration(bucket: "pasted ", region: "us-east-1\n", accessKey: FakeS3.signer.accessKey)
            let minio = S3Configuration(bucket: " pasted", endpoint: "http://minio.local:9000 ", accessKey: FakeS3.signer.accessKey, usesPathStyle: true)
            do {
                try await S3Provider(configuration: aws, secretKey: "bottari-secret", session: FakeS3.session()).write("/a.txt", data: Data("a".utf8))
                #expect(try await S3Provider(configuration: minio, secretKey: "bottari-secret", session: FakeS3.session()).list(.root).map(\.name) == ["a.txt"])
            } catch {
                Issue.record(error)
            }
        }
    }

    @Test func anAddressThatIsNoURLFailsInsteadOfCrashing() async {
        await #expect(processExitsWith: .success) {
            let spaced = S3Configuration(bucket: "my bucket", accessKey: FakeS3.signer.accessKey)
            await #expect(throws: ProviderError.self) {
                try await S3Provider(configuration: spaced, secretKey: "bottari-secret", session: FakeS3.session()).list(.root)
            }
        }
    }

    @Test func keysXMLCannotCarryListWithTheRest() async throws {
        FakeS3.put("a/bad\u{1}name", Data("1".utf8), in: bucket)
        FakeS3.put("a/sub/y.txt", Data("y".utf8), in: bucket)
        FakeS3.put("a/two\rlines", Data("2".utf8), in: bucket)
        FakeS3.put("a/z.txt", Data("z".utf8), in: bucket)
        let provider = provider

        let items = try await provider.list("/a")
        #expect(Set(items.map(\.name)) == ["bad\u{1}name", "sub", "two\rlines", "z.txt"])
        let twoLines = try #require(items.first { $0.name.hasPrefix("two") })
        #expect(try await provider.readData(twoLines.path) == Data("2".utf8))
    }

    @Test func aListingThatCannotBeReadFails() async throws {
        FakeS3.ignoreEncodingType(in: bucket)
        FakeS3.put("a/bad\u{1}name", Data("1".utf8), in: bucket)
        FakeS3.put("a/z.txt", Data("z".utf8), in: bucket)
        await #expect(throws: ProviderError.self) { try await provider.list("/a") }
    }

    @Test func aWrongSecretIsRefused() async throws {
        let wrong = S3Provider(configuration: S3Configuration(bucket: bucket, accessKey: FakeS3.signer.accessKey), secretKey: "nope", session: FakeS3.session())
        await #expect(throws: ProviderError.permissionDenied(.root)) { try await wrong.list(.root) }
    }
}
