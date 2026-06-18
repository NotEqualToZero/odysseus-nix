# Shared Odysseus package builder.
#
# Called by both module.nix (for the systemd service) and flake.nix
# (for the `packages` output). Returns an attrset with:
#   - package : the odysseus derivation (app source + wrappers)
#   - venv    : the immutable uv2nix virtual environment
#
# Takes the optional extras list so the venv can include faster-whisper etc.

{ lib
, pkgs
, odysseus                 # upstream source
, pyproject-nix
, uv2nix
, pyproject-build-systems
, extras ? []               # optional dep groups: "whisper" "duckduckgo" ...
}:

let
  python = pkgs.python312;

  # Overlay our pyproject.toml + uv.lock onto the upstream source so uv2nix
  # finds them together. Upstream source itself is never modified.
  combinedSrc = pkgs.runCommand "odysseus-with-lockfile" {} ''
    cp -r ${odysseus} $out
    chmod -R u+w $out
    cp ${./pyproject.toml} $out/pyproject.toml
    cp ${./uv.lock}        $out/uv.lock
  '';

  workspace = uv2nix.lib.workspace.loadWorkspace {
    workspaceRoot = combinedSrc;
  };

  overlay = workspace.mkPyprojectOverlay { sourcePreference = "wheel"; };

  baseSet = pkgs.callPackage pyproject-nix.build.packages { inherit python; };

  pythonSet = baseSet.overrideScope (
    lib.composeManyExtensions [
      overlay
      pyproject-build-systems.overlays.default
    ]
  );

  # Build the venv from the locked dependency set.
  # workspace.deps.default may be empty when package=false in pyproject.toml,
  # so fall back to the full locked set minus the odysseus stub entry.
  depsWithoutSelf = builtins.removeAttrs workspace.deps.default [ "odysseus" ];

  venv = pythonSet.mkVirtualEnv "odysseus-env" depsWithoutSelf;

  # Cookbook script patches: replace `python3 -m pip install` with
  # `uv pip install` targeting the mutable venv at $VIRTUAL_ENV.
  cookbookPatchScript = ''
    echo "Patching cookbook scripts: pip -> uv pip..."
    for f in \
        routes/cookbook_routes.py \
        cookbook_helpers.py \
        src/cookbook_helpers.py \
        routes/cookbook_helpers.py; do
      target="$out/lib/odysseus/$f"
      [ -f "$target" ] || continue
      echo "  patching $f"
      sed -i \
        -e 's|python3 -m pip install --no-cache-dir --user --break-system-packages|uv pip install --python "$VIRTUAL_ENV/bin/python"|g' \
        -e 's|python3 -m pip install --no-cache-dir|uv pip install --python "$VIRTUAL_ENV/bin/python"|g' \
        -e 's|python3 -m pip install --user --break-system-packages|uv pip install --python "$VIRTUAL_ENV/bin/python"|g' \
        -e 's|python3 -m pip install --user|uv pip install --python "$VIRTUAL_ENV/bin/python"|g' \
        -e 's|python3 -m pip install|uv pip install --python "$VIRTUAL_ENV/bin/python"|g' \
        "$target"
    done
  '';

  package = pkgs.stdenv.mkDerivation {
    pname   = "odysseus";
    version = "0-unstable";
    src     = combinedSrc;

    nativeBuildInputs = [ pkgs.makeWrapper pkgs.gnused ];
    buildInputs       = [ venv ];
    dontBuild         = true;

    installPhase = ''
      mkdir -p $out/lib/odysseus $out/bin
      cp -r . $out/lib/odysseus/
      [ -f _env ] && cp _env $out/lib/odysseus/.env.example || true

      ${cookbookPatchScript}

      makeWrapper ${venv}/bin/python $out/bin/odysseus \
        --add-flags "-m uvicorn app:app" \
        --add-flags "--host 127.0.0.1 --port 7000" \
        --set PYTHONPATH "$out/lib/odysseus" \
        --run 'cd "''${ODYSSEUS_HOME:-$HOME/.local/share/odysseus}"'

      makeWrapper ${venv}/bin/python $out/bin/odysseus-setup \
        --add-flags "$out/lib/odysseus/setup.py" \
        --set PYTHONPATH "$out/lib/odysseus" \
        --run 'cd "''${ODYSSEUS_HOME:-$HOME/.local/share/odysseus}"'
    '';

    meta = with lib; {
      description = "Self-hosted AI assistant UI with RAG, calendar, email, and research tools";
      license     = licenses.mit;
      platforms   = platforms.unix;
      mainProgram = "odysseus";
    };
  };

in {
  inherit package venv;
}
