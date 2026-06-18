# Odysseus — NixOS module.
#
# This is a NixOS module factory: it takes the pinned flake inputs and
# returns a module function { config, pkgs, lib, ... }. flake.nix calls it
# with the inputs; the flake-compat shim (default.nix) makes the same
# output available to non-flake consumers.
#
# The actual package is built by ./package.nix, shared with the flake's
# `packages` output.

{ lib
, odysseus
, pyproject-nix
, uv2nix
, pyproject-build-systems
}:

{ config, pkgs, lib, ... }:

let
  cfg = config.services.odysseus;

  moduleExtras =
    lib.optionals cfg.optionalDeps.whisper    [ "whisper"    ] ++
    lib.optionals cfg.optionalDeps.duckduckgo [ "duckduckgo" ] ++
    lib.optionals cfg.optionalDeps.mupdf      [ "mupdf"      ] ++
    lib.optionals cfg.optionalDeps.markitdown [ "markitdown" ];

  built = import ./package.nix {
    inherit lib pkgs odysseus pyproject-nix uv2nix pyproject-build-systems;
    extras = moduleExtras;
  };

  inherit (built) package venv;

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
