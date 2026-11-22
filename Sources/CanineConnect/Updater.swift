import CryptoKit
import Foundation

/// A release of Canine Connect newer than the one running.
struct AppUpdate: Equatable {
    let version: String
    let download: URL
    /// The zip's SHA-256 as GitHub recorded it when the release workflow uploaded the file.
    let sha256: String
}

enum UpdateError: LocalizedError {
    case notInstalled
    case translocated
    case notWritable(String)
    case feed(String)
    case download(String)
    case checksumMismatch
    case invalidBundle(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "This copy of Canine Connect isn't an installed app, so it can't update itself."
        case .translocated:
            return "Move Canine Connect to your Applications folder and open it from there, then update."
        case .notWritable(let folder):
            return "Canine Connect can't write to \(folder). Download the new version from \(Updater.releasesPage.absoluteString) instead."
        case .feed(let message):
            return "Couldn't check for updates: \(message)"
        case .download(let message):
            return "Couldn't download the update: \(message)"
        case .checksumMismatch:
            return "The update didn't match the checksum GitHub published for it, so it wasn't installed."
        case .invalidBundle(let message):
            return "The update wasn't installed: \(message)"
        }
    }
}

/// Updates the app from its GitHub releases, the same files Canine's download page links to. The release workflow
/// attaches CanineConnect-macos-<arch>.zip to every tag; this downloads the one for this Mac, checks it against the
/// SHA-256 GitHub recorded for it, and swaps it in for the running bundle.
///
/// The app is ad-hoc signed, so there is no publisher signature to check an update against: an update is trusted
/// because GitHub served it as a release of this repository, over HTTPS. Whoever can publish a release there can
/// update every installed copy.
enum Updater {
    static let repository = "CanineHQ/connect"
    static let releasesPage = URL(string: "https://github.com/\(repository)/releases/latest")!
    private static let feed = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    private static let bundleIdentifier = "sh.canine.connect"

    #if arch(arm64)
    static let architecture = "arm64"
    #else
    static let architecture = "x86_64"
    #endif

    /// Nil when running unbundled (`swift run`, `--snapshot`), where there is nothing to update.
    static var currentVersion: String? {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
            let digest: String?
        }

        let tagName: String
        let assets: [Asset]
    }

    /// The latest release, if it is newer than this copy. Nil when this copy is up to date.
    static func latest() async throws -> AppUpdate? {
        guard let currentVersion else { throw UpdateError.notInstalled }
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let release: Release
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { throw UpdateError.feed("GitHub answered \(status).") }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            release = try decoder.decode(Release.self, from: data)
        } catch let error as UpdateError {
            throw error
        } catch {
            throw UpdateError.feed(error.localizedDescription)
        }

        let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        guard isVersion(version, newerThan: currentVersion) else { return nil }
        let name = "CanineConnect-macos-\(architecture).zip"
        guard let asset = release.assets.first(where: { $0.name == name }) else {
            throw UpdateError.feed("version \(version) has no download for this Mac.")
        }
        guard let digest = asset.digest, digest.hasPrefix("sha256:") else {
            throw UpdateError.feed("version \(version) has no checksum to verify the download against.")
        }
        return AppUpdate(version: version, download: asset.browserDownloadUrl, sha256: String(digest.dropFirst("sha256:".count)))
    }

    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        candidate.compare(current, options: .numeric) == .orderedDescending
    }

    /// Downloads and checks an update, without touching the installed app. Returns the new bundle, in a temporary
    /// folder on the same volume as the installed one so `replace(with:)` can move it into place.
    static func stage(_ update: AppUpdate) async throws -> URL {
        let installed = try installedBundle()
        let files = FileManager.default
        let work: URL
        do {
            work = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: installed, create: true)
        } catch {
            throw UpdateError.notWritable(installed.deletingLastPathComponent().path)
        }

        do {
            let zip = work.appendingPathComponent("update.zip")
            do {
                let (downloaded, response) = try await URLSession.shared.download(from: update.download)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else { throw UpdateError.download("GitHub answered \(status).") }
                try files.moveItem(at: downloaded, to: zip)
            } catch let error as UpdateError {
                throw error
            } catch {
                throw UpdateError.download(error.localizedDescription)
            }

            let data = try Data(contentsOf: zip, options: .mappedIfSafe)
            let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard sha256 == update.sha256.lowercased() else { throw UpdateError.checksumMismatch }

            // ditto, like the release build that made the zip: it keeps the bundle's permissions and signature.
            let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
            let unzip = try await Shell.run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-x", "-k", zip.path, unpacked.path])
            guard unzip.succeeded else { throw UpdateError.invalidBundle(unzip.errorMessage) }
            try? files.removeItem(at: zip)

            let contents = try files.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
            guard let app = contents.first(where: { $0.pathExtension == "app" }), let bundle = Bundle(url: app) else {
                throw UpdateError.invalidBundle("the download doesn't contain the app.")
            }
            guard bundle.bundleIdentifier == bundleIdentifier,
                  bundle.infoDictionary?["CFBundleShortVersionString"] as? String == update.version else {
                throw UpdateError.invalidBundle("the download isn't Canine Connect \(update.version).")
            }
            // Catches a bundle damaged on the way; an ad-hoc signature says nothing about who built it.
            let signature = try await Shell.run(URL(fileURLWithPath: "/usr/bin/codesign"), ["--verify", "--deep", "--strict", app.path])
            guard signature.succeeded else { throw UpdateError.invalidBundle(signature.errorMessage) }
            return app
        } catch {
            try? files.removeItem(at: work)
            throw error
        }
    }

    /// Puts a staged bundle where the running app is. The running process keeps going on the old files until it exits.
    static func replace(with staged: URL) throws {
        let installed = try installedBundle()
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent().deletingLastPathComponent()) }
        do {
            _ = try FileManager.default.replaceItemAt(installed, withItemAt: staged)
        } catch {
            throw UpdateError.notWritable(installed.deletingLastPathComponent().path)
        }
    }

    /// Opens the installed app again once this process has exited. Call right before terminating.
    static func relaunchAfterExit() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", "while /bin/kill -0 \"$0\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$1\"",
            String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundleURL.path
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private static func installedBundle() throws -> URL {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { throw UpdateError.notInstalled }
        // Opened straight from a quarantined download, macOS runs the app from a read-only copy somewhere else.
        guard !bundle.path.contains("/AppTranslocation/") else { throw UpdateError.translocated }
        let folder = bundle.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: folder) else { throw UpdateError.notWritable(folder) }
        return bundle
    }
}
