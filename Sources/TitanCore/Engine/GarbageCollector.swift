import Foundation

/// One image in the local store; several references can point at the same digest.
public struct LocalImage: Equatable, Sendable {
    public var digest: String
    public var references: [String]
    /// Compressed (download) size of the arm64 variant.
    public var sizeBytes: UInt64

    public init(digest: String, references: [String], sizeBytes: UInt64) {
        self.digest = digest
        self.references = references
        self.sizeBytes = sizeBytes
    }

    /// The friendliest reference to show: a tag rather than a bare digest.
    public var displayName: String {
        references.first { !$0.contains("@") } ?? references.first ?? digest
    }
}

/// Decides which local images no Titan project or VM still needs.
public struct GarbageCollector {
    public struct Plan: Equatable, Sendable {
        /// Unused images Titan pulled or built: removed by default.
        public var titanImages: [LocalImage]
        /// Unused images Titan didn't create: removed only with `--all`.
        public var otherImages: [LocalImage]
        /// Images kept, with the reason.
        public var kept: [(image: LocalImage, reason: String)]

        public static func == (a: Plan, b: Plan) -> Bool {
            a.titanImages == b.titanImages && a.otherImages == b.otherImages
                && a.kept.map(\.image) == b.kept.map(\.image) && a.kept.map(\.reason) == b.kept.map(\.reason)
        }
    }

    let runtime: ContainerRuntime
    let paths: TitanPaths

    public init(runtime: ContainerRuntime, paths: TitanPaths = .standard) {
        self.runtime = runtime
        self.paths = paths
    }

    /// Images Titan's detector picks, so images pulled before the registry existed still count as Titan's.
    static let stackRepositories: Set<String> = [
        "docker.io/library/node", "docker.io/library/python", "docker.io/library/golang",
        "docker.io/library/rust", "docker.io/library/ruby", "docker.io/library/maven",
        "docker.io/library/gradle", "docker.io/library/debian",
    ]

    public func plan() throws -> Plan {
        guard runtime.isInstalled() else { throw TitanError.runtimeMissing }
        guard let images = runtime.listImages(), let inUse = runtime.imageDigestsInUse() else {
            throw TitanError.message("\(runtime.displayName) cannot list images and VMs.")
        }
        let registry = Registry.load(paths)
        let needed = neededReferences(registry)
        let titanRefs = Set(registry.allImages.map(Self.normalize))

        var plan = Plan(titanImages: [], otherImages: [], kept: [])
        for image in images.sorted(by: { $0.displayName < $1.displayName }) {
            let refs = image.references.map(Self.normalize)
            if inUse.contains(image.digest) {
                plan.kept.append((image, "used by a VM"))
            } else if let owner = needed.first(where: { $0.digests.contains(image.digest) || !$0.refs.isDisjoint(with: refs) }) {
                plan.kept.append((image, "needed by \(owner.project.name)"))
            } else if refs.contains(where: { titanRefs.contains($0) || $0.hasPrefix("titan-local/") || Self.stackRepositories.contains(Self.repository($0)) }) {
                plan.titanImages.append(image)
            } else {
                plan.otherImages.append(image)
            }
        }
        return plan
    }

    /// Deletes every reference of each image.
    public func remove(_ images: [LocalImage]) throws {
        let refs = images.flatMap(\.references)
        guard !refs.isEmpty else { return }
        try runtime.deleteImages(refs)
    }

    struct Need { var project: Project; var digests: Set<String>; var refs: Set<String> }

    /// What each registered project would use for its next `titan up`.
    func neededReferences(_ registry: Registry) -> [Need] {
        registry.liveProjects.map { project in
            var need = Need(project: project, digests: [], refs: [])
            if let lock = Lockfile.load(project) {
                if let d = lock.digest { need.digests.insert(d) }
                need.refs.insert(Self.normalize(lock.image))
            }
            if let image = ProjectState.load(project)?.image { need.refs.insert(Self.normalize(image)) }
            if case .pull(let ref)? = (try? EnvironmentResolver.resolve(project))?.image {
                need.refs.insert(Self.normalize(ref))
            }
            return need
        }
    }

    /// Canonical Docker reference: `python:3.12` → `docker.io/library/python:3.12`,
    /// `x@sha256:…` → `docker.io/library/x@sha256:…`, untagged → `:latest`.
    public static func normalize(_ reference: String) -> String {
        var ref = reference
        let firstComponent = ref.split(separator: "/").first.map(String.init) ?? ref
        let hasRegistry = ref.contains("/") && (firstComponent.contains(".") || firstComponent.contains(":") || firstComponent == "localhost")
        if !hasRegistry && !ref.hasPrefix("titan-local/") {
            ref = (ref.contains("/") ? "docker.io/" : "docker.io/library/") + ref
        }
        let name = ref.split(separator: "@").first.map(String.init) ?? ref
        let lastComponent = name.split(separator: "/").last.map(String.init) ?? name
        if !ref.contains("@") && !lastComponent.contains(":") { ref += ":latest" }
        // A tag plus digest pins the digest; the tag adds nothing for matching.
        if let at = ref.firstIndex(of: "@") {
            let repo = repository(String(ref[..<at]))
            ref = repo + ref[at...]
        }
        return ref
    }

    /// Reference without tag or digest.
    static func repository(_ normalized: String) -> String {
        let name = normalized.split(separator: "@").first.map(String.init) ?? normalized
        guard let slash = name.lastIndex(of: "/"), let colon = name.lastIndex(of: ":"), colon > slash else { return name }
        return String(name[..<colon])
    }
}
