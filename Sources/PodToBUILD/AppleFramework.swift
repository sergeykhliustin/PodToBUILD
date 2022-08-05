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
    public let deps: AttrSet<[String]>
    public let data: AttrSet<GlobNode>
    public let externalName: String
    public let objcDefines: AttrSet<[String]>
    public let swiftDefines: AttrSet<[String]>
    public let swiftVersion: AttrSet<String?>
    public let xcconfig: AttrSet<[String : String]>

    public let publicHeaders: AttrSet<GlobNode>
    
    public let sdkFrameworks: AttrSet<[String]>
    public let weakSdkFrameworks: AttrSet<[String]>
    public let sdkDylibs: AttrSet<[String]>

    public let isTopLevelTarget: Bool

    init(parentSpecs: [PodSpec], spec: PodSpec, extraDeps: [String] = [],
         isSplitDep: Bool = false,
         moduleMap: ModuleMap? = nil) {

        let podName = GetBuildOptions().podName
        let name = computeLibName(
            parentSpecs: parentSpecs,
            spec: spec,
            podName: podName,
            isSplitDep: false,
            sourceType: .swift
        )
        self.isTopLevelTarget = parentSpecs.isEmpty && isSplitDep == false
        self.name = name
        self.sourceFiles = Self.getSources(spec: spec)

        let externalName = getNamePrefix() + (parentSpecs.first?.name ?? spec.name)
        self.externalName = externalName

        let fallbackSpec = FallbackSpec(specs: [spec] +  parentSpecs)
        sdkFrameworks = fallbackSpec.attr(\.frameworks)
        weakSdkFrameworks = fallbackSpec.attr(\.weakFrameworks)
        sdkDylibs = fallbackSpec.attr(\.libraries)

        let moduleName: AttrSet<String> = spec.attr(\.moduleName).map {
            $0 ?? ""
        }
        self.moduleName = moduleName

        // Lift the deps to multiplatform, then get the names of these deps.
        let mpDeps = fallbackSpec.attr(\.dependencies)
        let mpPodSpecDeps = mpDeps.map { $0.map {
            getDependencyName(fromPodDepName: $0, podName:
                podName)
        } }

        let extraDepNames = extraDeps.map { bazelLabel(fromString: ":\($0)") }
        self.deps = AttrSet(basic: extraDepNames) <> mpPodSpecDeps

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

        let publicHeadersVal = fallbackSpec.attr(\.publicHeaders).unpackToMulti()
        let privateHeadersVal = fallbackSpec.attr(\.privateHeaders).unpackToMulti()

        let allSourceFiles = spec.attr(\PodSpecRepresentable.sourceFiles).unpackToMulti()

        let sourceHeaders = extractFiles(fromPattern: allSourceFiles, includingFileTypes:
                HeaderFileTypes)
        let privateHeaders = extractFiles(fromPattern: privateHeadersVal, includingFileTypes:
                HeaderFileTypes)
        let publicHeaders = extractFiles(fromPattern: publicHeadersVal, includingFileTypes:
                HeaderFileTypes)

        let basePublicHeaders = sourceHeaders.zip(publicHeaders).map {
            return Set($0.second ?? $0.first ?? [])
        }
        // lib/cocoapods/sandbox/file_accessor.rb
        self.publicHeaders = basePublicHeaders.zip(privateHeadersVal).map {
            GlobNode(include: .left($0.first ?? Set()), exclude: .left(Set($0.second ?? [])))
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
        // TODO: Make sources conditional
        let sourceFiles = self.sourceFiles.multi.ios?.toSkylark() ?? SkylarkNode.empty

        let swiftDefines = self.swiftDefines.toSkylark() .+. basicSwiftDefines
        let objcDefines = self.objcDefines.toSkylark() .+. basicObjcDefines

        // TODO: Make xcconfig conditional
        let xcconfig = (self.xcconfig.basic ?? [:])
            .merging((self.xcconfig.multi.ios ?? [:])) { (_, new) in new }

        let deps = deps.map {
            Set($0).sorted(by: (<))
        }

        // TODO: Make headers conditional
        let publicHeaders = self.publicHeaders.multi.ios ?? .empty

        let lines: [SkylarkFunctionArgument] = [
            .named(name: "name", value: name.toSkylark()),
            .named(name: "module_name", value: moduleName.toSkylark()),
            .named(name: "swift_version", value: swiftVersion.toSkylark()),
            .named(name: "srcs", value: sourceFiles),
            .named(name: "public_headers", value: publicHeaders.toSkylark()),
            .named(name: "deps", value: deps.toSkylark()),
            .named(name: "data", value: data.toSkylark()),
            .named(name: "swift_defines", value: swiftDefines),
            .named(name: "objc_defines", value: objcDefines),
            .named(name: "xcconfig", value: xcconfig.toSkylark()),
            .named(name: "sdk_frameworks", value: sdkFrameworks.toSkylark()),
            .named(name: "weak_sdk_frameworks", value: weakSdkFrameworks.toSkylark()),
            .named(name: "sdk_dylibs", value: sdkDylibs.toSkylark()),
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

    private static func getSources(spec: PodSpec) -> AttrSet<GlobNode> {
        let allSourceFiles = spec.attr(\.sourceFiles)
        let implFiles = extractFiles(fromPattern: allSourceFiles, includingFileTypes: AnyFileTypes)
            .unpackToMulti()
            .map { Set($0) }

        let allExcludes = spec.attr(\.excludeFiles)
        let implExcludes = extractFiles(fromPattern: allExcludes, includingFileTypes: AnyFileTypes)
            .unpackToMulti()
            .map { Set($0) }

        return implFiles.zip(implExcludes).map {
            GlobNode(include: .left($0.first ?? Set()), exclude: .left($0.second ?? Set()))
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
