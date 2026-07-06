import AppKit

/// Minimal self-updater: polls this repo's GitHub Releases, and if a newer
/// tag exists, downloads the built .zip, swaps /Applications/CmdTabSwitcher.app,
/// and relaunches — no Sparkle, no separate signing keys, just the same code
/// signing identity every build already uses.
enum Updater {
    static let owner = "borissharikoff-droid"
    static let repo = "CmdTabSwitcher"
    static let assetName = "CmdTabSwitcher.zip"

    struct ReleaseInfo {
        let version: String
        let downloadURL: URL
    }

    static func currentVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static func checkForUpdate(completion: @escaping (ReleaseInfo?) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { data, _, error in
            guard
                let data, error == nil,
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let tag = json["tag_name"] as? String,
                let assets = json["assets"] as? [[String: Any]],
                let asset = assets.first(where: { ($0["name"] as? String) == assetName }),
                let urlString = asset["browser_download_url"] as? String,
                let downloadURL = URL(string: urlString)
            else {
                completion(nil)
                return
            }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            completion(ReleaseInfo(version: version, downloadURL: downloadURL))
        }.resume()
    }

    /// Plain dotted-numeric comparison ("1.2.0" > "1.10.0" bugs are the usual
    /// semver footgun — comparing component-by-component as integers avoids it).
    static func isNewer(_ remote: String, than local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }

    /// `progress` fires on the main thread with 0...1 as the download streams
    /// in — driven by the task's own `Progress` object via KVO, so it reflects
    /// real bytes received, not a guess.
    static func downloadAndInstall(
        _ release: ReleaseInfo,
        progress: @escaping (Double) -> Void,
        completion: @escaping (Bool) -> Void
    ) {
        var observation: NSKeyValueObservation?
        let task = URLSession.shared.downloadTask(with: release.downloadURL) { tempURL, _, error in
            observation?.invalidate()
            observation = nil

            guard let tempURL, error == nil else {
                NSLog("CmdTabSwitcher: update download failed: \(error?.localizedDescription ?? "?")")
                completion(false)
                return
            }
            let zipPath = "/tmp/CmdTabSwitcher-update-\(release.version).zip"
            try? FileManager.default.removeItem(atPath: zipPath)
            do {
                try FileManager.default.copyItem(at: tempURL, to: URL(fileURLWithPath: zipPath))
            } catch {
                NSLog("CmdTabSwitcher: update copy failed: \(error)")
                completion(false)
                return
            }
            installFromZip(zipPath: zipPath, completion: completion)
        }

        observation = task.progress.observe(\.fractionCompleted, options: [.new]) { taskProgress, _ in
            let fraction = taskProgress.fractionCompleted
            DispatchQueue.main.async { progress(fraction) }
        }

        task.resume()
    }

    private static func installFromZip(zipPath: String, completion: @escaping (Bool) -> Void) {
        let extractDir = "/tmp/cmdtabswitcher-update-extract"
        try? FileManager.default.removeItem(atPath: extractDir)
        try? FileManager.default.createDirectory(atPath: extractDir, withIntermediateDirectories: true)

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", zipPath, "-d", extractDir]
        do {
            try unzip.run()
        } catch {
            completion(false)
            return
        }
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            completion(false)
            return
        }

        let newAppPath = "\(extractDir)/CmdTabSwitcher.app"
        guard FileManager.default.fileExists(atPath: newAppPath) else {
            completion(false)
            return
        }

        // We can't safely rewrite our own running .app bundle in place, so a
        // tiny detached script does the swap right after we quit, then
        // relaunches us with a plain `open` — this works regardless of how
        // the app was originally started (manually, or via the SMAppService
        // "start at login" registration), unlike depending on a specific
        // LaunchAgent label being loaded.
        let script = """
        #!/bin/sh
        sleep 1
        rm -rf "/Applications/CmdTabSwitcher.app"
        cp -R "\(newAppPath)" "/Applications/CmdTabSwitcher.app"
        open -a "/Applications/CmdTabSwitcher.app"
        rm -rf "\(extractDir)" "\(zipPath)"
        """
        let scriptPath = "/tmp/cmdtabswitcher-apply-update.sh"
        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)
        } catch {
            completion(false)
            return
        }

        let apply = Process()
        apply.executableURL = URL(fileURLWithPath: "/bin/sh")
        apply.arguments = [scriptPath]
        do {
            try apply.run()
        } catch {
            completion(false)
            return
        }

        completion(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }
}
