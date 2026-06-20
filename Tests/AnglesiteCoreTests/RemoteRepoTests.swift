import Testing
import Foundation
@testable import AnglesiteCore

@Suite struct RemoteRepoTests {
    @Test func parsesHTTPSRemote() {
        let repo = RemoteRepo.parse(remoteURL: "https://github.com/acme/my-site.git\n")
        #expect(repo == RemoteRepo(url: URL(string: "https://github.com/acme/my-site")!, owner: "acme", name: "my-site"))
    }

    @Test func parsesSSHRemote() {
        let repo = RemoteRepo.parse(remoteURL: "git@github.com:acme/my-site.git")
        #expect(repo?.owner == "acme")
        #expect(repo?.name == "my-site")
        #expect(repo?.url == URL(string: "https://github.com/acme/my-site"))
    }

    @Test func stripsDotGitAndWhitespace() {
        let repo = RemoteRepo.parse(remoteURL: "  https://github.com/acme/site  ")
        #expect(repo?.name == "site")
    }

    @Test func rejectsGarbage() {
        #expect(RemoteRepo.parse(remoteURL: "") == nil)
        #expect(RemoteRepo.parse(remoteURL: "not-a-url") == nil)
    }
}
