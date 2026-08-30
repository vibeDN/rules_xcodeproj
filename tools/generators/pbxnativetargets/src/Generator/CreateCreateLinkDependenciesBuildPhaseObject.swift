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
# MARK: ViboGram - CURRENT_ARCH is "undefined_arch" in this script phase's
# environment -- confirmed live (this phase doesn't run per-architecture the
# way the actual compile action does, so Xcode never resolves it here).
# $ARCHS (the target's configured architecture list) *is* reliably set
# regardless, so touch the placeholder under every configured arch instead
# of relying on CURRENT_ARCH.
# MARK: ViboGram - temporary diagnostic: an unambiguous marker file (a
# name CompileSwiftSources' own touch() never writes) so a subsequent run
# can prove definitively whether this block actually executed, independent
# of the swiftmodule file itself (which the stub also writes, so its mere
# existence can't distinguish "this ran first" from "the stub wrote it").
echo "ran at $(date -u +%Y-%m-%dT%H:%M:%S.%NZ), ARCHS='${ARCHS:-<unset>}'" >> "/tmp/create_link_deps_marker_${TARGET_NAME:-unknown}.txt" 2>/dev/null || true

if [[ -n "${SWIFT_VERSION:-}" && -n "${PRODUCT_MODULE_NAME:-}" && -n "${OBJECT_FILE_DIR_normal:-}" && -n "${ARCHS:-}" ]]; then
  for arch in ${ARCHS}; do
    mkdir -p "${OBJECT_FILE_DIR_normal}/${arch}"
    : > "${OBJECT_FILE_DIR_normal}/${arch}/.viboBAM_pretouch_marker"
    for ext in swiftmodule swiftdoc swiftsourceinfo swiftinterface; do
      f="${OBJECT_FILE_DIR_normal}/${arch}/${PRODUCT_MODULE_NAME}.${ext}"
      [[ -e "$f" ]] || : > "$f"
    done
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
