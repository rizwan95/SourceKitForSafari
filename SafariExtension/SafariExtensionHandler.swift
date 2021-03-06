import SafariServices
import OSLog

let log = OSLog(subsystem: "com.kishikawakatsumi.SourceKitForSafari", category: "Safari Extension")

final class SafariExtensionHandler: SFSafariExtensionHandler {
    private let service = SourceKitServiceProxy.shared

    override init() {
        super.init()
        Settings.shared.prepare()
    }

    override func messageReceived(withName messageName: String, from page: SFSafariPage, userInfo: [String : Any]?) {
        switch messageName {
        case "initialize":
            page.getPropertiesWithCompletionHandler { [weak self] (properties) in
                guard let self = self else { return }

                guard let properties = properties, let url = properties.url else {
                    return
                }
                guard let repositoryURL = self.parseGitHubURL(url) else {
                    return
                }

                self.service.synchronizeRepository(repositoryURL) { (_, _) in }
            }
        case "didOpen":
            guard let userInfo = userInfo,
                let resource = userInfo["resource"] as? String,
                let slug = userInfo["slug"] as? String,
                let filepath = userInfo["filepath"] as? String,
                let text = userInfo["text"] as? String
                else { break }
            
            os_log("[SafariExtension] didOpen(file: %{public}s)", log: log, type: .debug, filepath)

            service.sendInitializeRequest(resource: resource, slug: slug) { [weak self] (successfully, _) in
                guard let self = self else { return }

                if successfully {
                    self.service.sendInitializedNotification(resource: resource, slug: slug) { [weak self] (successfully, _)  in
                        guard let self = self else { return }

                        if successfully {
                            self.service.sendDidOpenNotification(resource: resource, slug: slug, path: filepath, text: text) { [weak self] (successfully, _)  in
                                guard let self = self else { return }
                                
                                if successfully {
                                    self.service.sendDocumentSymbolRequest(resource: resource, slug: slug, path: filepath) { (successfully, response) in
                                        guard let value = response["value"] else { return }
                                        page.dispatchMessageToScript(withName: "response", userInfo: ["request": "documentSymbol", "result": "success", "value": value])
                                    }
                                }
                            }
                        }
                    }
                }
            }
        case "hover":
            guard let userInfo = userInfo,
                let resource = userInfo["resource"] as? String,
                let slug = userInfo["slug"] as? String,
                let filepath = userInfo["filepath"] as? String ,
                let line = userInfo["line"] as? Int,
                let character = userInfo["character"] as? Int,
                let text = userInfo["text"] as? String
                else { break }
            var skip = 0
            for character in text {
                if character == " " || character == "." {
                    skip += 1
                } else {
                    break
                }
            }

            os_log("[SafariExtension] hover(file: %{public}s, line: %d, character: %d)", log: log, type: .debug, filepath, line, character + skip)

            service.sendHoverRequest(resource: resource, slug: slug, path: filepath, line: line, character: character + skip) { (successfully, response) in
                if successfully {
                    if let value = response["value"] as? String {
                        page.dispatchMessageToScript(
                            withName: "response",
                            userInfo: ["request": "hover", "result": "success", "value": value, "line": line, "character": character, "text": text]
                        )
                    }
                } else {
                    page.dispatchMessageToScript(withName: "response", userInfo: ["request": "hover", "result": "error"])
                }
            }
        case "definition":
            guard let userInfo = userInfo,
                let resource = userInfo["resource"] as? String,
                let slug = userInfo["slug"] as? String,
                let filepath = userInfo["filepath"] as? String ,
                let line = userInfo["line"] as? Int,
                let character = userInfo["character"] as? Int,
                let text = userInfo["text"] as? String
                else { break }
            var skip = 0
            for character in text {
                if character == " " || character == "." {
                    skip += 1
                } else {
                    break
                }
            }

            os_log("[SafariExtension] definition(file: %{public}s, line: %d, character: %d)", log: log, type: .debug, filepath, line, character + skip)

            service.sendDefinitionRequest(resource: resource, slug: slug, path: filepath, line: line, character: character + skip) { (successfully, response) in
                if successfully {
                    if let value = response["value"] as? [[String: Any]] {
                        let locations = value.compactMap { (location) -> [String: Any]? in
                            guard let uri = location["uri"] as? String, let start = location["start"] as? [String: Any],
                                let line = start["line"] as? Int else { return nil }

                            let filename = location["filename"] ?? ""
                            let content = location["content"] ?? ""
                            
                            if !uri.isEmpty {
                                let ref = uri
                                    .replacingOccurrences(of: resource, with: "")
                                    .replacingOccurrences(of: slug, with: "")
                                    .split(separator: "/")
                                    .joined(separator: "/")
                                    .appending("#L\(line + 1)")

                                return ["uri": ref, "filename": filename, "content": content]
                            } else {
                                return ["uri": "", "filename": filename, "content": content]
                            }
                        }

                        guard !locations.isEmpty else { return }

                        page.dispatchMessageToScript(
                            withName: "response",
                            userInfo: ["request": "definition", "result": "success", "value": ["locations": locations], "line": line, "character": character, "text": text]
                        )
                    }
                } else {
                    page.dispatchMessageToScript(withName: "response", userInfo: ["request": "definition", "result": "error"])
                }
            }
        default:
            break
        }
    }

    override func validateToolbarItem(in window: SFSafariWindow, validationHandler: @escaping ((Bool, String) -> Void)) {
        validationHandler(true, "")
    }

    override func popoverWillShow(in window: SFSafariWindow) {
        let viewController = SafariExtensionViewController.shared
        viewController.updateUI()

        window.getActiveTab { (activeTab) in
            guard let activeTab = activeTab else {
                return
            }

            activeTab.getActivePage { (activePage) in
                guard let activePage = activePage else {
                    return
                }

                activePage.getPropertiesWithCompletionHandler { [weak self] (properties) in
                    guard let properties = properties, let url = properties.url else {
                        return
                    }

                    guard let repositoryURL = self?.parseGitHubURL(url) else {
                        viewController.repository = ""
                        return
                    }

                    viewController.repository = repositoryURL.absoluteString
                }
            }
        }

        if Settings.shared.serverPathOption == .default {
            service.defaultLanguageServerPath { (successfully, response) in
                if successfully {
                    Settings.shared.serverPath = response
                    viewController.updateUI()
                }
            }
        }
        service.defaultSDKPath(for: Settings.shared.SDKOption.rawValue) { (successfully, response) in
            if successfully {
                Settings.shared.SDKPath = response
                viewController.updateUI()
            }
        }
    }

    override func popoverViewController() -> SFSafariExtensionViewController {
        let viewController = SafariExtensionViewController.shared
        return viewController
    }

    private func sendLogMessage(_ level: LogLevel, _ message: String) {
        SFSafariApplication.getActiveWindow { (window) in
            guard let window = window else {
                return
            }

            window.getActiveTab { (activeTab) in
                guard let activeTab = activeTab else {
                    return
                }

                activeTab.getActivePage { (activePage) in
                    guard let activePage = activePage else {
                        return
                    }

                    activePage.dispatchMessageToScript(withName: "log", userInfo: ["value": "[\(level.rawValue.uppercased())] \(message)"])
                }
            }
        }
    }

    private func parseGitHubURL(_ url: URL) -> URL? {
        guard let scheme = url.scheme, scheme == "https" ,let host = url.host, host == "github.com", url.pathComponents.count >= 3 else {
            return nil
        }
        return URL(string: "\(scheme)://\(host)/\(url.pathComponents.dropFirst().prefix(2).joined(separator: "/")).git")
    }

    private enum LogLevel: String {
        case debug
        case info
        case warn
        case error
    }
}
