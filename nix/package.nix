{ lib
, stdenvNoCC
, bun
, nodejs
, makeWrapper
}:

let
  pkg = lib.importJSON ../package.json;

  # Only the inputs that affect dependency resolution. Keeping this narrow
  # stops unrelated source edits from invalidating the fixed-output hash.
  depsSrc = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../package.json
      ../bun.lock
      ../patches
    ];
  };

  # Fixed-output derivation: the one stage allowed network access, so bun can
  # fetch the registry and apply the ink@6.2.0 patch. nar hashing ignores
  # mtimes, so the resulting tree hash is stable across rebuilds.
  nodeModules = stdenvNoCC.mkDerivation {
    pname = "${pkg.name}-node-modules";
    inherit (pkg) version;
    src = depsSrc;

    nativeBuildInputs = [ bun ];
    dontConfigure = true;

    buildPhase = ''
      runHook preBuild
      export HOME="$TMPDIR"
      export BUN_INSTALL_CACHE_DIR="$TMPDIR/bun-cache"
      # --ignore-scripts skips lifecycle scripts (e.g. unrs-resolver's
      # napi-postinstall, which shells out to /usr/bin/env and cannot run in the
      # sandbox). Its native binary is a lint-only transitive dep and never ends
      # up in the runtime bundle. Patched dependencies still apply; patching is
      # part of the installer, not a lifecycle script.
      bun install \
        --frozen-lockfile \
        --ignore-scripts \
        --no-progress \
        --no-summary
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -R node_modules "$out/node_modules"
      runHook postInstall
    '';

    dontFixup = true;

    outputHashMode = "recursive";
    outputHashAlgo = "sha256";
    # Refresh with: nix build .#packages.<system>.default and paste the "got:" hash.
    outputHash = "sha256-+gbqEE4i3UgGHConOp4rt6dbqk522r97zGBUQJwK2qY=";
  };
in
stdenvNoCC.mkDerivation {
  pname = pkg.name;
  inherit (pkg) version;
  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../src
      ../scripts
      ../package.json
      ../bun.lock
      ../tsconfig.json
    ];
  };

  nativeBuildInputs = [ bun nodejs makeWrapper ];

  configurePhase = ''
    runHook preConfigure
    cp -R ${nodeModules}/node_modules ./node_modules
    chmod -R u+w node_modules
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    export HOME="$TMPDIR"
    # `bun build` bundles every runtime dependency into a single node-targeted
    # file, so the artifact is self-contained and needs no node_modules to run.
    bun run build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/bin" "$out/lib/ccstatusline"
    cp dist/ccstatusline.js "$out/lib/ccstatusline/ccstatusline.js"
    makeWrapper ${nodejs}/bin/node "$out/bin/ccstatusline" \
      --add-flags "$out/lib/ccstatusline/ccstatusline.js"
    runHook postInstall
  '';

  meta = {
    description = pkg.description;
    homepage = "https://github.com/sirmalloc/ccstatusline";
    license = lib.licenses.mit;
    mainProgram = "ccstatusline";
  };
}
