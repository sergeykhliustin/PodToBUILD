load(
    "@bazel_tools//tools/build_defs/repo:git.bzl",
    "git_repository",
    "new_git_repository",
)

NAMESPACE_PREFIX = "podtobuild-"

def namespaced_name(name):
    if name.startswith("@"):
        return name.replace("@", "@%s" % NAMESPACE_PREFIX)
    return NAMESPACE_PREFIX + name

def namespaced_dep_name(name):
    if name.startswith("@"):
        return name.replace("@", "@%s" % NAMESPACE_PREFIX)
    return name

def namespaced_new_git_repository(name, **kwargs):
    new_git_repository(
        name = namespaced_name(name),
        **kwargs
    )

def namespaced_git_repository(name, **kwargs):
    git_repository(
        name = namespaced_name(name),
        **kwargs
    )

def namespaced_build_file(libs):
    return """
package(default_visibility = ["//visibility:public"])
load("@build_bazel_rules_swift//swift:swift.bzl", "swift_c_module",
"swift_library")
""" + "\n\n".join(libs)

def namespaced_swift_c_library(name, srcs, hdrs, includes, module_map):
    return """
objc_library(
  name = "{name}Lib",
  srcs = glob([
    {srcs}
  ]),
  hdrs = glob([
    {hdrs}
  ]),
  includes = [
    {includes}
  ]
)

swift_c_module(
  name = "{name}",
  deps = [":{name}Lib"],
  module_name = "{name}",
  module_map = "{module_map}",
)
""".format(**dict(
        name = name,
        srcs = ",\n".join(['"%s"' % x for x in srcs]),
        hdrs = ",\n".join(['"%s"' % x for x in hdrs]),
        includes = ",\n".join(['"%s"' % x for x in includes]),
        module_map = module_map,
    ))

def namespaced_swift_library(name, srcs, deps = None, defines = None, copts=[]):
    deps = [] if deps == None else deps
    defines = [] if defines == None else defines
    return """
swift_library(
    name = "{name}",
    srcs = glob([{srcs}]),
    module_name = "{name}",
    deps = [{deps}],
    defines = [{defines}],
    copts = ["-DSWIFT_PACKAGE", {copts}],
)""".format(**dict(
        name = name,
        srcs = ",\n".join(['"%s"' % x for x in srcs]),
        defines = ",\n".join(['"%s"' % x for x in defines]),
        deps = ",\n".join(['"%s"' % namespaced_dep_name(x) for x in deps]),
        copts = ",\n".join(['"%s"' % x for x in copts]),
    ))

def podtobuild_dependencies():
    """Fetches repositories that are dependencies of the podtobuild workspace.

    Users should call this macro in their `WORKSPACE` to ensure that all of the
    dependencies of podtobuild are downloaded and that they are isolated from
    changes to those dependencies.
    """
    namespaced_new_git_repository(
        name = "Yams",
        remote = "https://github.com/jpsim/Yams.git",
        commit = "39698493e08190d867da98ff49210952b8059e78",
        patch_cmds = [
            """
echo '
module CYaml {
    umbrella header "CYaml.h"
    export *
}
' > Sources/CYaml/include/Yams.modulemap
""",
        ],
        build_file_content = namespaced_build_file([
            namespaced_swift_c_library(
                name = "CYaml",
                srcs = [
                    "Sources/CYaml/src/*.c",
                    "Sources/CYaml/src/*.h",
                ],
                hdrs = [
                    "Sources/CYaml/include/*.h",
                ],
                includes = ["Sources/CYaml/include"],
                module_map = "Sources/CYaml/include/Yams.modulemap",
            ),
            namespaced_swift_library(
                name = "Yams",
                srcs = ["Sources/Yams/*.swift"],
                deps = [":CYaml", ":CYamlLib"],
                defines = ["SWIFT_PACKAGE"],
            ),
        ]),
    )
    namespaced_new_git_repository(
        name = "SwiftCheck",
        remote = "https://github.com/typelift/SwiftCheck.git",
        build_file_content = namespaced_build_file([
            namespaced_swift_library(
                name = "SwiftCheck",
                srcs = ["Sources/**/*.swift"],
            ),
        ]),
        commit = "077c096c3ddfc38db223ac8e525ad16ffb987138",
    )
    namespaced_new_git_repository(
        name = "FileCheck",
        remote = "https://github.com/llvm-swift/FileCheck.git",
        build_file_content = namespaced_build_file([
            namespaced_swift_library(
                name = "FileCheck",
                srcs = ["Sources/**/*.swift"],
            ),
        ]),
        commit = "bd9cb30ceee1f21c02f51a7168f58471449807d8",
    )


