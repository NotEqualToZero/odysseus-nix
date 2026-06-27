# Odysseus — NixOS module.
#
# Runs the Odysseus web UI as a systemd service.
#
# Backend model servers (llama.cpp, vllm, etc.) are NOT managed here.
# Add them to `backendPackages` to put them on PATH for the Odysseus
# cookbook to launch on demand, or point `extraEnv` at services already
# running on the system (Ollama, OpenAI-compatible APIs, etc.).

{ lib
, odysseus
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
    inherit lib pkgs odysseus;
    extras = moduleExtras;
  };

  inherit (built) package pythonEnv bootstrapPackages;

  bootstrapArgs = lib.concatStringsSep " "
    (map lib.escapeShellArg bootstrapPackages);

  # PATH entries for backend packages (llama-cpp, vllm, etc.)
  backendBinPaths = lib.concatStringsSep ":"
    (map (p: "${p}/bin") cfg.backendPackages);

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
        Path to a file containing secret environment variables (API keys, etc.).
        See the bundled .env.example for available options.
      '';
    };

    extraEnv = lib.mkOption {
      type    = lib.types.attrsOf lib.types.str;
      default = {};
      example = {
        OLLAMA_BASE_URL  = "http://127.0.0.1:11434";
        OPENAI_API_BASE  = "http://127.0.0.1:8080/v1";
        OPENAI_API_KEY   = "sk-local";
      };
      description = ''
        Extra environment variables passed to the Odysseus service.
        Use this to point Odysseus at model servers already running on
        the system — Ollama, llama-server, vllm, LM Studio, etc.
      '';
    };

    backendPackages = lib.mkOption {
      type    = lib.types.listOf lib.types.package;
      default = [];
      example = lib.literalExpression "[ pkgs.llama-cpp ]";
      description = ''
        Packages placed on PATH inside the Odysseus service, making their
        binaries available for the cookbook to launch on demand (e.g.
        llama-server, vllm). These are not managed as separate services —
        the cookbook starts and stops them via tmux sessions.

        GPU variants can be passed directly:
          pkgs.llama-cpp.override { vulkanSupport = true; }
          pkgs.llama-cpp.override { rocmSupport = true; }
      '';
    };

    optionalDeps = {
      whisper = lib.mkOption {
        type        = lib.types.bool;
        default     = false;
        description = "Install faster-whisper for local speech-to-text.";
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

    # Cookbook-generated runner scripts use a hardcoded #!/bin/bash shebang.
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

        # KillMode=process leaves cookbook tmux sessions (and their model
        # server children) alive when the web UI is restarted.
        KillMode = "process";

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
          echo "Creating mutable venv..."
          ${pkgs.uv}/bin/uv venv \
            --python ${pythonEnv}/bin/python \
            --system-site-packages \
            --seed \
            ${cfg.dataDir}/venv
        fi

        echo "Ensuring bootstrap packages: ${bootstrapArgs}"
        ${pkgs.uv}/bin/uv pip install \
          --python "${cfg.dataDir}/venv/bin/python" \
          ${bootstrapArgs} || \
          echo "WARNING: bootstrap package install failed (will retry next start)"

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
