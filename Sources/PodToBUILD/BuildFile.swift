//
//  Pod.swift
//  PodToBUILD
//
//  Created by Jerry Marino on 4/14/17.
//  Copyright © 2017 Pinterest Inc. All rights reserved.
//

import Foundation

private var sharedBuildOptions: BuildOptions = BasicBuildOptions.empty

public func GetBuildOptions() -> BuildOptions {
    return sharedBuildOptions
}

/// Config Setting Nodes
/// Write Build dependent COPTS.
/// @note We consume this as an expression in ObjCLibrary
public func makeConfigSettingNodes() -> SkylarkNode {
    let comment = [
        "# Add a config setting release for compilation mode",
        "# Assume that people are using `opt` for release mode",
        "# see the bazel user manual for more information",
        "# https://docs.bazel.build/versions/master/be/general.html#config_setting",
    ].map { SkylarkNode.skylark($0) }
    return .lines([.lines(comment),
        ConfigSetting(
            name: "release",
            values: ["compilation_mode": "opt"]).toSkylark(),
        ConfigSetting(
            name: "osxCase",
            values: ["apple_platform_type": "macos"]).toSkylark(),
        ConfigSetting(
            name: "tvosCase",
            values: ["apple_platform_type": "tvos"]).toSkylark(),
        ConfigSetting(
            name: "watchosCase",
            values: ["apple_platform_type": "watchos"]).toSkylark()
    ])
}

public func makeLoadNodes(forConvertibles skylarkConvertibles: [SkylarkConvertible]) -> SkylarkNode {
    let hasAppleBundleImport = skylarkConvertibles.first(where: { $0 is AppleBundleImport }) != nil
    let hasAppleResourceBundle = skylarkConvertibles.first(where: { $0 is AppleResourceBundle }) != nil
    let hasAppleFrameworkImport = skylarkConvertibles.first(where: { ($0 as? AppleFrameworkImport)?.isXCFramework == false }) != nil
    let hasAppleXCFrameworkImport = skylarkConvertibles.first(where: { ($0 as? AppleFrameworkImport)?.isXCFramework == true }) != nil
    let appleFrameworkImportString = appleFrameworkImport(isDynamicFramework: GetBuildOptions().isDynamicFramework, isXCFramework: false)
    let appleXCFrameworkImportString = appleFrameworkImport(isDynamicFramework: GetBuildOptions().isDynamicFramework, isXCFramework: true)
    
    return .lines( [
        SkylarkNode.skylark("load('@build_bazel_rules_ios//rules:framework.bzl', 'apple_framework')"),
        hasAppleBundleImport ?  SkylarkNode.skylark("load('@build_bazel_rules_apple//apple:resources.bzl', 'apple_bundle_import')") : nil,
        hasAppleResourceBundle ?  SkylarkNode.skylark("load('@build_bazel_rules_apple//apple:resources.bzl', 'apple_resource_bundle')") : nil,
        hasAppleFrameworkImport ? SkylarkNode.skylark("load('@build_bazel_rules_apple//apple:apple.bzl', '\(appleFrameworkImportString)')") : nil,
        hasAppleXCFrameworkImport ? SkylarkNode.skylark("load('@build_bazel_rules_apple//apple:apple.bzl', '\(appleXCFrameworkImportString)')") : nil,
        ].compactMap { $0 }
    )
}

// Make Nodes to be inserted at the beginning of skylark output
// public for test purposes
public func makePrefixNodes() -> SkylarkNode {
    let name = "rules_pods"
    let extFile = getRulePrefix(name: name) + "BazelExtensions:extensions.bzl"

    let lineNodes = [
        SkylarkNode.functionCall(name: "load", arguments: [
            .basic(.string(extFile)),
            .basic(.string("acknowledged_target")),
            .basic(.string("gen_module_map")),
            .basic(.string("gen_includes")),
            .basic(.string("headermap")),
            .basic(.string("umbrella_header"))]),
        makeConfigSettingNodes()
    ]
    return .lines(lineNodes)
}

/// Acknowledgment node exposes an acknowledgment fragment including all of
/// the `deps` acknowledgment fragments.
public struct AcknowledgmentNode: BazelTarget {
    public let name: String
    let license: PodSpecLicense
    let deps: [String]

    public func toSkylark() -> SkylarkNode {
        let nodeName = bazelLabel(fromString: name).toSkylark()
        let options = GetBuildOptions()
        let podSupportBuildableDir = String(PodSupportBuidableDir.utf8.dropLast())!
        let value = (getRulePrefix(name: options.podName) +
                        podSupportBuildableDir + ":acknowledgement_fragment")
        let target = SkylarkNode.functionCall(
            name: "acknowledged_target",
            arguments: [
                .named(name: "name", value: nodeName),
                // Consider moving this to an aspect and adding it to the
                // existing dep graph.
                .named(name: "deps", value: deps.map { $0 + "_acknowledgement" }.toSkylark()),
                .named(name: "value", value: value.toSkylark())
            ]
        )
        return target
    }
}
public struct PodBuildFile: SkylarkConvertible {
    /// Skylark Convertibles excluding prefix nodes.
    /// @note Use toSkylark() to generate the actual BUILD file
    public let skylarkConvertibles: [SkylarkConvertible]

    /// When there is a podspec adjacent to another, we need to concat
    /// the "child" BUILD file into the parents
    public let assimilate: Bool

    private let options: BuildOptions

    public static func shouldAssimilate(buildOptions: BuildOptions) -> Bool {
        return buildOptions.path != "." &&
            FileManager.default.fileExists(atPath: BazelConstants.buildFilePath)
    }

    /// Return the skylark representation of the entire BUILD file
    public func toSkylark() -> SkylarkNode {
        let prevOptions = sharedBuildOptions
        // This is very brittle but the options are implicit passed into
        // toSkylark() and constructors instead of passing them to every
        // function. For child build files we need to update them.
        sharedBuildOptions = options
        BuildFileContext.set(BuildFileContext(convertibles: skylarkConvertibles))
        let convertibleNodes: [SkylarkNode] = skylarkConvertibles.compactMap { $0.toSkylark() }
        BuildFileContext.set(nil)

        let prefixNodes: [SkylarkNode]
        // If we have to assimilate this into another build file then don't
        // write prefix nodes. This is not 100% pefect, as some other algorithms
        // require all contents of the build file. This is an intrim solution.
        let allHeaders = skylarkConvertibles.reduce(into: [String]()) {
            accum, next in
            if let objcLib = next as? ObjcLibrary {
                accum.append(objcLib.name + "_direct_hdrs")
            }
        }

        let pkgHeaders = SkylarkNode.functionCall(
            name: "filegroup",
            arguments: [
                .named(name: "name", value: (getNamePrefix() +
                                             options.podName + "_package_hdrs").toSkylark()),
                .named(name: "srcs", value: allHeaders.toSkylark()),
                .named(name: "visibility", value: ["//visibility:public"].toSkylark()),
                ]
            )
    
        sharedBuildOptions = prevOptions
        let top: [SkylarkNode] = assimilate ? [] : [makePrefixNodes()]
        prefixNodes = top + [pkgHeaders]
        return .lines([ makeLoadNodes(forConvertibles: skylarkConvertibles) ] +
            prefixNodes
            + convertibleNodes)
    }

    public static func with(podSpec: PodSpec, buildOptions: BuildOptions =
                            BasicBuildOptions.empty, assimilate: Bool = false) -> PodBuildFile {
        sharedBuildOptions = buildOptions
        let libs = PodBuildFile.makeConvertables(fromPodspec: podSpec, buildOptions: buildOptions)
        return PodBuildFile(skylarkConvertibles: libs, assimilate: assimilate,
                            options: buildOptions)
    }

    private static func bundleLibraries(withPodSpec spec: PodSpec) -> [BazelTarget] {
        // See if the Podspec specifies a prebuilt .bundle file
        let bundleResources = (spec.attr(\.resources)).map { (strArr: [String]) -> [BazelTarget] in
            strArr.filter({ (str: String) -> Bool in
                str.hasSuffix(".bundle")
            }).map { (bundlePath: String) -> BazelTarget in
                let bundleName = AppleBundleImport.extractBundleName(fromPath: bundlePath)
                let name = "\(spec.moduleName ?? spec.name)_Bundle_\(bundleName)"
                let bundleImports = AttrSet<[String]>(basic: ["\(bundlePath)/**"])
                return AppleBundleImport(name: name, bundleImports: bundleImports)
            }
        }

        // Converts an attrset to resource bundles
        let resourceBundles = spec.attr(\.resourceBundles).map {
            return $0.map {
            (x: (String, [String])) -> BazelTarget  in
            let k = x.0
            let resources = x.1
            let name = "\(spec.moduleName ?? spec.name)_Bundle_\(k)"
            return AppleResourceBundle(name: name, resources: AttrSet<[String]>(basic: resources))
        }
        }

        return ((resourceBundles.basic ?? []) + (resourceBundles.multi.ios ??
        []) + (bundleResources.basic ?? []) + (bundleResources.multi.ios ?? [])).sorted { $0.name < $1.name }
    }

    private static func vendoredFrameworks(withPodspec spec: PodSpec, deps: [PodSpec] = []) -> [BazelTarget] {
        // TODO: Make frameworks AttrSet
        let vendoredFrameworks = AppleFramework.collectAttribute(from: spec, subspecs: deps, keyPath: \.vendoredFrameworks)
        let frameworks = vendoredFrameworks.map {
            $0.map {
                let frameworkName = URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
                return AppleFrameworkImport(name: "\(spec.moduleName ?? spec.name)_\(frameworkName)_VendoredFrameworks",
                                            frameworkImport: AttrSet(basic: $0))
            } as [AppleFrameworkImport]
        }
        return (frameworks.basic ?? []) + (frameworks.multi.ios ?? [])
    }

    private static func vendoredLibraries(withPodspec spec: PodSpec) -> [BazelTarget] {
        let libraries = spec.attr(\.vendoredLibraries)
        return libraries.isEmpty ? [] : [ObjcImport(name: "\(spec.moduleName ?? spec.name)_VendoredLibraries", archives: libraries)]
    }

    static func makeSourceLibsV2(parentSpecs: [PodSpec], spec: PodSpec, subspecs: [String],
            extraDeps: [BazelTarget], isRootSpec: Bool = false) -> [BazelTarget] {
        var sourceLibs: [BazelTarget] = []

        let rootSpec = parentSpecs.first ?? spec

        let fallbackSpec = FallbackSpec(specs: [spec] +  parentSpecs)

        let externalName = getNamePrefix() + (parentSpecs.first?.name ?? spec.name)
        let moduleName: AttrSet<String> = fallbackSpec.attr(\.moduleName).map {
            $0 ?? ""
        }
        let headerDirectoryName: AttrSet<String?> = fallbackSpec.attr(\.headerDirectory)
        let headerName = (moduleName.isEmpty ? nil : moduleName) ??
            (headerDirectoryName.basic == nil ? nil :
                headerDirectoryName.denormalize()) ?? AttrSet<String>(value:
                externalName)
        let clangModuleName = headerName.basic?.replacingOccurrences(of: "-", with: "_") ?? ""
        let isTopLevelTarget = parentSpecs.isEmpty
        let options = GetBuildOptions()

        let podName = GetBuildOptions().podName
        let rootName = computeLibName(parentSpecs: [], spec: rootSpec, podName:
            podName, isSplitDep: false, sourceType: .objc)

        sourceLibs.append(AppleFramework(parentSpecs: parentSpecs,
                                         subspecs: subspecs,
                                         spec: spec,
                                         extraDeps: extraDeps.map { $0.name }))


        return sourceLibs
    }

    private static func makeSubspecTargets(parentSpecs: [PodSpec], spec: PodSpec) -> [BazelTarget] {
        let bundles: [BazelTarget] = bundleLibraries(withPodSpec: spec)
        var podSpecDeps: [PodSpec] = spec.dependencies.compactMap({
            let splitted = $0.split(separator: "/")
            guard splitted.count == 2 else { return nil }
            let podName = splitted[0]
            let depName = splitted[1]
            return parentSpecs.first(where: { $0.name == podName })?.subspecs.first(where: { $0.name == depName })
        })

        let libraries = vendoredLibraries(withPodspec: spec)
        let frameworks = vendoredFrameworks(withPodspec: spec, deps: podSpecDeps)

        let extraDeps: [BazelTarget] = (
                (libraries as [BazelTarget]) +
                        (frameworks as [BazelTarget]))
        let sourceLibs = makeSourceLibsV2(parentSpecs: parentSpecs, spec: spec, subspecs: [],
                extraDeps: extraDeps)

        let subspecTargets = spec.subspecs.flatMap {
            makeSubspecTargets(parentSpecs: parentSpecs + [spec], spec: $0)
        }

        return bundles + sourceLibs + libraries + frameworks + subspecTargets
    }

    public static func makeConvertables(
            fromPodspec podSpec: PodSpec,
            buildOptions: BuildOptions = BasicBuildOptions.empty
    ) -> [SkylarkConvertible] {
        let subspecs = podSpec.selectedSubspecs(subspecs: buildOptions.subspecs)

        let extraDeps = vendoredFrameworks(withPodspec: podSpec, deps: subspecs) +
            vendoredLibraries(withPodspec: podSpec)

        let allRootDeps = extraDeps
            .filter { !($0 is AppleResourceBundle || $0 is AppleBundleImport) }

        let sourceLibs = makeSourceLibsV2(parentSpecs: [], spec: podSpec, subspecs: buildOptions.subspecs, extraDeps:
                allRootDeps)

        var output: [BazelTarget] = sourceLibs +
            bundleLibraries(withPodSpec: podSpec) + extraDeps

        output = UserConfigurableTransform.transform(convertibles: output,
                                                     options: buildOptions,
                                                     podSpec: podSpec)
        output = RedundantCompiledSourceTransform.transform(convertibles: output,
                                                            options: buildOptions,
                                                            podSpec: podSpec)
        return output
    }

//    public static func subspecDependencies(podName: String, podSpec: PodSpec, allSpecs: [PodSpec]) -> [PodSpec] {
//        var subspecs = podSpec.selectedSubspecs()
//        if !podSpec.dependencies.isEmpty {
//            subspecs = podSpec.dependencies.compactMap({
//                let splitted = $0.split(separator: "/")
//                guard splitted.count == 2 else { return nil }
//                let name = splitted[0]
//                let depName = splitted[1]
//                if name == podName {
//                    return allSpecs.first(where: { $0.name == depName })
//                }
//                return nil
//            })
//        }
//        let deps = subspecs.reduce(into: [PodSpec]()) { partialResult, spec in
//            partialResult += Self.subspecDependencies(podName: podName, podSpec: spec, allSpecs: allSpecs)
//        }
//        return subspecs + deps
//    }
}
