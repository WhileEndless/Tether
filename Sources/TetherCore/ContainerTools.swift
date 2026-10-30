import Foundation

/// Container tools running in a terminal (Docker, Docker Compose, Podman): shown on the tab with
/// their own symbol, moving while they work, and what they are doing (building an image, running
/// services, following logs, inside a container), as coding agents are.
public enum ToolKind: String, CaseIterable, Codable, Sendable {
    case docker, compose, podman

    public var title: String {
        switch self {
        case .docker: "Docker"
        case .compose: "Docker Compose"
        case .podman: "Podman"
        }
    }

    /// SF Symbol for tabs and sidebar rows.
    public var symbol: String {
        switch self {
        case .docker: "shippingbox.fill"
        case .compose: "square.stack.3d.up.fill"
        case .podman: "shippingbox"
        }
    }

    /// The symbol's colour (sRGB), close to each tool's own.
    public var tint: (red: Double, green: Double, blue: Double) {
        switch self {
        case .docker: (0.11, 0.47, 0.93)
        case .compose: (0.20, 0.58, 0.95)
        case .podman: (0.55, 0.36, 0.68)
        }
    }

    /// The tool a program (and, when known, its command line) is: `docker`, `docker compose …`,
    /// `docker-compose`, `podman`, `podman compose …`, `podman-compose`; nil for anything else.
    public init?(program: String, commandLine: String? = nil) {
        let name = (program as NSString).lastPathComponent.lowercased()
        switch name {
        case "docker", "docker.exe":
            self = Self.subcommand(commandLine).first == "compose" ? .compose : .docker
        case "docker-compose", "docker-compose.exe", "podman-compose":
            self = .compose
        case "podman", "podman.exe":
            self = Self.subcommand(commandLine).first == "compose" ? .compose : .podman
        default:
            return nil
        }
    }

    /// What the tool is doing, from its command line ("building an image", "running services"),
    /// or nil when it does not say anything more than its name.
    public static func doing(_ commandLine: String?) -> String? {
        var words = subcommand(commandLine)
        guard !words.isEmpty else { return nil }
        let compose = words.first == "compose" || ["docker-compose", "podman-compose"].contains(program(commandLine))
        if words.first == "compose" { words.removeFirst() }
        let follows = commandLine.map { line in line.split(separator: " ").contains { $0 == "-f" || $0 == "--follow" } } ?? false
        let detached = commandLine.map { line in line.split(separator: " ").contains { $0 == "-d" || $0 == "--detach" } } ?? false
        guard let verb = words.first else { return nil }
        let next = words.dropFirst().first
        if compose {
            switch verb {
            case "up": return detached ? "starting services" : "running services"
            case "build": return "building services"
            case "down": return "stopping and removing services"
            case "stop": return "stopping services"
            case "restart": return "restarting services"
            case "pull": return "pulling images"
            case "push": return "pushing images"
            case "logs": return follows ? "following the services' logs" : "showing the services' logs"
            case "exec", "run": return "inside a service's container"
            case "ps", "ls", "top": return "listing services"
            case "watch": return "watching for changes"
            default: return nil
            }
        }
        switch verb {
        case "build": return "building an image"
        case "buildx" where next == "build" || next == "bake": return "building an image"
        case "run": return detached ? "starting a container" : "running a container"
        case "exec", "attach": return "inside a container"
        case "logs": return follows ? "following a container's logs" : "showing a container's logs"
        case "pull": return "pulling an image"
        case "push": return "pushing an image"
        case "stats": return "watching containers' use"
        case "events": return "watching events"
        case "start", "restart": return "starting containers"
        case "stop", "kill": return "stopping containers"
        case "rm", "rmi", "prune": return "removing"
        case "system", "image", "container", "volume", "network", "builder": return next == "prune" ? "cleaning up" : nil
        case "cp": return "copying files"
        case "save", "load", "export", "import": return "moving an image"
        case "login": return "signing in to a registry"
        default: return nil
        }
    }

    /// Global options that take a value (skipped with it before the subcommand).
    private static let valued: Set<String> = ["--context", "-c", "--host", "-H", "--config", "--log-level", "-l",
                                              "--file", "-f", "--project-name", "-p", "--project-directory",
                                              "--env-file", "--profile", "--ansi", "--parallel", "--progress",
                                              "--remote", "--url", "--connection", "--root", "--runroot",
                                              "--storage-driver", "--cgroup-manager"]

    private static func program(_ commandLine: String?) -> String {
        guard let first = commandLine?.split(separator: " ").first else { return "" }
        return (String(first) as NSString).lastPathComponent.lowercased()
    }

    /// The words after the program and its global options: `["compose", "up"]`, `["build", "."]`.
    static func subcommand(_ commandLine: String?) -> [String] {
        guard let line = commandLine else { return [] }
        let words = line.split(whereSeparator: \.isWhitespace).map(String.init)
        var out: [String] = []
        var i = 1
        while i < words.count {
            let w = words[i]
            if out.isEmpty || out == ["compose"] {
                if w.hasPrefix("-") {
                    i += valued.contains(w) ? 2 : 1
                    continue
                }
            }
            out.append(w)
            if out.count >= 3 { break }
            i += 1
        }
        return out
    }
}
