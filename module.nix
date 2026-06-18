# Odysseus — NixOS module.
#
# Module factory: takes the pinned flake inputs and returns a module function
# { config, pkgs, lib, ... }. flake.nix calls it; the flake-compat shim
# (default.nix) exposes the same output to non-flake consumers.
#
# Core deps come from nixpkgs (immutable, via package.nix). Packages missing
# from nixpkgs and all runtime cookbook installs live in a mutable uv venv at
# <dataDir>/venv, created on first boot.

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

  # Space-separated list for the uv install command in preStart
  bootstrapArgs = lib.concatStringsSep " "
    (map lib.escapeShellArg bootstrapPackages);

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
        description = ''
          Install faster-whisper for local CPU/GPU speech-to-text.
          (Installed into the mutable venv since it is not in nixpkgs.)
        '';
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

    # Cookbook-generated runner scripts (model downloads + serves) use a
    # hardcoded `#!/bin/bash` shebang. NixOS has no /bin/bash by default, so
    # detached tmux sessions fail with "bad interpreter: No such file or
    # directory" the instant they try to exec a runner. Providing the symlink
    # fixes both downloads and serves without patching upstream scripts.
    system.activationScripts.odysseusBinBash = ''
      mkdir -p /bin
      ln -sf ${pkgs.bash}/bin/bash /bin/bash
    '';

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
      } // cfg.extraEnv;

      serviceConfig = {
        Type             = "simple";
        User             = cfg.user;
        Group            = cfg.group;
        WorkingDirectory = cfg.dataDir;

        # The mutable venv is created with --system-site-packages so it sees
        # everything in the immutable nixpkgs env, then adds the missing +
        # runtime packages on top. We run uvicorn from the venv python so all
        # of it is importable.
        # The venv is built against the bare interpreter and only holds the
        # bootstrap + runtime-installed packages. uvicorn/fastapi/etc. live in
        # the immutable nixpkgs env (pythonEnv). So we run uvicorn FROM the
        # nixpkgs env python and append the venv's site-packages to PYTHONPATH,
        # making both sets importable in one interpreter.
        ExecStart = pkgs.writeShellScript "odysseus-start" ''
          VENV_SITE="${cfg.dataDir}/venv/lib/python3.12/site-packages"

          # NOTE: we deliberately do NOT `source venv/bin/activate` here.
          # Activating exports VIRTUAL_ENV/PATH in a way that cookbook tmux
          # sessions inherit, which makes the runner scripts' `deactivate`
          # call do real work and disrupts their environment. Instead we add
          # the venv site-packages to PYTHONPATH directly — same import
          # result, no activation side-effects leaking into child sessions.
          export PATH="${package}/bin:${pkgs.uv}/bin:${pkgs.tmux}/bin:${pkgs.llama-cpp}/bin:${pythonEnv}/bin:/run/current-system/sw/bin:$PATH"
          export PYTHONPATH="${package}/lib/odysseus:$VENV_SITE"

          exec ${pythonEnv}/bin/python -m uvicorn app:app \
            --host ${cfg.host} \
            --port ${toString cfg.port}
        '';

        EnvironmentFile = lib.mkIf (cfg.envFile != null) cfg.envFile;
        Restart         = "on-failure";
        RestartSec      = "5s";

        # Cookbook launches model serves and downloads in detached tmux
        # sessions. With the default KillMode=control-group, systemd reaps
        # every process in the service cgroup — including those tmux sessions —
        # which kills a running model serve. KillMode=process kills only the
        # main uvicorn process on stop/restart, leaving the tmux sessions
        # (and their llama-server children) alive.
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

        # Create the mutable venv linked to the immutable nixpkgs env.
        if [ ! -d "${cfg.dataDir}/venv" ]; then
          echo "Creating mutable venv (system-site-packages -> nixpkgs env)..."
          ${pkgs.uv}/bin/uv venv \
            --python ${pythonEnv}/bin/python \
            --system-site-packages \
            ${cfg.dataDir}/venv
        fi

        # Install packages missing from nixpkgs (+ whisper if enabled).
        # Idempotent: uv skips already-satisfied packages quickly.
        echo "Ensuring bootstrap packages: ${bootstrapArgs}"
        ${pkgs.uv}/bin/uv pip install \
          --python "${cfg.dataDir}/venv/bin/python" \
          ${bootstrapArgs} || \
          echo "WARNING: bootstrap package install failed (will retry next start)"

        # First-time app setup: DB, data dirs, auth.json.
        # Run from the nixpkgs env python (has sqlalchemy/bcrypt/etc.) with
        # the venv site-packages appended so any bootstrap deps are visible.
        if [ ! -f "${cfg.dataDir}/app.db" ]; then
          echo "Running first-time Odysseus setup..."
          PYTHONPATH="${package}/lib/odysseus:${cfg.dataDir}/venv/lib/python3.12/site-packages" \
            ${pythonEnv}/bin/python \
            ${package}/lib/odysseus/setup.py
        fi
      '';
    };
  };
}
