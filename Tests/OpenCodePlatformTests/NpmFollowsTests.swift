import Testing
import OpenCodePlatform
import OpenCodeUtil

@Suite("NpmPlatform.follows Parity Tests")
struct NpmFollowsTests {
    @Test("classifyFollows distinguishes explicit @latest, ranges, git semver, bare names, dist-tags, commits, and refs")
    func classifyFollowsSpecs() {
        // Bare names stay on what is installed
        #expect(NpmSpec.classifyFollows("plugin") == .never)
        #expect(NpmSpec.classifyFollows("@scope/plugin") == .never)

        // Explicit @latest and semver ranges follow
        #expect(NpmSpec.classifyFollows("plugin@latest") == .always)
        #expect(NpmSpec.classifyFollows("@scope/plugin@latest") == .always)
        #expect(NpmSpec.classifyFollows("plugin@^1.0.0") == .always)
        #expect(NpmSpec.classifyFollows("plugin@~1.2.0") == .always)
        #expect(NpmSpec.classifyFollows("plugin@>=1.0.0 <2.0.0") == .always)
        #expect(NpmSpec.classifyFollows("plugin@1.x") == .always)
        #expect(NpmSpec.classifyFollows("plugin@*") == .always)

        // Exact versions and non-latest dist-tags stay pinned
        #expect(NpmSpec.classifyFollows("plugin@1.2.3") == .never)
        #expect(NpmSpec.classifyFollows("plugin@v1.2.3") == .never)
        #expect(NpmSpec.classifyFollows("plugin@=1.2.3") == .never)
        #expect(NpmSpec.classifyFollows("plugin@next") == .never)
        #expect(NpmSpec.classifyFollows("plugin@beta") == .never)

        // Git specs: bare repo and commit stay pinned; semver range follows; named ref defers to remote
        #expect(NpmSpec.classifyFollows("github:acme/plugin") == .never)
        #expect(NpmSpec.classifyFollows("github:acme/plugin#0123456789abcdef") == .never)
        #expect(NpmSpec.classifyFollows("github:acme/plugin#semver:^1.0.0") == .always)
        #expect(
            NpmSpec.classifyFollows("github:acme/plugin#main")
                == .gitRef(repoURL: "https://github.com/acme/plugin.git", ref: "main")
        )
        #expect(
            NpmSpec.classifyFollows("my-pkg@github:acme/plugin#v1.0.0")
                == .gitRef(repoURL: "https://github.com/acme/plugin.git", ref: "v1.0.0")
        )
    }

    @Test("NpmPlatform.Service.follows queries remote gitRefResolver only for named Git refs")
    func serviceFollowsChecksRemoteGitRef() async throws {
        let fs = InMemoryFileSystem()
        let service = NpmPlatform.Service(
            cacheRoot: "/cache",
            fsUtil: FSUtil.Service(fileSystem: fs),
            gitRefResolver: { _, _, ref, _ in
                if ref == "broken" {
                    struct Boom: Error {}
                    throw Boom()
                }
                return ref == "main"
            }
        )

        #expect(try await service.follows("plugin") == false)
        #expect(try await service.follows("plugin@latest") == true)
        #expect(try await service.follows("plugin@^2.0.0") == true)
        #expect(try await service.follows("plugin@next") == false)
        #expect(try await service.follows("github:acme/plugin#semver:^1.0.0") == true)
        #expect(try await service.follows("github:acme/plugin#main") == true)
        #expect(try await service.follows("github:acme/plugin#v1.0.0") == false)

        await #expect(throws: NpmSpec.InstallFailedError.self) {
            _ = try await service.follows("github:acme/plugin#broken")
        }
    }
}
