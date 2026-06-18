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

  # llama-cpp build selected by cfg.gpuBackend:
  #   "cpu"    — nixpkgs default, CPU only
  #   "vulkan" — Vulkan backend (works well on the 7900XTX, sidesteps the
  #              ROCm/HSA enumeration problems on Strix Point APUs)
  #   "rocm"   — HIP/ROCm backend (only if ROCm enumerates the GPU)
  llamaCpp =
    if cfg.gpuBackend == "vulkan" then
      pkgs.llama-cpp.override { vulkanSupport = true; }
    else if cfg.gpuBackend == "rocm" then
      pkgs.llama-cpp.override { rocmSupport = true; }
    else
      pkgs.llama-cpp;

in {

  options.services.odysseus = {
    enable = lib.mkEnableOption "Odysseus AI assistant UI";

    gpuBackend = lib.mkOption {
      type        = lib.types.enum [ "cpu" "vulkan" "rocm" ];
      default     = "cpu";
      description = ''
        GPU backend for the bundled llama-cpp (llama-server) used by the
        Cookbook to serve models.
          "cpu"    — CPU only (default).
          "vulkan" — Vulkan backend. Recommended for AMD GPUs on new APU
                     platforms (e.g. Strix Point) where ROCm/HSA fails to
                     enumerate. Works well on RDNA3 cards like the 7900XTX.
          "rocm"   — HIP/ROCm backend. Only use if `rocminfo` successfully
                     lists your GPU.
      '';
    };

    gpuDeviceIndex = lib.mkOption {
      type        = lib.types.nullOr lib.types.int;
      default     = null;
      example     = 0;
      description = ''
        Which GPU the Vulkan/ROCm backend should use, when more than one is
        present (e.g. a discrete 7900XTX alongside an integrated GPU).
        For Vulkan this sets GGML_VK_VISIBLE_DEVICES; for ROCm it sets
        ROCR_VISIBLE_DEVICES / HIP_VISIBLE_DEVICES. Find the index with
        `vulkaninfo --summary` (Vulkan) or `rocminfo` (ROCm). null = let the
        backend pick.
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
      # GPU access for the Vulkan/ROCm llama-server. /dev/dri/render* is
      # render-group; /dev/kfd (ROCm) and card nodes are video/render.
      extraGroups  = lib.optionals (cfg.gpuBackend != "cpu") [ "render" "video" ];
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

    environment.systemPackages = [ pkgs.tmux llamaCpp pkgs.uv ];

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
      } // lib.optionalAttrs (cfg.gpuBackend == "vulkan") {
        # Force ONLY the RADV (AMD) Vulkan ICD. The NixOS driver directory
        # ships ICDs for every Mesa driver (freedreno/Turnip, panfrost, etc.);
        # without pinning, llama-cpp's Vulkan backend tries them all, hits the
        # wrong driver on the AMD render nodes, and falls back to llvmpipe (CPU).
        VK_ICD_FILENAMES =
          "/run/opengl-driver/share/vulkan/icd.d/radeon_icd.x86_64.json";
      } // lib.optionalAttrs (cfg.gpuBackend == "vulkan" && cfg.gpuDeviceIndex != null) {
        # Restrict the Vulkan backend to the chosen GPU. With only RADV loaded,
        # index 0 is typically the discrete 7900XTX and 1 the integrated 890M —
        # confirm with `vulkaninfo --summary` (RADV-only) and set accordingly.
        GGML_VK_VISIBLE_DEVICES = toString cfg.gpuDeviceIndex;
      } // lib.optionalAttrs (cfg.gpuBackend == "rocm" && cfg.gpuDeviceIndex != null) {
        ROCR_VISIBLE_DEVICES = toString cfg.gpuDeviceIndex;
        HIP_VISIBLE_DEVICES  = toString cfg.gpuDeviceIndex;
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

          export VIRTUAL_ENV="${cfg.dataDir}/venv"
          export PATH="${cfg.dataDir}/venv/bin:${package}/bin:${pkgs.uv}/bin:${pkgs.tmux}/bin:${llamaCpp}/bin:${pythonEnv}/bin:/run/current-system/sw/bin:$PATH"
          export PYTHONPATH="${package}/lib/odysseus:$VENV_SITE"

          # Run uvicorn from the VENV python, not the nixpkgs-env python.
          # The venv is created with --system-site-packages so it can import
          # all the core deps from the immutable nixpkgs env, AND because it's
          # a real venv, `sys.prefix != sys.base_prefix` is true. Odysseus's
          # cookbook helper checks exactly that to decide whether to pip-install
          # into the venv vs. fall back to a `--user` install. nixpkgs Python
          # disables user-site, so the --user path errors; running as the venv
          # python makes Odysseus correctly choose the venv-install path.
          exec "${cfg.dataDir}/venv/bin/python" -m uvicorn app:app \
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

        # GPU access for the Vulkan/ROCm llama-server. Only applied when a GPU
        # backend is selected. PrivateDevices stays off so /dev/dri and /dev/kfd
        # remain visible; the render nodes are allowed explicitly and the
        # process is granted render/video supplementary groups.
        PrivateDevices = lib.mkIf (cfg.gpuBackend != "cpu") false;
        DeviceAllow = lib.mkIf (cfg.gpuBackend != "cpu") [
          "/dev/dri rw"
          "/dev/kfd rw"
        ];
        SupplementaryGroups =
          lib.mkIf (cfg.gpuBackend != "cpu") [ "render" "video" ];
      };

      preStart = ''
        chown -R ${cfg.user}:${cfg.group} ${cfg.dataDir} || true
        mkdir -p ${cfg.dataDir}/.cache/huggingface/hub
        mkdir -p ${cfg.dataDir}/tmux
        mkdir -p ${cfg.dataDir}/logs

        # Create the mutable venv linked to the immutable nixpkgs env.
        # --seed installs pip/setuptools into the venv so the cookbook runner
        # scripts' `python3 -m pip install` works inside it. --system-site-
        # packages lets it import everything from the nixpkgs base env too.
        if [ ! -d "${cfg.dataDir}/venv" ]; then
          echo "Creating mutable venv (system-site-packages -> nixpkgs env, seeded with pip)..."
          ${pkgs.uv}/bin/uv venv \
            --python ${pythonEnv}/bin/python \
            --system-site-packages \
            --seed \
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
        # Run from the venv python (system-site-packages gives it the core
        # deps; being a venv keeps behaviour consistent with the main service).
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
