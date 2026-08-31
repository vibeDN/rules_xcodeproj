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

# MARK: ViboGram - real fix for MobileNativeFoundation/rules_xcodeproj#3183.
# Root cause (confirmed live, not guessed): the native "Copy .swiftmodule
# et al into the framework bundle" step doesn't fail because its SOURCE is
# missing -- pre-creating the source under Objects-normal/$(arch), even
# well before xcodebuild starts, does not help at all (verified with a
# file whose creation time predates the whole build and is never deleted
# or recreated). It fails because multiple of Xcode's own parallel copy
# workers (one per artifact: swiftmodule/swiftdoc/swiftsourceinfo) race
# each other to mkdir the *shared destination* bundle-style directory
# (.../Modules/$(PRODUCT_MODULE_NAME).swiftmodule/, plus its nested
# .../Project subdirectory for swiftsourceinfo) -- whichever worker tries
# to open its file inside that directory before another worker's mkdir for
# the same path has completed gets ENOENT, misleadingly reported against
# the (perfectly fine) source path since Xcode's error message prints both
# paths together. Pre-creating the destination directory structure here
# removes the need for any worker to mkdir it at all, which is what
# actually fixes this (confirmed live: identical build succeeds cleanly
# once this directory pre-exists, fails identically every time otherwise).
if [[ -n "${SWIFT_VERSION:-}" && -n "${PRODUCT_MODULE_NAME:-}" && -n "${BUILT_PRODUCTS_DIR:-}" && -n "${FULL_PRODUCT_NAME:-}" ]]; then
  MODULE_DEST_DIR="${BUILT_PRODUCTS_DIR}/${FULL_PRODUCT_NAME}/Modules/${PRODUCT_MODULE_NAME}.swiftmodule"
  mkdir -p "${MODULE_DEST_DIR}/Project"
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
