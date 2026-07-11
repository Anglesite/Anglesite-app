import Foundation
import Adwaita
import AnglesiteCore

/// The Linux shell (cross-platform port phase 2, #567): a GTK4/libadwaita window that opens a
/// `.anglesite` package, boots its site in a rootless-podman container
/// (`LocalContainerSiteRuntime` over `PodmanContainerControl`, #647), and live-previews the
/// containerized Astro dev server in an embedded WebKitGTK webview with the edit overlay
/// injected. Deliberately thin (port design §6 risk containment): everything below the window
/// chrome is `AnglesiteCore`/`AnglesiteBridgeCore` — the same portable stack the macOS shell
/// composes.
///
/// Usage: `anglesite-linux [path/to/Site.anglesite]`, or open a package from the header-bar
/// button. Requires podman and a loaded `localhost/anglesite-dev:latest` image.
@main
struct AnglesiteLinuxApp: App {
    /// What the window shows. `.ready`'s payload feeds `PreviewWebView` directly.
    enum PreviewStatus: Equatable {
        case noSite
        case starting(name: String)
        case ready(name: String, url: String)
        case failed(name: String, message: String)
    }

    var app = AdwaitaApp(id: "io.dwk.anglesite.linux")

    let model = ShellModel()
    let overlaySource = ShellModel.overlaySource()
    @State private var status: PreviewStatus = .noSite
    @State private var router: MCPApplyEditRouter?
    @State private var openDialog: Signal = .init()
    @State private var quitting = false

    var scene: Scene {
        Window(id: "main") { _ in
            content
                .topToolbar {
                    HeaderBar.end {
                        Button("Open Site…") { openDialog.signal() }
                    }
                    .headerBarTitle {
                        Text(windowTitle)
                    }
                }
                .folderImporter(open: openDialog) { url in
                    open(packageURL: url)
                }
                .onAppear {
                    // Logs are sacred: until the shell grows a debug pane, every supervised
                    // subprocess line (container boot, git clone, astro dev, the MCP sidecar)
                    // streams to the launching terminal's stderr.
                    Task.detached {
                        let subscription = await LogCenter.shared.subscribe()
                        for await line in subscription.stream {
                            FileHandle.standardError.write(Data("[\(line.source)] \(line.text)\n".utf8))
                        }
                    }
                    // `anglesite-linux Foo.anglesite` — open straight into the site.
                    if let path = CommandLine.arguments.dropFirst().first {
                        open(packageURL: URL(fileURLWithPath: path))
                    }
                }
        }
        .defaultSize(width: 1200, height: 800)
        .onClose {
            // Never leak the site container: intercept the first close, stop the runtime
            // (podman stop tears down the whole `--rm` guest), then quit for real. GTK's main
            // loop keeps running during the async stop, so the window just stays up for the
            // second or two the teardown takes.
            if quitting { return .close }
            quitting = true
            Task {
                await model.stopCurrent()
                Idle { app.quit() }
            }
            return .cancel
        }
    }

    var windowTitle: String {
        switch status {
        case .noSite: return "Anglesite"
        case .starting(let name), .ready(let name, _), .failed(let name, _): return name
        }
    }

    @ViewBuilder var content: Body {
        switch status {
        case .noSite:
            StatusPage()
                .title("No Site Open")
                .description("Open a .anglesite package to start its preview.")
                .iconName("folder-open-symbolic")
        case .starting(let name):
            StatusPage()
                .title("Starting \(name)…")
                .description("Booting the site container and dev server. First boot clones the site and installs dependencies.")
                .child { Spinner() }
        case .ready(_, let url):
            PreviewWebView(
                url: url,
                router: router ?? MCPApplyEditRouter(mcpClient: { nil }),
                overlaySource: overlaySource
            )
            .vexpand()
            .hexpand()
        case .failed(_, let message):
            StatusPage()
                .title("Preview Failed")
                .description(message)
                .iconName("dialog-error-symbolic")
        }
    }

    /// Opens the package and forwards every runtime state transition onto the GTK main loop.
    /// Errors surface as `.failed` on the status page rather than crashing the shell — the
    /// Debug-pane equivalent (LogCenter) has the full container output.
    func open(packageURL: URL) {
        let site: ShellModel.OpenedSite
        do {
            site = try model.open(packageURL: packageURL)
        } catch {
            status = .failed(
                name: packageURL.deletingPathExtension().lastPathComponent,
                message: "Not an openable .anglesite package: \(error)"
            )
            return
        }
        router = site.router
        status = .starting(name: site.displayName)

        let name = site.displayName
        let runtime = site.runtime
        Task {
            for await state in await runtime.observe() {
                Idle {
                    switch state {
                    case .idle:
                        break
                    case .starting:
                        status = .starting(name: name)
                    case .ready(_, let url):
                        status = .ready(name: name, url: url.absoluteString)
                    case .failed(_, let message):
                        status = .failed(name: name, message: message)
                    }
                }
            }
        }
    }
}
