import Foundation

/// Paths, identity, and volume for the account that is actually running the app.
/// Nothing here is taken from the machine that built the binary.
struct UserEnvironment: Equatable {
    var home: URL
    var uid: uid_t
    var volume: URL

    static func current() -> UserEnvironment {
        UserEnvironment(
            home: FileManager.default.homeDirectoryForCurrentUser,
            uid: getuid(),
            volume: URL(fileURLWithPath: "/", isDirectory: true)
        )
    }

    var resolvedHome: URL {
        home.resolvingSymlinksInPath().standardizedFileURL
    }
}
