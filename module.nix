# Odysseus — NixOS module.
#
# Runs the Odysseus web UI as a systemd service.
#
# The odysseus source is pinned via npins (npins/sources.json). Override it
# per-host with services.odysseus.src if you need a different commit.
#
# Backend model servers are NOT managed here — use backendPackages to put
# binaries on PATH for the cookbook, or extraEnv to point at existing services.

{ odysseus }:  # pinned default source from npins, passed by default.nix

{ config, pkgs, lib, ... }:

let
  cfg = config.services.odysseus;

  effectiveSrc = if cfg.src != null then cfg.src else odysseus;

  moduleExtras =
    lib.optionals cfg.optionalDeps.whisper    [ "whisper"    ] ++
    lib.optionals cfg.optionalDeps.duckduckgo [ "duckduckgo" ] ++
    lib.optionals cfg.optionalDeps.mupdf      [ "mupdf"      ] ++
    lib.optionals cfg.optionalDeps.markitdown [ "markitdown" ];

  built = import ./package.nix {
    inherit lib pkgs;
    odysseus = effectiveSrc;
    extras   = moduleExtras;
  };

  inherit (built) package pythonEnv;

  backendBinPaths = lib.concatStringsSep ":"
    (map (p: "${p}/bin") cfg.backendPackages);

in {

  options.services.odysseus = {
    enable = lib.mkEnableOption "Odysseus AI assistant UI";

    src = lib.mkOption {
      type    = lib.types.nullOr lib.types.path;
      default = null;
      example = lib.literalExpression ''
        pkgs.fetchFromGitHub {
          owner = "pewdiepie-archdaemon";
          repo  = "odysseus";
          rev   = "abc1234";
          hash  = "sha256-...";
        }
      '';
      description = ''
        Override the Odysseus source. When null (default) the version pinned
        in npins/sources.json is used. Set this to pin a specific commit
        per-host without changing the shared pin.
      '';
    };

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
      type    = lib.types.str;
      default = "odysseus";
    };

    group = lib.mkOption {
      type    = lib.types.str;
      default = "odysseus";
    };

    envFile = lib.mkOption {
      type        = lib.types.nullOr lib.types.path;
      default     = null;
      description = "Path to a file containing secret environment variables (API keys, etc.).";
    };

    extraEnv = lib.mkOption {
      type    = lib.types.attrsOf lib.types.str;
      default = {};
      example = {
        OLLAMA_BASE_URL = "http://127.0.0.1:11434";
        OPENAI_API_BASE = "http://127.0.0.1:8080/v1";
        OPENAI_API_KEY  = "sk-local";
      };
      description = ''
        Extra environment variables. Use to point Odysseus at model servers
        already running on the system — Ollama, llama-server, vllm, etc.
      '';
    };

    backendPackages = lib.mkOption {
      type    = lib.types.listOf lib.types.package;
      default = [];
      example = lib.literalExpression "[ pkgs.llama-cpp ]";
      description = ''
        Packages placed on PATH inside the service so the Odysseus cookbook
        can launch them on demand via tmux (llama-server, vllm, etc.).
        GPU variants: pkgs.llama-cpp.override { vulkanSupport = true; }
      '';
    };

    optionalDeps = {
      whisper = lib.mkOption {
        type    = lib.types.bool;
        default = false;
        description = "Install faster-whisper for local speech-to-text (pinned in requirements-whisper.lock).";
      };
      duckduckgo = lib.mkOption {
        type    = lib.types.bool;
        default = false;
        description = "Install ddgs for DuckDuckGo search.";
      };
      mupdf = lib.mkOption {
        type    = lib.types.bool;
        default = false;
        description = "Install PyMuPDF for PDF form-filling (AGPL-3.0).";
      };
      markitdown = lib.mkOption {
        type    = lib.types.bool;
        default = false;
        description = "Install markitdown for Office/EPUB extraction.";
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

    # Cookbook runner scripts use a hardcoded #!/bin/bash shebang.
    system.activationScripts.odysseusBinBash = ''
      mkdir -p /bin
      ln -sf ${pkgs.bash}/bin/bash /bin/bash
    '';

    environment.systemPackages = [ pkgs.tmux pkgs.uv ] ++ cfg.backendPackages;

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
      } // cfg.extraEnv;

      serviceConfig = {
        Type             = "simple";
        User             = cfg.user;
        Group            = cfg.group;
        WorkingDirectory = cfg.dataDir;

        ExecStart = pkgs.writeShellScript "odysseus-start" ''
          VENV_SITE="${cfg.dataDir}/venv/lib/python3.12/site-packages"
          export VIRTUAL_ENV="${cfg.dataDir}/venv"
          export PATH="${cfg.dataDir}/venv/bin:${package}/bin:${pkgs.uv}/bin:${pkgs.tmux}/bin:${pythonEnv}/bin${lib.optionalString (cfg.backendPackages != []) ":${backendBinPaths}"}:/run/current-system/sw/bin:$PATH"
          export PYTHONPATH="${package}/lib/odysseus:$VENV_SITE"
          exec "${cfg.dataDir}/venv/bin/python" -m uvicorn app:app \
            --host ${cfg.host} \
            --port ${toString cfg.port}
        '';

        EnvironmentFile = lib.mkIf (cfg.envFile != null) cfg.envFile;
        Restart         = "on-failure";
        RestartSec      = "5s";
        KillMode        = "process";

        NoNewPrivileges = true;
        PrivateTmp      = false;
        ProtectSystem   = "strict";
        ReadWritePaths  = [ cfg.dataDir "/tmp" ];
        ProtectHome     = true;
      };

      preStart = ''
        mkdir -p ${cfg.dataDir}/.cache/huggingface/hub
        mkdir -p ${cfg.dataDir}/tmux
        mkdir -p ${cfg.dataDir}/logs

        chown ${cfg.user}:${cfg.group} ${cfg.dataDir}
        chown -R ${cfg.user}:${cfg.group} ${cfg.dataDir}/.cache
        chown -R ${cfg.user}:${cfg.group} ${cfg.dataDir}/tmux
        chown -R ${cfg.user}:${cfg.group} ${cfg.dataDir}/logs

        # Recreate if missing or if previously created by uv (uv sets creator=uv in pyvenv.cfg)
        if [ ! -f "${cfg.dataDir}/venv/pyvenv.cfg" ] || \
           grep -q "^creator = uv" "${cfg.dataDir}/venv/pyvenv.cfg" 2>/dev/null; then
          echo "Creating mutable venv..."
          rm -rf "${cfg.dataDir}/venv"
          ${pythonEnv}/bin/python -m venv \
            --system-site-packages \
            ${cfg.dataDir}/venv
          chown -R ${cfg.user}:${cfg.group} ${cfg.dataDir}/venv
        fi

        echo "Installing pinned bootstrap packages..."
        "${cfg.dataDir}/venv/bin/python" -m pip install \
          --break-system-packages \
          --ignore-installed \
          --require-hashes \
          -r ${./requirements.lock}

        ${lib.optionalString cfg.optionalDeps.whisper ''
          echo "Installing faster-whisper..."
          "${cfg.dataDir}/venv/bin/python" -m pip install \
            --break-system-packages \
            --ignore-installed \
            --require-hashes \
            -r ${./requirements-whisper.lock}
        ''}

        if [ ! -f "${cfg.dataDir}/app.db" ]; then
          echo "Running first-time Odysseus setup..."
          PYTHONPATH="${package}/lib/odysseus:${cfg.dataDir}/venv/lib/python3.12/site-packages" \
            "${cfg.dataDir}/venv/bin/python" \
            ${package}/lib/odysseus/setup.py
        fi
      '';
    };
  };
}
