# Copyright 2018 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""Implementation of compilation logic for Swift."""

load(":actions.bzl", "run_toolchain_swift_action")
load(":deps.bzl", "collect_link_libraries")
load(":derived_files.bzl", "derived_files")
load(
    ":providers.bzl",
    "SwiftClangModuleInfo",
    "SwiftInfo",
    "SwiftToolchainInfo",
)
load(":utils.bzl", "collect_transitive")
load("@bazel_skylib//lib:collections.bzl", "collections")
load("@bazel_skylib//lib:paths.bzl", "paths")

# Swift compiler options that cause the code to be compiled using whole-module optimization.
_WMO_COPTS = ("-force-single-frontend-invocation", "-whole-module-optimization", "-wmo")

def collect_transitive_compile_inputs(args, deps, direct_defines = []):
    """Collect transitive inputs and flags from Swift providers.

    Args:
        args: An `Args` object to which
        deps: The dependencies for which the inputs should be gathered.
        direct_defines: The list of defines for the target being built, which are merged with the
            transitive defines before they are added to `args` in order to prevent duplication.

    Returns:
        A list of `depset`s representing files that must be passed as inputs to the Swift
        compilation action.
    """
    input_depsets = []

    # Collect all the search paths, module maps, flags, and so forth from transitive dependencies.
    transitive_swiftmodules = collect_transitive(
        deps,
        SwiftInfo,
        "transitive_swiftmodules",
    )
    args.add_all(transitive_swiftmodules, format_each = "-I%s", map_each = _dirname_map_fn)
    input_depsets.append(transitive_swiftmodules)

    transitive_defines = collect_transitive(
        deps,
        SwiftInfo,
        "transitive_defines",
        direct = direct_defines,
    )
    args.add_all(transitive_defines, format_each = "-D%s")

    transitive_modulemaps = collect_transitive(
        deps,
        SwiftClangModuleInfo,
        "transitive_modulemaps",
    )
    input_depsets.append(transitive_modulemaps)
    args.add_all(
        transitive_modulemaps,
        before_each = "-Xcc",
        format_each = "-fmodule-map-file=%s",
    )

    transitive_cc_headers = collect_transitive(
        deps,
        SwiftClangModuleInfo,
        "transitive_headers",
    )
    input_depsets.append(transitive_cc_headers)

    transitive_cc_compile_flags = collect_transitive(
        deps,
        SwiftClangModuleInfo,
        "transitive_compile_flags",
    )

    # Handle possible spaces in these arguments correctly (for example,
    # `-isystem foo`) by prepending `-Xcc` to each one.
    for arg in transitive_cc_compile_flags.to_list():
        args.add_all(arg.split(" "), before_each = "-Xcc")

    transitive_cc_defines = collect_transitive(
        deps,
        SwiftClangModuleInfo,
        "transitive_defines",
    )
    args.add_all(transitive_cc_defines, before_each = "-Xcc", format_each = "-D%s")

    return input_depsets

def declare_compile_outputs(
        actions,
        copts,
        srcs,
        target_name,
        index_while_building = False):
    """Declares output files (and optional output file map) for a compile action.

    Args:
        actions: The object used to register actions.
        copts: The flags that will be passed to the compile action, which are scanned to determine
            whether a single frontend invocation will be used or not.
        srcs: The list of source files that will be compiled.
        target_name: The name (excluding package path) of the target being built.
        index_while_building: If `True`, a tree artifact will be declared to hold Clang index store
            data and the relevant option will be added during compilation to generate the indexes.

    Returns:
        A `struct` containing the following fields:

        *   `args`: A list of values that should be added to the `Args` of the compile action.
        *   `compile_inputs`: Additional input files that should be passed to the compile action.
        *   `other_outputs`: Additional output files that should be declared by the compile action,
            but which are not processed further.
        *   `output_groups`: A dictionary of additional output groups that should be propagated by
            the calling rule using the `OutputGroupInfo` provider.
        *   `output_objects`: A list of object (.o) files that will be the result of the compile
            action and which should be archived afterward.
    """
    output_nature = _emitted_output_nature(copts)

    if not output_nature.emits_multiple_objects:
        # If we're emitting a single object, we don't use an object map; we just declare the output
        # file that the compiler will generate and there are no other partial outputs.
        out_obj = derived_files.whole_module_object_file(actions, target_name = target_name)
        return struct(
            args = ["-o", out_obj],
            compile_inputs = [],
            other_outputs = [],
            output_groups = {},
            output_objects = [out_obj],
        )

    # Otherwise, we need to create an output map that lists the individual object files so that we
    # can pass them all to the archive action.
    output_map_file = derived_files.swiftc_output_file_map(actions, target_name = target_name)

    # The output map data, which is keyed by source path and will be written to `output_map_file`.
    output_map = {}

    # Object files that will be used to build the archive.
    output_objs = []

    # Additional files, such as partial Swift modules, that must be declared as action outputs
    # although they are not processed further.
    other_outputs = []

    for src in srcs:
        src_output_map = {}

        # Declare the object file (there is one per source file).
        obj = derived_files.intermediate_object_file(actions, target_name = target_name, src = src)
        output_objs.append(obj)
        src_output_map["object"] = obj.path

        # Multi-threaded WMO compiles still produce a single .swiftmodule file, despite producing
        # multiple object files, so we have to check explicitly for that case.
        if output_nature.emits_partial_modules:
            partial_module = derived_files.partial_swiftmodule(
                actions,
                target_name = target_name,
                src = src,
            )
            other_outputs.append(partial_module)
            src_output_map["swiftmodule"] = partial_module.path

        output_map[src.path] = struct(**src_output_map)

    actions.write(
        content = struct(**output_map).to_json(),
        output = output_map_file,
    )

    args = ["-output-file-map", output_map_file]
    output_groups = {}

    # Configure index-while-building if requested. IDEs and other indexing tools can enable this
    # feature on the command line during a build and then access the index store artifacts that are
    # produced.
    if index_while_building:
        index_store_dir = derived_files.indexstore_directory(actions, target_name = target_name)
        other_outputs.append(index_store_dir)
        args.extend(["-index-store-path", index_store_dir.path])
        output_groups["swift_index_store"] = depset(direct = [index_store_dir])

    return struct(
        args = args,
        compile_inputs = [output_map_file],
        other_outputs = other_outputs,
        output_groups = output_groups,
        output_objects = output_objs,
    )

def find_swift_version_copt_value(copts):
    """Returns the value of the `-swift-version` argument, if found.

    Args:
        copts: The list of copts to be scanned.

    Returns:
        The value of the `-swift-version` argument, or None if it was not found in the copt list.
    """

    # Note that the argument can occur multiple times, and the last one wins.
    last_swift_version = None

    count = len(copts)
    for i in range(count):
        copt = copts[i]
        if copt == "-swift-version" and i + 1 < count:
            last_swift_version = copts[i + 1]

    return last_swift_version

def new_objc_provider(
        deps,
        include_path,
        link_inputs,
        linkopts,
        module_map,
        static_archive,
        swiftmodule,
        objc_header = None):
    """Creates an `apple_common.Objc` provider for a Swift target.

    Args:
        deps: The dependencies of the target being built, whose `Objc` providers will be passed to
            the new one in order to propagate the correct transitive fields.
        include_path: A header search path that should be propagated to dependents.
        link_inputs: Additional linker input files that should be propagated to dependents.
        linkopts: Linker options that should be propagated to dependents.
        module_map: The module map generated for the Swift target's Objective-C header, if any.
        static_archive: The static archive (`.a` file) containing the target's compiled code.
        swiftmodule: The `.swiftmodule` file for the compiled target.
        objc_header: The generated Objective-C header for the Swift target. If `None`, no headers
            will be propagated. This header is only needed for Swift code that defines classes that
            should be exposed to Objective-C.

    Returns:
        An `apple_common.Objc` provider that should be returned by the calling rule.
    """
    objc_providers = [dep[apple_common.Objc] for dep in deps if apple_common.Objc in dep]
    objc_provider_args = {
        "include": depset(direct = [include_path]),
        "library": depset(direct = [static_archive]),
        "link_inputs": depset(direct = [swiftmodule] + link_inputs),
        "providers": objc_providers,
        "uses_swift": True,
    }

    if objc_header:
        objc_provider_args["header"] = depset(direct = [objc_header])
    if linkopts:
        objc_provider_args["linkopt"] = depset(direct = linkopts)

    # In addition to the generated header's module map, we must re-propagate the direct deps'
    # Objective-C module maps to dependents, because those Swift modules still need to see them. We
    # need to construct a new transitive objc provider to get the correct strict propagation
    # behavior.
    transitive_objc_provider_args = {"providers": objc_providers}
    if module_map:
        transitive_objc_provider_args["module_map"] = depset(direct = [module_map])

    transitive_objc = apple_common.new_objc_provider(**transitive_objc_provider_args)
    objc_provider_args["module_map"] = transitive_objc.module_map

    return apple_common.new_objc_provider(**objc_provider_args)

def objc_compile_requirements(args, deps, objc_fragment):
    """Collects compilation requirements for Objective-C dependencies.

    Args:
        args: An `Args` object to which compile options will be added.
        deps: The `deps` of the target being built.
        objc_fragment: The `objc` configuration fragment.

    Returns:
        A `depset` of files that should be included among the inputs of the compile action.
    """
    defines = []
    includes = []
    inputs = []
    module_maps = []
    static_frameworks = []
    all_frameworks = []

    objc_providers = [dep[apple_common.Objc] for dep in deps if apple_common.Objc in dep]

    for objc in objc_providers:
        inputs.append(objc.header)
        inputs.append(objc.umbrella_header)
        inputs.append(objc.static_framework_file)
        inputs.append(objc.dynamic_framework_file)

        defines.append(objc.define)
        includes.append(objc.include)

        static_frameworks.append(objc.framework_dir)
        all_frameworks.append(objc.framework_dir)
        all_frameworks.append(objc.dynamic_framework_dir)

    # Collect module maps for dependencies. These must be pulled from a combined transitive
    # provider to get the correct strict propagation behavior that we use to workaround command-line
    # length issues until Swift 4.2 is available.
    transitive_objc_provider = apple_common.new_objc_provider(providers = objc_providers)
    module_maps = transitive_objc_provider.module_map
    inputs.append(module_maps)

    # Add the objc dependencies' header search paths so that imported modules can find their
    # headers.
    args.add_all(depset(transitive = includes), format_each = "-I%s")

    # Add framework search paths for any Objective-C frameworks propagated through static/dynamic
    # framework provider keys.
    args.add_all(
        depset(transitive = all_frameworks),
        format_each = "-F%s",
        map_each = paths.dirname,
    )

    # Disable the `LC_LINKER_OPTION` load commands for static framework automatic linking. This is
    # needed to correctly deduplicate static frameworks from also being linked into test binaries
    # where it is also linked into the app binary. TODO(allevato): Update this to not expand the
    # depset once `Args.add` supports returning multiple elements from a `map_fn`.
    for framework in depset(transitive = static_frameworks).to_list():
        args.add_all(collections.before_each(
            "-Xfrontend",
            [
                "-disable-autolink-framework",
                _objc_provider_framework_name(framework),
            ],
        ))

    # Swift's ClangImporter does not include the current directory by default in its search paths,
    # so we must add it to find workspace-relative imports in headers imported by module maps.
    args.add_all(["-Xcc", "-iquote."])

    # Ensure that headers imported by Swift modules have the correct defines propagated from
    # dependencies.
    args.add_all(depset(transitive = defines), before_each = "-Xcc", format_each = "-D%s")

    # Load module maps explicitly instead of letting Clang discover them in the search paths. This
    # is needed to avoid a case where Clang may load the same header in modular and non-modular
    # contexts, leading to duplicate definitions in the same file.
    # <https://llvm.org/bugs/show_bug.cgi?id=19501>
    args.add_all(module_maps, before_each = "-Xcc", format_each = "-fmodule-map-file=%s")

    # Add any copts required by the `objc` configuration fragment.
    args.add_all(_clang_copts(objc_fragment), before_each = "-Xcc")

    return depset(transitive = inputs)

def register_autolink_extract_action(
        actions,
        objects,
        output,
        toolchain):
    """Extracts autolink information from Swift `.o` files.

    For some platforms (such as Linux), autolinking of imported frameworks is achieved by extracting
    the information about which libraries are needed from the `.o` files and producing a text file
    with the necessary linker flags. That file can then be passed to the linker as a response file
    (i.e., `@flags.txt`).

    Args:
        actions: The object used to register actions.
        objects: The list of object files whose autolink information will be extracted.
        output: A `File` into which the autolink information will be written.
        toolchain: The `SwiftToolchainInfo` provider of the toolchain.
    """
    tool_args = actions.args()
    tool_args.add_all(objects)
    tool_args.add("-o", output)

    run_toolchain_swift_action(
        actions = actions,
        toolchain = toolchain,
        arguments = [tool_args],
        inputs = objects,
        mnemonic = "SwiftAutolinkExtract",
        outputs = [output],
        swift_tool = "swift-autolink-extract",
    )

def swift_library_output_map(name, module_link_name):
    """Returns the dictionary of implicit outputs for a `swift_library`.

    This function is used to specify the `outputs` of the `swift_library` rule; as such, its
    arguments must be named exactly the same as the attributes to which they refer.

    Args:
        name: The name of the target being built.
        module_link_name: The module link name of the target being built.

    Returns:
        The implicit outputs dictionary for a `swift_library`.
    """
    lib_name = module_link_name if module_link_name else name
    return {
        "archive": "lib{}.a".format(lib_name),
    }

def write_objc_header_module_map(
        actions,
        module_name,
        objc_header,
        output):
    """Writes a module map for a generated Swift header to a file.

    Args:
        actions: The context's actions object.
        module_name: The name of the Swift module.
        objc_header: The `File` representing the generated header.
        output: The `File` to which the module map should be written.
    """
    actions.write(
        content = ('module "{module_name}" {{\n' +
                   '  header "../{header_name}"\n' +
                   "}}\n").format(
            header_name = objc_header.basename,
            module_name = module_name,
        ),
        output = output,
    )

def _clang_copts(objc_fragment):
    """Returns copts that should be passed to `clang` from the `objc` fragment.

    Args:
        objc_fragment: The `objc` configuration fragment.

    Returns:
        A list of `clang` copts.
    """

    # In general, every compilation mode flag from native `objc_*` rules should be passed, but `-g`
    # seems to break Clang module compilation. Since this flag does not make much sense for module
    # compilation and only touches headers, it's ok to omit.
    clang_copts = objc_fragment.copts + objc_fragment.copts_for_current_compilation_mode
    return [copt for copt in clang_copts if copt != "-g"]

def _dirname_map_fn(f):
    """Returns the dir name of a file.

    This function is intended to be used as a mapping function for file passed into `Args.add`.

    Args:
        f: The file.

    Returns:
        The dirname of the file.
    """
    return f.dirname

def _emitted_output_nature(copts):
    """Returns a `struct` with information about the nature of emitted outputs for the given flags.

    The compiler emits a single object if it is invoked with whole-module optimization enabled and
    is single-threaded (`-num-threads` is not present or is equal to 1); otherwise, it emits one
    object file per source file. It also emits a single `.swiftmodule` file for WMO builds,
    _regardless of thread count,_ so we have to treat that case separately.

    Args:
        copts: The options passed into the compile action.

    Returns:
        A struct containing the following fields:

        *   `emits_multiple_objects`: `True` if the Swift frontend emits an object file per source
            file, instead of a single object file for the whole module, in a compilation action with
            the given flags.
        *   `emits_partial_modules`: `True` if the Swift frontend emits partial `.swiftmodule` files
            for the individual source files in a compilation action with the given flags.
    """
    is_wmo = False
    saw_space_separated_num_threads = False
    num_threads = 1

    for copt in copts:
        if copt in _WMO_COPTS:
            is_wmo = True
        elif saw_space_separated_num_threads:
            saw_space_separated_num_threads = False
            num_threads = _safe_int(copt)
        elif copt == "-num-threads":
            saw_space_separated_num_threads = True
        elif copt.startswith("-num-threads="):
            num_threads = _safe_int(copt.split("=")[1])

    if not num_threads:
        fail("The value of '-num-threads' must be a positive integer.")

    return struct(
        emits_multiple_objects = not (is_wmo and num_threads == 1),
        emits_partial_modules = not is_wmo,
    )

def _safe_int(s):
    """Returns the integer value of `s` when interpreted as base 10, or `None` if it is invalid.

    This function is needed because `int()` fails the build when passed a string that isn't a valid
    integer, with no way to recover (https://github.com/bazelbuild/bazel/issues/5940).

    Args:
        s: The string to be converted to an integer.

    Returns:
        The integer value of `s`, or `None` if was not a valid base 10 integer.
    """
    for i in range(len(s)):
        if s[i] < "0" or s[i] > "9":
            return None
    return int(s)

def _objc_provider_framework_name(path):
    """Returns the name of the framework from an `objc` provider path.

    Args:
        path: A path that came from an `objc` provider.

    Returns:
        A string containing the name of the framework (e.g., `Foo` for `Foo.framework`).
    """
    return path.rpartition("/")[2].partition(".")[0]
