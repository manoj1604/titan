import Foundation

/// Finds a project (or one of its services) by the names people see in `titan ps`, so
/// `titan shell shop` works from any folder.
public enum ProjectLookup {
    public enum Target: Equatable, Sendable {
        case project(Project)
        /// A service VM of a project, e.g. `shop/postgres`.
        case service(Project, String)
    }

    /// Accepts a project name (`shop`), VM name (`titan-shop-65578934`), service (`shop/postgres`
    /// or its VM name `titan-shop-65578934-postgres`), or a folder path (`~/code/shop`, `.`).
    public static func find(_ query: String, in projects: [Project], cwd: String = FileManager.default.currentDirectoryPath,
                            home: String = FileManager.default.homeDirectoryForCurrentUser.path) throws -> Target {
        let q = query.trimmingCharacters(in: .whitespaces)

        // A path: "~/code/shop", "./shop", "/Users/…", ".".
        if q.hasPrefix("/") || q.hasPrefix(".") || q.hasPrefix("~") {
            let expanded = q.hasPrefix("~") ? home + q.dropFirst() : q
            let url = URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: cwd)).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw TitanError.message("No folder at \(url.path).")
            }
            return .project(Project.discover(from: url))
        }

        // VM names (unique by construction): the app VM, or a service VM.
        if let p = projects.first(where: { $0.containerName == q }) { return .project(p) }
        if let p = projects.first(where: { q.hasPrefix($0.containerName + "-") }) {
            return .service(p, String(q.dropFirst(p.containerName.count + 1)))
        }

        // "project/service".
        if let slash = q.firstIndex(of: "/") {
            let name = String(q[..<slash]), service = String(q[q.index(after: slash)...])
            guard !service.isEmpty else { throw TitanError.message("Add the service after the slash, e.g. \(name)/postgres.") }
            return .service(try byName(name, in: projects), service)
        }
        return .project(try byName(q, in: projects))
    }

    static func byName(_ name: String, in projects: [Project]) throws -> Project {
        let matches = projects.filter { $0.name.lowercased() == name.lowercased() }
        if matches.count == 1 { return matches[0] }
        if matches.isEmpty {
            let known = projects.map(\.name).sorted()
            throw TitanError.message("No project called '\(name)'."
                + (known.isEmpty ? " Titan knows a project once you've run `titan up` (or any command) in it."
                                 : " Known projects: \(known.joined(separator: ", ")) (see `titan ps`)."))
        }
        let list = matches.map { "  \($0.containerName)  \($0.root.path)" }.joined(separator: "\n")
        throw TitanError.message("More than one project is called '\(name)'. Use the VM name or the folder:\n\(list)")
    }
}
