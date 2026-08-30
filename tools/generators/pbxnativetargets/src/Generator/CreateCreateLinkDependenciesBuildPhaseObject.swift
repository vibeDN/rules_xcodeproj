import PBXProj
import ToolCommon

extension Generator {
    struct CreateCreateLinkDependenciesBuildPhaseObject {
        private let callable: Callable

        /// - Parameters:
        ///   - callable: The function that will be called in
        ///     `callAsFunction()`.
        init(callable: @escaping Callable = Self.defaultCallable) {
            self.callable = callable
        }

        /// Creates the "Create Link Dependencies" build phase object for a
        /// target.
        func callAsFunction(
            subIdentifier: Identifiers.Targets.SubIdentifier,
            hasCompileStub: Bool
        ) -> Object {
            return callable(
                /*subIdentifier:*/ subIdentifier,
                /*hasCompileStub:*/ hasCompileStub
            )
        }
    }
}

// MARK: - CreateCreateLinkDependenciesBuildPhaseObject.Callable

extension Generator.CreateCreateLinkDependenciesBuildPhaseObject {
    typealias Callable = (
        _ subIdentifier: Identifiers.Targets.SubIdentifier,
        _ hasCompileStub: Bool
    ) -> Object

    static func defaultCallable(
        subIdentifier: Identifiers.Targets.SubIdentifier,
        hasCompileStub: Bool
    ) -> Object {
        let action = #"""
perl -pe 's/\$(\()?([a-zA-Z_]\w*)(?(1)\))/$ENV{$2}/g' \
  "$SCRIPT_INPUT_FILE_0" > "$SCRIPT_OUTPUT_FILE_0"
"""#
        var shellScriptComponents: [String] = [
            #"""
set -euo pipefail

if [[ "${ENABLE_PREVIEWS:-}" == "YES" ]]; then
\#(action)
else
  touch "$SCRIPT_OUTPUT_FILE_0"
fi

# MARK: ViboGram - bugfix for MobileNativeFoundation/rules_xcodeproj#3183.
# swiftc_stub's touch() creates these placeholder module artifacts inside
# CompileSwiftSources, but that action's own declared-output tracking is
# apparently not a hard enough dependency edge for Xcode's build system:
# under BwB, the compiler is a near-instant stub rather than a real (slow)
# compile, and the native "Copy ... to Modules/" step that consumes these
# files can get scheduled before CompileSwiftSources finishes writing them
# -- confirmed live (mtime of the placeholder postdates the failed Copy
# attempt in the build log). This phase already runs unconditionally and
# strictly before Sources, with real declared outputs Xcode does honor, so
# pre-creating empty placeholders here closes that window: whichever phase
# actually runs first, the files already exist by the time Copy looks for
# them. CompileSwiftSources' own touch() still runs afterward and is a
# no-op against an already-existing file (mtime bump only), so this can't
# make an already-working target worse.
# MARK: ViboGram - temporary diagnostic (unconditional, always runs):
# dump the exact values this phase actually sees, to a per-target file, so
# a failing run tells us definitively which of these is empty/unset
# instead of guessing again.
{
  echo "SWIFT_VERSION=${SWIFT_VERSION:-<unset>}"
  echo "PRODUCT_MODULE_NAME=${PRODUCT_MODULE_NAME:-<unset>}"
  echo "OBJECT_FILE_DIR_normal=${OBJECT_FILE_DIR_normal:-<unset>}"
  echo "CURRENT_ARCH=${CURRENT_ARCH:-<unset>}"
} > "/tmp/create_link_deps_env_${TARGET_NAME:-unknown}.txt" 2>/dev/null || true

if [[ -n "${SWIFT_VERSION:-}" && -n "${PRODUCT_MODULE_NAME:-}" && -n "${OBJECT_FILE_DIR_normal:-}" && -n "${CURRENT_ARCH:-}" ]]; then
  mkdir -p "${OBJECT_FILE_DIR_normal}/${CURRENT_ARCH}"
  for ext in swiftmodule swiftdoc swiftsourceinfo swiftinterface; do
    f="${OBJECT_FILE_DIR_normal}/${CURRENT_ARCH}/${PRODUCT_MODULE_NAME}.${ext}"
    [[ -e "$f" ]] || : > "$f"
  done
fi

"""#,
        ]

        var outputPaths = [#"""
				"$(DERIVED_FILE_DIR)/link.params",
"""#]
        if hasCompileStub {
            outputPaths.append(#"""
				"$(DERIVED_FILE_DIR)/_CompileStub_.m",
"""#)
            shellScriptComponents.append(#"""
touch "$SCRIPT_OUTPUT_FILE_1"

"""#)
        }

        // The tabs for indenting are intentional
        let content = #"""
{
			isa = PBXShellScriptBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			inputPaths = (
				"$(LINK_PARAMS_FILE)",
			);
			name = "Create Link Dependencies";
			outputPaths = (
\#(outputPaths.joined(separator: "\n"))
			);
			runOnlyForDeploymentPostprocessing = 0;
			shellPath = /bin/sh;
			shellScript = \#(
    shellScriptComponents.joined(separator: "\n").pbxProjEscaped
);
			showEnvVarsInLog = 0;
		}
"""#

        return Object(
            identifier: Identifiers.Targets.buildPhase(
                .createLinkDependencies,
                subIdentifier: subIdentifier
            ),
            content: content
        )
    }
}
