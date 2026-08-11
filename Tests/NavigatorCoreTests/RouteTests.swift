import Foundation
import Testing
@testable import NavigatorCore

@Suite struct PathNormalization {
    @Test(arguments: [
        ("/a/b/../c", "/a/c"),
        ("/a/./b", "/a/b"),
        ("/a//b", "/a/b"),
        ("/a/b/", "/a/b"),
        ("/a/b/../../c", "/c"),
        ("/..", "/"),
        ("/", "/"),
    ])
    func normalizesLexically(_ input: String, _ expected: String) {
        #expect(PathNormalizer.normalize(input) == expected)
    }

    @Test func containmentIsBoundaryAware() {
        #expect(PathNormalizer.contains(dir: "/a/b", path: "/a/b/c.txt"))
        #expect(PathNormalizer.contains(dir: "/a/b", path: "/a/b"))
        // /a/bcd must not count as inside /a/b
        #expect(!PathNormalizer.contains(dir: "/a/b", path: "/a/bcd/e.txt"))
        #expect(!PathNormalizer.contains(dir: "/a/b", path: "/a/c.txt"))
        #expect(!PathNormalizer.contains(dir: "/a/b", path: "/"))
    }

    @Test func containmentResolvesTraversalBeforeComparing() {
        #expect(!PathNormalizer.contains(dir: "/a/b", path: "/a/b/../../etc/passwd"))
    }
}

@Suite struct RouteClassification {
    let subject = RouteClassifier()
    let session = Session(
        id: "s1", cwd: "/Users/t/Projects/app",
        startedAt: Date(timeIntervalSince1970: 0),
        lastEventAt: Date(timeIntervalSince1970: 0))

    @Test func writeInsideCwdIsOnRoute() {
        let status = subject.classify(
            toolName: "Edit",
            toolInput: ["file_path": .string("/Users/t/Projects/app/src/main.swift")],
            session: session)
        #expect(status == .onRoute)
    }

    @Test func writeOutsideCwdIsOffRoute() {
        let status = subject.classify(
            toolName: "Write",
            toolInput: ["file_path": .string("/Users/t/.zshrc")],
            session: session)
        guard case .offRoute = status else {
            Issue.record("expected offRoute")
            return
        }
    }

    @Test func writeInsideDeclaredDirIsOnRoute() {
        var wider = session
        wider.declaredDirs = ["/Users/t/Projects/shared"]
        let status = subject.classify(
            toolName: "Edit",
            toolInput: ["file_path": .string("/Users/t/Projects/shared/lib.swift")],
            session: wider)
        #expect(status == .onRoute)
    }

    @Test func relativePathIsResolvedAgainstCwd() {
        let status = subject.classify(
            toolName: "Edit",
            toolInput: ["file_path": .string("src/main.swift")],
            session: session)
        #expect(status == .onRoute)
    }

    @Test func relativeTraversalEscapingCwdIsOffRoute() {
        let status = subject.classify(
            toolName: "Write",
            toolInput: ["file_path": .string("../other/file.swift")],
            session: session)
        guard case .offRoute = status else {
            Issue.record("expected offRoute")
            return
        }
    }

    @Test func readsAreAlwaysOnRoute() {
        // Reading outside the project is how you look things up. It is not drift.
        let status = subject.classify(
            toolName: "Read",
            toolInput: ["file_path": .string("/usr/share/doc/thing")],
            session: session)
        #expect(status == .onRoute)
    }

    @Test func bashWithNoPathIsOnRoute() {
        // Location is not knowable from the command string; the reversibility
        // axis is what guards these.
        let status = subject.classify(
            toolName: "Bash",
            toolInput: ["command": .string("swift build")],
            session: session)
        #expect(status == .onRoute)
    }

    @Test func toolWithoutPathIsOnRoute() {
        #expect(subject.classify(toolName: "Glob", toolInput: nil, session: session) == .onRoute)
    }
}
