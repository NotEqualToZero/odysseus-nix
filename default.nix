# Odysseus — NixOS module (Nix packaging layer).
#
# This file is the NixOS module. It is called by flake.nix which provides
# all pinned inputs. It can also be imported directly without a flake by
# passing the arguments manually — see the comments below.
#
# FLAKE USAGE in /etc/nixos/configuration.nix:
#
#   {
#     inputs.odysseus-nix.url = "github:your-user/odysseus-nix";
#     # or if local:
#     # inputs.odysseus-nix.url = "path:/path/to/odysseus-nix";
#   }
#
#   # In outputs:
#   { inputs, ... }:
#   {
#     nixosConfigurations.mymachine = inputs.nixpkgs.lib.nixosSystem {
#       modules = [
#         inputs.odysseus-nix.nixosModules.default
#         {
#           services.odysseus = {
#             enable  = true;
#             dataDir = "/tank/Models/Odysseus";
#             envFile = "/etc/odysseus/env";
#           };
#         }
#       ];
#     };
#   }
#
# NON-FLAKE USAGE in /etc/nixos/configuration.nix:
#
#   { pkgs, lib, ... }:
#   let
#     fetchInput = url: builtins.fetchGit { inherit url; };
#     pn  = import (fetchInput "https://github.com/pyproject-nix/pyproject.nix") { inherit lib; };
#     u2n = import (fetchInput "https://github.com/pyproject-nix/uv2nix")
#             { inherit lib; pyproject-nix = pn; };
#     pbs = import (fetchInput "https://github.com/pyproject-nix/build-system-pkgs")
#             { inherit lib; pyproject-nix = pn; uv2nix = u2n; };
#     src = fetchInput "https://github.com/pewdiepie-archdaemon/odysseus";
#     module = import (fetchInput "https://github.com/your-user/odysseus-nix" + "/default.nix") {
#       inherit lib pkgs src;
#       pyproject-nix = pn; uv2nix = u2n; pyproject-build-systems = pbs;
#     };
#   in {
#     imports = [ module.nixosModule ];
#     services.odysseus.enable = true;
#   }

# When called from flake.nix, pkgs is not passed at the top level —
# it is accessed inside the module via the standard { config, pkgs, lib, ... }.
# The ecosystem inputs are passed at call time by flake.nix.
{ lib
, odysseus              # upstream source (flake input, flake = false)
, pyproject-nix
, uv2nix
, pyproject-build-systems
# pkgs is NOT a top-level arg — it comes from the module system
}:

{ config, pkgs, lib, ... }:

let
  cfg    = config.services.odysseus;
  python = pkgs.python312;

  # The workspace root is always the upstream Odysseus source.
  # pyproject.toml and uv.lock in THIS repo describe its dependencies
  # and are copied into the source at build time (see mkPackage below).
  # uv2nix reads them from the merged source.
  #
  # We create a combined source that overlays our pyproject.toml + uv.lock
  # onto the upstream Odysseus tree so uv2nix finds them together.
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

  # Build the venv from all locked packages.
  # workspace.deps.default may be empty when package=false, so we use
  # the full locked set minus the odysseus stub entry.
  mkVenv =
    let
      depsWithoutSelf = builtins.removeAttrs workspace.deps.default [ "odysseus" ];
      # If deps.default is empty (package=false), fall back to all locked packages
      deps = if depsWithoutSelf == {}
             then lib.mapAttrs (_: _: []) (
               builtins.removeAttrs pythonSet [
                 "odysseus" "python" "makePythonPath" "overrideScope"
                 "callPackage" "newScope" "mkVirtualEnv"
               ])
             else depsWithoutSelf;
    in
      pythonSet.mkVirtualEnv "odysseus-env" deps;

  venv = mkVenv;

  # ------------------------------------------------------------------ #
  # Cookbook script patches                                             #
  # Replaces `python3 -m pip install` with `uv pip install` targeting  #
  # the mutable venv at <dataDir>/venv. Upstream source untouched.     #
  # ------------------------------------------------------------------ #
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

  options.services.odysseus = {
    enable = lib.mkEnableOption "Odysseus AI assistant UI";

    host = lib.mkOption {
      type        = lib.types.str;
      default     = "127.0.0.1";
      description = "Bind address for the uvicorn server.";
    };

    port = lib.mkOption {
      type        = lib.types.port;
      default     = 7000;
      description = "Port for the uvicorn server.";
    };

    dataDir = lib.mkOption {
      type        = lib.types.path;
      default     = "/var/lib/odysseus";
      description = "Directory for persistent data (database, uploads, auth, venv, etc.).";
    };

    user = lib.mkOption {
      type        = lib.types.str;
      default     = "odysseus";
      description = "User account under which Odysseus runs.";
    };

    group = lib.mkOption {
      type        = lib.types.str;
      default     = "odysseus";
      description = "Group account under which Odysseus runs.";
    };

    envFile = lib.mkOption {
      type        = lib.types.nullOr lib.types.path;
      default     = null;
      description = ''
        Path to a .env file containing secrets (API keys, passwords, etc.).
        See the bundled .env.example for available options.
      '';
    };

    extraEnv = lib.mkOption {
      type    = lib.types.attrsOf lib.types.str;
      default = {};
      example = {
        SEARXNG_INSTANCE = "http://localhost:8080";
        OLLAMA_HOST      = "http://127.0.0.1:11434";
      };
      description = "Extra environment variables passed to the service.";
    };

    optionalDeps = {
      whisper = lib.mkOption {
        type        = lib.types.bool;
        default     = false;
        description = "Install faster-whisper for local CPU/GPU speech-to-text.";
      };
      duckduckgo = lib.mkOption {
        type        = lib.types.bool;
        default     = false;
        description = "Install ddgs for DuckDuckGo search provider.";
      };
      mupdf = lib.mkOption {
        type        = lib.types.bool;
        default     = false;
        description = "Install PyMuPDF for PDF form-filling (AGPL-3.0).";
      };
      markitdown = lib.mkOption {
        type        = lib.types.bool;
        default     = false;
        description = "Install markitdown for Office/EPUB text extraction.";
      };
    };
  };

  config = lib.mkIf cfg.enable {

    users.users.${cfg.user} = {
      isNormalUser = true;
      home         = cfg.dataDir;
      createHome   = true;
      group        = cfg.group;
      shell        = pkgs.bash;
      description  = "Odysseus service user";
    };

    users.groups.${cfg.group} = {};

    environment.systemPackages = [ pkgs.tmux pkgs.llama-cpp pkgs.uv ];

    systemd.services.odysseus = {
      description = "Odysseus AI assistant UI";
      wantedBy    = [ "multi-user.target" ];
      after       = [ "network.target" ];

      environment = {
        ODYSSEUS_DATA_DIR          = cfg.dataDir;
        DATABASE_URL               = "sqlite:///${cfg.dataDir}/app.db";
        PYTHONPATH                 = "${package}/lib/odysseus";
        ODYSSEUS_SKIP_RUN_HINT     = "1";
        ODYSSEUS_SKIP_ADMIN_PROMPT = "1";
        HOME                       = cfg.dataDir;
        HF_HOME                    = "${cfg.dataDir}/.cache/huggingface";
        HF_HUB_CACHE               = "${cfg.dataDir}/.cache/huggingface/hub";
        VIRTUAL_ENV                = "${cfg.dataDir}/venv";
        UV_PYTHON                  = "${cfg.dataDir}/venv/bin/python";
        ODYSSEUS_INSTALLER         = "uv";
        UV_PYTHON_DOWNLOADS        = "never";
      } // cfg.extraEnv;

      serviceConfig = {
        Type             = "simple";
        User             = cfg.user;
        Group            = cfg.group;
        WorkingDirectory = cfg.dataDir;

        ExecStart = pkgs.writeShellScript "odysseus-start" ''
          if [ -f "${cfg.dataDir}/venv/bin/activate" ]; then
            source "${cfg.dataDir}/venv/bin/activate"
          fi
          export PATH="${package}/bin:${pkgs.uv}/bin:${pkgs.tmux}/bin:${pkgs.llama-cpp}/bin:${venv}/bin:/run/current-system/sw/bin:$PATH"
          export PYTHONPATH="${package}/lib/odysseus"
          export VIRTUAL_ENV="${cfg.dataDir}/venv"
          export UV_PYTHON="${cfg.dataDir}/venv/bin/python"
          export UV_PYTHON_DOWNLOADS="never"
          exec ${venv}/bin/python -m uvicorn app:app \
            --host ${cfg.host} \
            --port ${toString cfg.port}
        '';

        EnvironmentFile = lib.mkIf (cfg.envFile != null) cfg.envFile;
        Restart         = "on-failure";
        RestartSec      = "5s";
        NoNewPrivileges = true;
        PrivateTmp      = false;
        ProtectSystem   = "strict";
        ReadWritePaths  = [ cfg.dataDir "/tmp" ];
        ProtectHome     = true;
      };

      preStart = ''
        chown -R ${cfg.user}:${cfg.group} ${cfg.dataDir} || true
        mkdir -p ${cfg.dataDir}/.cache/huggingface/hub
        mkdir -p ${cfg.dataDir}/tmux
        mkdir -p ${cfg.dataDir}/logs

        if [ ! -d "${cfg.dataDir}/venv" ]; then
          echo "Creating mutable venv for runtime installs..."
          ${pkgs.uv}/bin/uv venv \
            --python ${venv}/bin/python \
            --system-site-packages \
            ${cfg.dataDir}/venv
        fi

        if [ ! -f "${cfg.dataDir}/app.db" ]; then
          echo "Running first-time Odysseus setup..."
          PYTHONPATH=${package}/lib/odysseus \
            ${venv}/bin/python \
            ${package}/lib/odysseus/setup.py
        fi
      '';
    };
  };
}
