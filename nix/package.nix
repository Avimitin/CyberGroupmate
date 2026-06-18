{
  lib,
  stdenv,
  nodejs,
  pnpm,
  pnpmConfigHook,
  fetchPnpmDeps,
  node-gyp,
  python3,
  srcOnly,
  makeWrapper,
  callPackage,
}:

let
  version = "0.1.0";
  # Project root, relative to this file (nix/package.nix -> repo root).
  srcRoot = ../.;

  # `srcOnly nodejs` gives the unpacked Node source tree in the exact layout
  # `node-gyp --nodedir` expects (matches what nixpkgs' own `npmConfigHook`
  # uses as `nodeSrc`). We pass it explicitly to each native build so node-gyp
  # uses the local headers instead of trying to download them.
  nodeSources = srcOnly nodejs;

  # Filter the source so only build-relevant files enter the NAR. Editing
  # docs/tests/Dockerfiles/README/flake metadata (or even the dashboard UI
  # source, which is built in its own derivation) then no longer invalidates
  # the backend's cache.
  backendSource = lib.fileset.toSource {
    root = srcRoot;
    fileset = lib.fileset.unions [
      (srcRoot + "/package.json")
      (srcRoot + "/pnpm-lock.yaml")
      (srcRoot + "/pnpm-workspace.yaml")
      (srcRoot + "/patches")
      # Backend TS source, minus the standalone dashboard UI project.
      (lib.fileset.difference (srcRoot + "/src") (srcRoot + "/src/dashboard/ui"))
      (srcRoot + "/system-prompts")
    ];
  };

  # The dashboard UI lives in its own derivation (see ./dashboard-ui.nix) —
  # it's a self-contained Vite + Svelte project whose built static assets get
  # dropped into the backend's `src/dashboard/public` directory.
  dashboardUi = callPackage ./dashboard-ui.nix { inherit version; };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "cybergroupmate";
  inherit version;
  src = backendSource;

  nativeBuildInputs = [
    nodejs
    pnpm
    pnpmConfigHook
    node-gyp # builds node-pty + better-sqlite3 native addons from source
    python3 # gyp invokes python during native addon builds
    makeWrapper
  ];

  pnpmDeps = fetchPnpmDeps {
    pname = finalAttrs.pname;
    inherit (finalAttrs) version;
    src = backendSource;
    fetcherVersion = 4;
    hash = "sha256-2WgD872lsp/c6ITlSuJkWA13KYtyGlgOhGQF2U0DXi0=";
  };

  # `pnpmConfigHook` runs `pnpm install --offline --frozen-lockfile` in the
  # configure phase, applying the `@mtcute/core` patch declared in
  # `pnpm-workspace.yaml` (the patch file lives under `patches/`, included in
  # `src`). It uses `--ignore-scripts`, so native addons are NOT built there.
  #
  # Rather than relying on `pnpm rebuild` (which drives native builds through
  # pnpm's *bundled* node-gyp and tries to fetch Node headers from the
  # network), we build each native addon explicitly with `node-gyp` and a
  # local `--nodedir`. This mirrors how nixpkgs packages like `karakeep` build
  # `better-sqlite3` under pnpm.
  buildPhase = ''
    runHook preBuild

    # node-pty 1.1.0 has no Linux prebuilds, so its install script always
    # falls back to compiling `pty.node` from source. There may be multiple
    # versions in the pnpm store (transitive deps); build whichever resolved.
    for d in node_modules/.pnpm/node-pty@*/node_modules/node-pty; do
      echo "building native addon: $d"
      ( cd "$d" && node-gyp rebuild --nodedir="${nodeSources}" )
    done

    # better-sqlite3 ships no prebuilt binary offline; build it from its
    # bundled sqlite sources. (`build-release` == `node-gyp rebuild --release`.)
    # Multiple versions may be present; build each resolved one.
    for d in node_modules/.pnpm/better-sqlite3@*/node_modules/better-sqlite3; do
      echo "building native addon: $d"
      ( cd "$d" && npm run build-release --offline -- --nodedir="${nodeSources}" )
    done

    # sqlite-vec (vec0.so) and esbuild's platform binary ship as prebuilt
    # optional dependencies, so they need no build step.

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    local appdir="$out/lib/cybergroupmate"
    mkdir -p "$appdir" "$out/bin"

    cp -r package.json src system-prompts "$appdir"/
    cp -r node_modules "$appdir"/

    # Replace any stale/missing built dashboard assets with the ones from
    # the UI derivation. The backend serves these from
    # `src/dashboard/public` (relative to the dashboard-server module).
    rm -rf "$appdir/src/dashboard/public"
    cp -r ${dashboardUi} "$appdir/src/dashboard/public"

    # Runtime entrypoint is `src/main.ts`, executed with tsx from the
    # package's own node_modules. The process expects its CWD to be a writable
    # data directory: `config.yaml`, `workspace/`, `workspace/memory.db`, ...
    # are all resolved relative to `process.cwd()`. We default CWD to a
    # XDG-style data directory but let the caller override it via
    # `$CYBERGROUPMATE_WORKDIR` (used by the Home Manager module).
    #
    # We invoke tsx by absolute path instead of `npx tsx` so npx never tries
    # to fetch tsx from the network at runtime (the data dir has no
    # node_modules).
    makeWrapper "${nodejs}/bin/node" "$out/bin/cybergroupmate" \
      --prefix PATH : "${lib.makeBinPath [ nodejs ]}" \
      --set NODE_ENV production \
      --run 'cd "''${CYBERGROUPMATE_WORKDIR:-''${HOME:-/var/lib/cybergroupmate}/.local/share/cybergroupmate}"' \
      --add-flags "$appdir/node_modules/tsx/dist/cli.mjs" \
      --add-flags "$appdir/src/main.ts"

    runHook postInstall
  '';

  meta = {
    description = "A code-driven group chat social agent (CodeAct based)";
    homepage = "https://github.com/Archeb/CyberGroupmate";
    license = lib.licenses.agpl3Only;
    mainProgram = "cybergroupmate";
    maintainers = [ ];
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };

  # Expose the sub-derivations so they can be built/inspected directly from
  # the command line, e.g. `nix build .#cybergroupmate.passthru.dashboardUi`.
  passthru = {
    inherit dashboardUi;
  };
})
