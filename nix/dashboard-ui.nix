# Static build of the CyberGroupmate dashboard UI.
#
# This is a self-contained Vite + Svelte project that lives under
# `src/dashboard/ui/` and ships its own `package.json` / `pnpm-lock.yaml`.
# We build it separately from the backend so its (sizeable) JS toolchain deps
# never leak into the runtime closure; only the resulting static assets get
# copied into the backend's `src/dashboard/public` directory, which
# `dashboard-server.ts` serves via `express.static(join(__dirname, "public"))`.
{
  lib,
  stdenv,
  nodejs,
  pnpm,
  pnpmConfigHook,
  fetchPnpmDeps,
  version,
}:

let
  # `nix/dashboard-ui.nix` -> `..` is the repo root.
  srcRoot = ../.;
  dashboardRoot = srcRoot + "/src/dashboard/ui";

  # Only the files the Vite build consumes, so unrelated changes (README, etc.)
  # don't bust the cache.
  dashboardSource = lib.fileset.toSource {
    root = dashboardRoot;
    fileset = lib.fileset.unions [
      (dashboardRoot + "/package.json")
      (dashboardRoot + "/pnpm-lock.yaml")
      (dashboardRoot + "/pnpm-workspace.yaml")
      (dashboardRoot + "/src")
      (dashboardRoot + "/public")
      (dashboardRoot + "/index.html")
      (dashboardRoot + "/vite.config.js")
      (dashboardRoot + "/svelte.config.js")
    ];
  };
in
stdenv.mkDerivation {
  pname = "cybergroupmate-dashboard-ui";
  inherit version;
  src = dashboardSource;

  pnpmDeps = fetchPnpmDeps {
    pname = "cybergroupmate-dashboard";
    inherit version;
    src = dashboardSource;
    fetcherVersion = 4;
    hash = "sha256-SLBtfDuhSodH8G8nQ9DY2wDYlq4WytqMxDjAbqZ74K8=";
  };

  nativeBuildInputs = [
    nodejs
    pnpm
    pnpmConfigHook
  ];

  # Vite's config sets `outDir: "../public"` (i.e. `src/dashboard/public`),
  # which is outside this derivation's `src` (the `ui` subdirectory only) and
  # would be read-only. Build into a local `dist` dir instead and let the
  # consumer copy it.
  buildPhase = ''
    runHook preBuild
    pnpm exec vite build --outDir dist --emptyOutDir
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp -r dist/. $out/
    runHook postInstall
  '';

  meta = {
    description = "CyberGroupmate dashboard UI (Vite + Svelte static build)";
    homepage = "https://github.com/Archeb/CyberGroupmate";
    license = lib.licenses.agpl3Only;
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
