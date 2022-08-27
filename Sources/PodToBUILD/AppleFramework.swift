//
//  AppleFramework.swift
//  PodToBUILD
//
//  Created by Sergey Khliustin on 04.08.2022.
//

public struct AppleFramework: BazelTarget {
    public let name: String
    public let sourceFiles: AttrSet<GlobNode>
    public let moduleName: AttrSet<String>
    public let platforms: [String: String]?
    public let deps: AttrSet<[String]>
    public let data: AttrSet<GlobNode>
    public let externalName: String
    public let objcDefines: AttrSet<[String]>
    public let swiftDefines: AttrSet<[String]>
    public let swiftVersion: AttrSet<String?>
    public let xcconfig: AttrSet<[String: Either<String, [String]>]>

    public let publicHeaders: AttrSet<GlobNode>
    public let privateHeaders: AttrSet<GlobNode>
    
    public let sdkFrameworks: AttrSet<Set<String>>
    public let weakSdkFrameworks: AttrSet<Set<String>>
    public let sdkDylibs: AttrSet<Set<String>>
    public let objcCopts: AttrSet<[String]>
    public let swiftCopts: AttrSet<[String]>

    public let isTopLevelTarget: Bool

    init(parentSpecs: [PodSpec], subspecs: [String], spec: PodSpec, extraDeps: [String] = []) {

        let podName = GetBuildOptions().podName
        let name = computeLibName(
            parentSpecs: parentSpecs,
            spec: spec,
            podName: podName,
            isSplitDep: false,
            sourceType: .swift
        )
        self.isTopLevelTarget = parentSpecs.isEmpty
        self.name = name
        self.platforms = spec.platforms

        let externalName = getNamePrefix() + (parentSpecs.first?.name ?? spec.name)
        self.externalName = externalName

        let fallbackSpec = FallbackSpec(specs: [spec] +  parentSpecs)

        let moduleName: AttrSet<String> = fallbackSpec.attr(\.moduleName).map {
            $0 ?? ""
        }
        self.moduleName = moduleName

        var localDeps = spec.selectedSubspecs(subspecs: subspecs)

        if !isTopLevelTarget {
            localDeps = getLocalSourceDependencies(allSpecs: parentSpecs, spec: spec, podName: podName)
        }

        sourceFiles = Self.getFilesNodes(from: spec, subspecs: localDeps, includesKeyPath: \.sourceFiles, excludesKeyPath: \.excludeFiles, fileTypes: AnyFileTypes)
        publicHeaders = Self.getFilesNodes(from: spec, subspecs: localDeps, includesKeyPath: \.publicHeaders, excludesKeyPath: \.privateHeaders, fileTypes: HeaderFileTypes)
        privateHeaders = Self.getFilesNodes(from: spec, subspecs: localDeps, includesKeyPath: \.privateHeaders, fileTypes: HeaderFileTypes)
        sdkDylibs = Self.collectAttribute(from: spec, subspecs: localDeps, keyPath: \.libraries)
        sdkFrameworks = Self.collectAttribute(from: spec, subspecs: localDeps, keyPath: \.frameworks)
        weakSdkFrameworks = Self.collectAttribute(from: spec, subspecs: localDeps, keyPath: \.weakFrameworks)
        let allPodSpecDeps = Self.collectAttribute(from: spec, subspecs: localDeps, keyPath: \.dependencies)
            .map({
                $0.map({
                    getDependencyName(fromPodDepName: $0, podName: podName)
                }).filter({ !$0.hasPrefix(":") })
            })

        let extraDepNames = extraDeps.map { bazelLabel(fromString: ":\($0)") }
        self.deps = AttrSet(basic: extraDepNames) <> allPodSpecDeps

        let swiftFlags = XCConfigTransformer.defaultTransformer(
            externalName: externalName, sourceType: .swift)
            .compilerFlags(for: fallbackSpec)

        let objcFlags = XCConfigTransformer.defaultTransformer(
            externalName: externalName, sourceType: .objc)
            .compilerFlags(for: fallbackSpec)

        self.swiftDefines = AttrSet(basic: ["COCOAPODS"])
        self.objcDefines = AttrSet(basic: ["COCOAPODS=1"])

        let resourceFiles = (spec.attr(\.resources).map { (strArr: [String]) -> [String] in
            strArr.filter { (str: String) -> Bool in
                !str.hasSuffix(".bundle")
            }
        }).map(extractResources)
        self.data = resourceFiles.map { GlobNode(include: Set($0)) }
        self.swiftVersion = Self.resolveSwiftVersion(spec: fallbackSpec)

        self.xcconfig = XCConfigTransformer.defaultTransformer(externalName: externalName, sourceType: .objc).xcconfig(for: fallbackSpec)

        // TODO: Temp solution
        self.objcCopts = xcconfig.map {
            if let paths = $0["HEADER_SEARCH_PATHS"] {
                return paths.fold(left: { ["-I" + $0] }, right: { $0.map({ "-I" + $0 }) })
            }
            return []
        }
        self.swiftCopts = xcconfig.map {
            if let paths = $0["HEADER_SEARCH_PATHS"] {
                return paths.fold(left: { ["-Xcc", "-I" + $0] }, right: {
                    $0.reduce(into: [String]()) { partialResult, value in
                        partialResult.append("-Xcc")
                        partialResult.append("-I" + value)
                    }
                })
            }
            return []
        }
    }

    public func toSkylark() -> SkylarkNode {
        let options = GetBuildOptions()

        let basicSwiftDefines: SkylarkNode =
            .functionCall(name: "select",
                          arguments: [
                            .basic([
                                "//conditions:default": [
                                    "DEBUG",
                                ],
                            ].toSkylark())
                          ]
            )
        let basicObjcDefines: SkylarkNode =
            .functionCall(name: "select",
                          arguments: [
                            .basic([
                                ":release": [
                                    "POD_CONFIGURATION_RELEASE=1",
                                 ],
                                "//conditions:default": [
                                    "POD_CONFIGURATION_DEBUG=1",
                                    "DEBUG=1",
                                ],
                            ].toSkylark())
                          ])
        let buildConfigDependenctCOpts: SkylarkNode =
            .functionCall(name: "select",
             arguments: [
                 .basic([
                     ":release": [
                         "-Xcc", "-DPOD_CONFIGURATION_RELEASE=1",
                      ],
                     "//conditions:default": [
                         "-enable-testing",
                         "-DDEBUG",
                         "-Xcc", "-DPOD_CONFIGURATION_DEBUG=1",
                         "-Xcc", "-DDEBUG=1",
                     ],
                 ].toSkylark()
                 ),
             ])

        let swiftDefines = self.swiftDefines.toSkylark() .+. basicSwiftDefines
        let objcDefines = self.objcDefines.toSkylark() .+. basicObjcDefines

        // TODO: Make xcconfig conditional
        let xcconfig = (self.xcconfig.basic ?? [:])
            .merging((self.xcconfig.multi.ios ?? [:])) { (_, new) in new }

        let deps = deps.map {
            Set($0).sorted(by: (<))
        }

        // TODO: Make headers conditional
        let publicHeaders = (self.publicHeaders.multi.ios ?? .empty)
        let privateHeaders = self.privateHeaders.multi.ios ?? .empty

        let allExcludeHeaders = (privateHeaders.include + publicHeaders.include).reduce(into: Set<String>()) { partialResult, value in
            if case let .left(strings) = value {
                partialResult.formUnion(strings)
            }
        }

        // TODO: Make sources conditional
        let sourceFiles = self.sourceFiles.multi.ios.map({
            GlobNode(include: $0.include, exclude: [.left(allExcludeHeaders)])
        }) ?? .empty

        let lines: [SkylarkFunctionArgument] = [
            .named(name: "name", value: name.toSkylark()),
            .named(name: "module_name", value: moduleName.toSkylark()),
            .named(name: "swift_version", value: swiftVersion.toSkylark()),
            .named(name: "platforms", value: platforms.toSkylark()),
            .named(name: "srcs", value: sourceFiles.toSkylark()),
            .named(name: "public_headers", value: publicHeaders.toSkylark()),
            .named(name: "private_headers", value: privateHeaders.toSkylark()),
            .named(name: "deps", value: deps.toSkylark()),
            .named(name: "data", value: data.toSkylark()),
            .named(name: "swift_defines", value: swiftDefines),
            .named(name: "objc_defines", value: objcDefines),
            .named(name: "xcconfig", value: xcconfig.toSkylark()),
            .named(name: "sdk_frameworks", value: sdkFrameworks.toSkylark()),
            .named(name: "weak_sdk_frameworks", value: weakSdkFrameworks.toSkylark()),
            .named(name: "sdk_dylibs", value: sdkDylibs.toSkylark()),
            .named(name: "objc_copts", value: objcCopts.toSkylark()),
            .named(name: "swift_copts", value: swiftCopts.toSkylark()),
            .named(name: "visibility", value: ["//visibility:public"].toSkylark())
        ]
            .filter({
                switch $0 {
                case .basic:
                    return true
                case .named(let name, let value):
                    return !value.isEmpty
                }
            })
        
        return .functionCall(
            name: "apple_framework",
            arguments: lines
        )
    }

    private static func getSourcesNodes(spec: PodSpec, deps: [PodSpec] = []) -> AttrSet<GlobNode> {
        let (implFiles, implExcludes) = Self.getSources(spec: spec, deps: deps)

        return implFiles.zip(implExcludes).map {
            GlobNode(include: .left($0.first ?? Set()), exclude: .left($0.second ?? Set()))
        }
    }

    private static func getSources(spec: PodSpec, deps: [PodSpec] = []) -> (includes:  AttrSet<Set<String>>, excludes:  AttrSet<Set<String>>) {
        let depsIncludes = AttrSet<Set<String>>(value: .empty)
        let depsExcludes = AttrSet<Set<String>>(value: .empty)

        let depsSources = deps.reduce((includes: depsIncludes, excludes: depsExcludes)) { partialResult, spec in
            let sources = Self.getSources(spec: spec)
            let includes = partialResult.includes <> sources.includes
            let excludes = partialResult.excludes <> sources.excludes
            return (includes, excludes)
        }

        let allSourceFiles = spec.attr(\.sourceFiles)
        let implFiles = extractFiles(fromPattern: allSourceFiles, includingFileTypes: AnyFileTypes)
            .unpackToMulti()
            .map { Set($0) }

        let allExcludes = spec.attr(\.excludeFiles)
        let implExcludes = extractFiles(fromPattern: allExcludes, includingFileTypes: AnyFileTypes)
            .unpackToMulti()
            .map { Set($0) }
        return (implFiles <> depsSources.includes, implExcludes <> depsSources.excludes)
    }

    private static func getFilesNodes(from spec: PodSpec,
                                 subspecs: [PodSpec] = [],
                                 includesKeyPath: KeyPath<PodSpecRepresentable, [String]>,
                                 excludesKeyPath: KeyPath<PodSpecRepresentable, [String]>? = nil,
                                 fileTypes: Set<String>) -> AttrSet<GlobNode> {
        let (implFiles, implExcludes) = Self.getFiles(from: spec,
                                                      subspecs: subspecs,
                                                      includesKeyPath: includesKeyPath,
                                                      excludesKeyPath: excludesKeyPath,
                                                      fileTypes: fileTypes)

        return implFiles.zip(implExcludes).map {
            GlobNode(include: .left($0.first ?? Set()), exclude: .left($0.second ?? Set()))
        }
    }

    private static func getFiles(from spec: PodSpec,
                                 subspecs: [PodSpec] = [],
                                 includesKeyPath: KeyPath<PodSpecRepresentable, [String]>,
                                 excludesKeyPath: KeyPath<PodSpecRepresentable, [String]>? = nil,
                                 fileTypes: Set<String>) -> (includes: AttrSet<Set<String>>, excludes: AttrSet<Set<String>>) {
        let depsIncludes = AttrSet<Set<String>>(value: .empty)
        let depsExcludes = AttrSet<Set<String>>(value: .empty)

        let depsSources = subspecs.reduce((includes: depsIncludes, excludes: depsExcludes)) { partialResult, spec in
            let sources = Self.getFiles(from: spec, includesKeyPath: includesKeyPath, excludesKeyPath: excludesKeyPath, fileTypes: fileTypes)
            let includes = partialResult.includes <> sources.includes
            let excludes = partialResult.excludes <> sources.excludes
            return (includes, excludes)
        }

        let allFiles = spec.attr(includesKeyPath)
        let implFiles = extractFiles(fromPattern: allFiles, includingFileTypes: fileTypes)
            .unpackToMulti()
            .map { Set($0) }

        var implExcludes: AttrSet<Set<String>> = AttrSet.empty

        if let excludesKeyPath = excludesKeyPath {
            let allExcludes = spec.attr(excludesKeyPath)
            implExcludes = extractFiles(fromPattern: allExcludes, includingFileTypes: fileTypes)
                .unpackToMulti()
                .map { Set($0) }
        }

        return (implFiles <> depsSources.includes, implExcludes <> depsSources.excludes)
    }

    static func collectAttribute(from spec: PodSpec,
                                         subspecs: [PodSpec] = [],
                                         keyPath: KeyPath<PodSpecRepresentable, [String]>) -> AttrSet<Set<String>> {
        return (subspecs + [spec])
            .reduce(into: AttrSet<Set<String>>.empty) { partialResult, spec in
                partialResult = partialResult <> spec.attr(keyPath).unpackToMulti().map({ Set($0) })
            }
    }

    private static func resolveSwiftVersion(spec: FallbackSpec) -> AttrSet<String?> {
        return spec.attr(\.swiftVersions).map {
            if let versions = $0?.compactMap({ Double($0) }) {
                if versions.contains(where: { $0 >= 5.0 }) {
                    return "5"
                } else if versions.contains(where: { $0 >= 4.2 }) {
                    return "4.2"
                } else if !versions.isEmpty {
                    return "4"
                }
            }
            return nil
        }
    }
}

private func extractResources(patterns: [String]) -> [String] {
    return patterns.flatMap { (p: String) -> [String] in
        pattern(fromPattern: p, includingFileTypes: [])
    }
}
