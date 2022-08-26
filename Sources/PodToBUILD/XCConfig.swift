//
//  XCConfig.swift
//  PodToBUILD
//
//  Created by Jerry Marino on 4/27/17.
//  Copyright © 2017 Pinterest Inc. All rights reserved.
//
// Notes:
// Clang uses the right most value for a given flag
// EX:
// clang  S/main.m -Wmacro-redefined
// -Wno-macro-redefined -framework Foundation -DDEBUGG=0 -DDEBUGG=1 -o e
//
// Here the compiler will not emit the warning, since we passed -Wno
// after the -W option was passed

import Foundation

public protocol XCConfigValueTransformer {
    func xcconfigValue(forXCConfigValue value: String) -> String?
    func string(forXCConfigValue value: String) -> String?
    var xcconfigKey: String { get }
}

enum XCConfigValueTransformerError: Error {
    case unimplemented
}

public struct XCConfigTransformer {
    private let registry: [String: XCConfigValueTransformer]

    init(transformers: [XCConfigValueTransformer]) {
        var registry = [String: XCConfigValueTransformer]()
        transformers.forEach { registry[$0.xcconfigKey] = $0 }
        self.registry = registry
    }

    func stringAsList(value: String) -> [String] {
        return value
            .components(separatedBy: "=\"")
            .map {
                let components = $0.components(separatedBy: "\"")
                guard components.count == 2 else {
                    return $0
                }
                let modifiedValue = [
                    components.first?.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "",
                    components.dropFirst().joined()
                ].joined(separator: "\\\"")
                return modifiedValue
            }
            .joined(separator: "=\\\"")
            .components(separatedBy: .whitespaces)
            .map { $0.removingPercentEncoding ?? "" }
    }

    func xcconfig(forXCConfigKey key: String, XCConfigValue value: String) throws -> String {
        guard let transformer = registry[key] else {
            throw XCConfigValueTransformerError.unimplemented
        }
        let allValues = value
            .components(separatedBy: "=\"")
            .map {
                let components = $0.components(separatedBy: "\"")
                guard components.count == 2 else {
                    return $0
                }
                let modifiedValue = [
                    components.first?.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "",
                    components.dropFirst().joined()
                ].joined(separator: "\\\"")
                return modifiedValue
            }
            .joined(separator: "=\\\"")
            .components(separatedBy: .whitespaces)
            .map { $0.removingPercentEncoding ?? "" }
        return allValues
            .filter { $0 != "$(inherited)" }
            .compactMap { val in
                let podDir = getPodBaseDir()
                let targetDir = getGenfileOutputBaseDir()
                return transformer.xcconfigValue(forXCConfigValue: val)?
                    .replacingOccurrences(of: "$(PODS_ROOT)", with: podDir)
                    .replacingOccurrences(of: "${PODS_ROOT}", with: podDir)
                    .replacingOccurrences(of: "$(PODS_TARGET_SRCROOT)", with: targetDir)
                    .replacingOccurrences(of: "${PODS_TARGET_SRCROOT}", with: targetDir)
//                    .replacingOccurrences(of: "\\\"", with: "[ESCAPED_QUOTE]")
//                    .replacingOccurrences(of: "\"", with: "\\\"")
//                    .replacingOccurrences(of: "[ESCAPED_QUOTE]", with: "\\\"")
            }
            .joined(separator: " ")
    }

    func compilerFlag(forXCConfigKey key: String, XCConfigValue value: String) throws -> [String] {
        // Case insensitve?
        guard let transformer = registry[key] else {
            throw XCConfigValueTransformerError.unimplemented
        }
        // Instead of splitting by whitespaces we also want to handle cases like "SOMEKEY=\"SOME VALUE\""
        let allValues = value
            .components(separatedBy: "=\"")
            .map {
                let components = $0.components(separatedBy: "\"")
                guard components.count == 2 else {
                    return $0
                }
                let modifiedValue = [
                    components.first?.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "",
                    components.dropFirst().joined()
                ].joined(separator: "\\\"")
                return modifiedValue
            }
            .joined(separator: "=\\\"")
            .components(separatedBy: .whitespaces)
            .map { $0.removingPercentEncoding ?? "" }

        return allValues.filter { $0 != "$(inherited)" }
            .compactMap { val in
                let podDir = getPodBaseDir()
                let targetDir = getGenfileOutputBaseDir()
                return transformer.string(forXCConfigValue: val)?
                    .replacingOccurrences(of: "$(PODS_ROOT)", with: podDir)
                    .replacingOccurrences(of: "${PODS_ROOT}", with: podDir)
                    .replacingOccurrences(of: "$(PODS_TARGET_SRCROOT)", with: targetDir)
                    .replacingOccurrences(of: "${PODS_TARGET_SRCROOT}", with: targetDir)
            }
    }

    public static func defaultTransformer(externalName: String, sourceType: BazelSourceLibType) -> XCConfigTransformer {
        if sourceType == .swift {
            return XCConfigTransformer(transformers: [
                SwiftApplicationExtensionAPIOnlyTransformer()
            ])
        }
        return XCConfigTransformer(transformers: [
            PassthroughTransformer(xcconfigKey: "OTHER_CFLAGS"),
            PassthroughTransformer(xcconfigKey: "OTHER_LDFLAGS"),
            PassthroughTransformer(xcconfigKey: "OTHER_CPLUSPLUSFLAGS"),
            HeaderSearchPathTransformer(externalName: externalName),
            CXXLibraryTransformer(enabled: sourceType == .cpp),
            CXXLanguageStandardTransformer(enabled: sourceType == .cpp),
            PreprocessorDefinesTransformer(),
            AllowNonModularIncludesInFrameworkModulesTransformer(),
            ApplicationExtensionAPIOnlyTransformer(),
            PreCompilePrefixHeaderTransformer(),
        ])
    }

    public func compilerFlags(forXCConfig xcconfig: AttrSet<[String: String]>) -> AttrSet<[String]> {
        return xcconfig.map({ config in
            return config.keys
                .sorted(by: <)
                .compactMap {
                    key -> [String]? in
                    guard let value = config[key] else {
                        return nil
                    }
                    return try? compilerFlag(forXCConfigKey: key, XCConfigValue: value)
                }
                .flatMap { $0 }
        })
    }

    public func xcconfig(forXCConfig xcconfig: AttrSet<[String: String]>) -> AttrSet<[String: Either<String, [String]>]> {
        let shouldBeArray = [
            "GCC_PREPROCESSOR_DEFINITIONS",
            "OTHER_SWIFT_FLAGS",
            "OTHER_CFLAGS",
            "SWIFT_INCLUDE_PATHS"
        ]
        return xcconfig.map({
            $0.reduce([String: Either<String, [String]>]()) { result, element in
                var result = result

                if let newValue = try? self.xcconfig(forXCConfigKey: element.key, XCConfigValue: element.value),
                   newValue.isEmpty == false {
                    if shouldBeArray.contains(element.key) {
                        result[element.key] = .right(stringAsList(value: newValue))
                    } else {
                        result[element.key] = .left(newValue)
                    }
                }
                return result
            }
        })
    }
}

//  MARK: - Value Transformers

// public struct for creating transformers instances that simply return their values
public struct PassthroughTransformer: XCConfigValueTransformer {
    private let key: String

    public var xcconfigKey: String {
        return self.key
    }

    init(xcconfigKey: String) {
        self.key = xcconfigKey
    }

    public func string(forXCConfigValue value: String) -> String? {
        return value
    }

    public func xcconfigValue(forXCConfigValue value: String) -> String? {
        return value
    }
}

public struct PreCompilePrefixHeaderTransformer: XCConfigValueTransformer {
    public var xcconfigKey: String {
        return "GCC_PRECOMPILE_PREFIX_HEADER"
    }

    public func string(forXCConfigValue _: String) -> String? {
        // TODO: Implement precompiled header support in Bazel.
        return ""
    }

    public func xcconfigValue(forXCConfigValue value: String) -> String? {
        return value
    }
}

public struct HeaderSearchPathTransformer: XCConfigValueTransformer {
    public static let xcconfigKey = "HEADER_SEARCH_PATHS"
    public var xcconfigKey: String = HeaderSearchPathTransformer.xcconfigKey
    
    let externalName: String
    init(externalName: String) {
        self.externalName = externalName;
    }
    
    public func string(forXCConfigValue value: String) -> String? {
        let cleaned = value.replacingOccurrences(of: "$(PODS_TARGET_SRCROOT)",
            with: "\(getPodBaseDir())/\(externalName)").replacingOccurrences(of: "\"", with: "")
        return "-I\(cleaned)"
    }

    public func xcconfigValue(forXCConfigValue value: String) -> String? {
        return value
            .replacingOccurrences(of: "$(PODS_TARGET_SRCROOT)",
                                  with: "\(getPodBaseDir())/\(externalName)")
            .replacingOccurrences(of: "\"", with: "")
    }
}

public struct PreprocessorDefinesTransformer: XCConfigValueTransformer {
    public var xcconfigKey: String {
        return "GCC_PREPROCESSOR_DEFINITIONS"
    }

    public func string(forXCConfigValue value: String) -> String? {
        return "-D\(value)"
    }

    public func xcconfigValue(forXCConfigValue value: String) -> String? {
        return value
    }
}

public struct AllowNonModularIncludesInFrameworkModulesTransformer: XCConfigValueTransformer {
    public var xcconfigKey: String {
        return "CLANG_ALLOW_NON_MODULAR_INCLUDES_IN_FRAMEWORK_MODULES"
    }

    public func string(forXCConfigValue _: String) -> String? {
        return "-Wno-non-modular-include-in-framework-module -Wno-error=noon-modular-include-in-framework-module"
    }

    public func xcconfigValue(forXCConfigValue value: String) -> String? {
        return value
    }
}

public struct SwiftApplicationExtensionAPIOnlyTransformer: XCConfigValueTransformer {
    public var xcconfigKey: String {
        return "APPLICATION_EXTENSION_API_ONLY" 
    }

    public func string(forXCConfigValue value: String) -> String? {
        return value == "YES" || value == "yes" ? "-application-extension" : nil
    }

    public func xcconfigValue(forXCConfigValue value: String) -> String? {
        return value
    }
}

public struct ApplicationExtensionAPIOnlyTransformer: XCConfigValueTransformer {
    public var xcconfigKey: String {
        return "APPLICATION_EXTENSION_API_ONLY" 
    }

    public func string(forXCConfigValue value: String) -> String? {
        return value == "YES" || value == "yes" ? "-fapplication-extension" : nil
    }

    public func xcconfigValue(forXCConfigValue value: String) -> String? {
        return value
    }
}

/// MARK - CXX specific settings
/// Don't enable CXX specific settings for C/ObjC libs.
/// It is possible that a user may create such a Podspec.
public struct CXXLanguageStandardTransformer: XCConfigValueTransformer {
    let enabled: Bool

    init(enabled: Bool) {
        self.enabled = enabled
    }

    public var xcconfigKey: String {
        return "CLANG_CXX_LANGUAGE_STANDARD"
    }

    public func string(forXCConfigValue value: String) -> String? {
        guard enabled else {
            return nil
        }
        return "-std=\(value)"
    }

    public func xcconfigValue(forXCConfigValue value: String) -> String? {
        return value
    }
}

public struct CXXLibraryTransformer: XCConfigValueTransformer {
    let enabled: Bool

    init(enabled: Bool) {
        self.enabled = enabled
    }

    public var xcconfigKey: String {
        return "CLANG_CXX_LIBRARY"
    }

    public func string(forXCConfigValue value: String) -> String? {
        guard enabled else {
            return nil
        }
        return "-stdlib=\(value)"
    }

    public func xcconfigValue(forXCConfigValue value: String) -> String? {
        return value
    }
}

public extension XCConfigTransformer {
    func compilerFlags(for spec: FallbackSpec) -> AttrSet<[String]> {
        let xcconfig = spec.attr(\.podTargetXcconfig).map({ $0 ?? [:]})
        <> spec.attr(\.userTargetXcconfig).map({ $0 ?? [:] })
        <> spec.attr(\.xcconfig).map({ $0 ?? [:] })
        return self.compilerFlags(forXCConfig: xcconfig)
    }

    func xcconfig(for spec: FallbackSpec) -> AttrSet<[String: Either<String, [String]>]> {
        let xcconfig = spec.attr(\.podTargetXcconfig).map({ $0 ?? [:]})
        <> spec.attr(\.userTargetXcconfig).map({ $0 ?? [:] })
        <> spec.attr(\.xcconfig).map({ $0 ?? [:] })
        return self.xcconfig(forXCConfig: xcconfig)
    }
}

