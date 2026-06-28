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

  # libstdc++ (always needed by pip-installed native extensions like torch/vllm)
  # plus /run/opengl-driver/lib which NixOS populates for all GPU vendors via
  # hardware.opengl — covers AMD ROCm, Intel compute, and NVIDIA CUDA.
  # amdsmi is included when available so pip-installed vLLM can find libamd_smi.so
  # (its Python wrapper hardcodes /opt/rocm/lib which doesn't exist on NixOS).
  amdSmiLib = lib.optionalString
    (pkgs ? rocmPackages && pkgs.rocmPackages ? amdsmi)
    "${pkgs.rocmPackages.amdsmi}/lib";

  ldLibraryPath = lib.concatStringsSep ":" (
    lib.filter (s: s != "") [
      "${pkgs.stdenv.cc.cc.lib}/lib"
      "/run/opengl-driver/lib"
      # libdrm_amdgpu.so.1 — needed by Triton/ROCm; not in opengl-driver on all configs
      "${pkgs.libdrm}/lib"
      amdSmiLib
    ] ++ cfg.extraLibPaths
  );

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

    extraLibPaths = lib.mkOption {
      type    = lib.types.listOf lib.types.str;
      default = [];
      example = lib.literalExpression ''[ "\${pkgs.cudaPackages.cudatoolkit}/lib" ]'';
      description = ''
        Extra paths appended to LD_LIBRARY_PATH inside the service.
        libstdc++ and /run/opengl-driver/lib are always included (covers
        AMD ROCm, Intel, and NVIDIA via hardware.opengl). Use this for
        anything vendor-specific not covered by the opengl-driver path.
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
      isNormalUser  = true;
      home          = cfg.dataDir;
      createHome    = true;
      group         = cfg.group;
      # render + video give access to /dev/dri (all GPU vendors) and /dev/kfd (AMD ROCm)
      extraGroups   = [ "render" "video" ];
      shell         = pkgs.bash;
      description   = "Odysseus service user";
    };

    users.groups.${cfg.group} = {};

    # Cookbook runner scripts use a hardcoded #!/bin/bash shebang.
    system.activationScripts.odysseusBinBash = ''
      mkdir -p /bin
      ln -sf ${pkgs.bash}/bin/bash /bin/bash
    '';

    # Symlink libamd_smi.so to the path pip-installed amdsmi checks first.
    system.activationScripts.odysseusGpuLibs =
      lib.mkIf (pkgs ? rocmPackages && pkgs.rocmPackages ? amdsmi) ''
        mkdir -p /opt/rocm/lib
        ln -sf ${pkgs.rocmPackages.amdsmi}/lib/libamd_smi.so /opt/rocm/lib/libamd_smi.so
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
        LD_LIBRARY_PATH            = ldLibraryPath;
        # Bash sources $BASH_ENV for every non-interactive invocation, so tmux-spawned
        # cookbook commands (bash -c "vllm serve ...") inherit LD_LIBRARY_PATH even
        # when the shell doesn't source .bashrc or .profile.
        BASH_ENV                   = "${cfg.dataDir}/.gpu_env";
      } // cfg.extraEnv;

      serviceConfig = {
        Type             = "simple";
        User             = cfg.user;
        Group            = cfg.group;
        WorkingDirectory = cfg.dataDir;

        ExecStart = pkgs.writeShellScript "odysseus-start" ''
          VENV_SITE="${cfg.dataDir}/venv/lib/python3.12/site-packages"
          export VIRTUAL_ENV="${cfg.dataDir}/venv"
          export PATH="${cfg.dataDir}/wrappers:${cfg.dataDir}/venv/bin:${package}/bin:${pkgs.uv}/bin:${pkgs.tmux}/bin:${pythonEnv}/bin${lib.optionalString (cfg.backendPackages != []) ":${backendBinPaths}"}:/run/current-system/sw/bin:$PATH"
          export PYTHONPATH="${package}/lib/odysseus:$VENV_SITE:${pythonEnv}/lib/python3.12/site-packages"
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
        PrivateDevices  = false;   # must be false to reach GPU nodes
        ProtectSystem   = "strict";
        ReadWritePaths  = [ cfg.dataDir "/tmp" ];
        ProtectHome     = true;
        # Allow access to GPU devices across vendors:
        #   /dev/dri/*        — DRM render nodes (AMD/Intel/NVIDIA)
        #   /dev/kfd          — AMD ROCm compute
        #   /dev/nvidia*      — NVIDIA GPU + UVM + control
        DeviceAllow = [
          "char-drm:* rw"
          "/dev/kfd rw"
          "/dev/nvidiactl rw"
          "/dev/nvidia-uvm rw"
          "/dev/nvidia-uvm-tools rw"
          "/dev/nvidia0 rw"
          "/dev/nvidia1 rw"
          "/dev/nvidia2 rw"
          "/dev/nvidia3 rw"
        ];
      };

      preStart = ''
        mkdir -p ${cfg.dataDir}/.cache/huggingface/hub
        mkdir -p ${cfg.dataDir}/tmux
        mkdir -p ${cfg.dataDir}/logs

        chown ${cfg.user}:${cfg.group} ${cfg.dataDir}
        chown -R ${cfg.user}:${cfg.group} ${cfg.dataDir}/.cache

        # Regenerate .gpu_env so BASH_ENV picks up current nix store paths after rebuild
        echo "export LD_LIBRARY_PATH=${ldLibraryPath}:''${LD_LIBRARY_PATH:-}" > "${cfg.dataDir}/.gpu_env"
        chown ${cfg.user}:${cfg.group} "${cfg.dataDir}/.gpu_env"

        # vllm wrapper: bakes LD_LIBRARY_PATH directly into the script so the correct
        # GPU libs (libdrm, amdsmi) are loaded regardless of how the caller's env looks.
        # Placed in wrappers/ which is prepended to PATH, so it intercepts all vllm calls.
        mkdir -p "${cfg.dataDir}/wrappers"
        cat > "${cfg.dataDir}/wrappers/vllm" <<'VLLMWRAPPER'
#!/bin/sh
export LD_LIBRARY_PATH="${ldLibraryPath}:''${LD_LIBRARY_PATH:-}"
exec "${cfg.dataDir}/venv/bin/vllm" "$@"
VLLMWRAPPER
        chmod +x "${cfg.dataDir}/wrappers/vllm"
        chown -R ${cfg.user}:${cfg.group} "${cfg.dataDir}/wrappers"

        # Patch torch's C extension RPATH so it finds libstdc++/libdrm without
        # LD_LIBRARY_PATH (which doesn't reach the cookbook's inline Python exec).
        # patchelf --add-rpath is safe and idempotent on repeated runs.
        TORCH_C="${cfg.dataDir}/venv/lib/python3.12/site-packages/torch"
        if [ -d "$TORCH_C" ]; then
          EXTRA_RPATH="${pkgs.stdenv.cc.cc.lib}/lib:${pkgs.libdrm}/lib:/opt/rocm/lib"
          find "$TORCH_C" -name "*.so" -o -name "*.so.*" 2>/dev/null | while read -r so; do
            ${pkgs.patchelf}/bin/patchelf --add-rpath "$EXTRA_RPATH" "$so" 2>/dev/null || true
          done
        fi

        chown -R ${cfg.user}:${cfg.group} ${cfg.dataDir}/tmux
        chown -R ${cfg.user}:${cfg.group} ${cfg.dataDir}/logs

        # Recreate if missing or if previously created with --system-site-packages or uv
        # (we now use an isolated venv and expose nixpkgs packages via PYTHONPATH instead)
        if [ ! -f "${cfg.dataDir}/venv/pyvenv.cfg" ] || \
           grep -q "^creator = uv\|^include-system-site-packages = true" "${cfg.dataDir}/venv/pyvenv.cfg" 2>/dev/null; then
          echo "Creating mutable venv..."
          rm -rf "${cfg.dataDir}/venv"
          ${pythonEnv}/bin/python -m venv ${cfg.dataDir}/venv
          chown -R ${cfg.user}:${cfg.group} ${cfg.dataDir}/venv
        fi

        # Remove EXTERNALLY-MANAGED so cookbook pip installs work at runtime
        rm -f "${cfg.dataDir}/venv/lib/python3.12/EXTERNALLY-MANAGED"

        echo "Installing pinned bootstrap packages..."
        "${cfg.dataDir}/venv/bin/python" -m pip install \
          --require-hashes \
          -r ${./requirements.lock}

        ${lib.optionalString cfg.optionalDeps.whisper ''
          echo "Installing faster-whisper..."
          "${cfg.dataDir}/venv/bin/python" -m pip install \
            --require-hashes \
            -r ${./requirements-whisper.lock}
        ''}

        if [ ! -f "${cfg.dataDir}/app.db" ]; then
          echo "Running first-time Odysseus setup..."
          PYTHONPATH="${package}/lib/odysseus:${cfg.dataDir}/venv/lib/python3.12/site-packages:${pythonEnv}/lib/python3.12/site-packages" \
            "${cfg.dataDir}/venv/bin/python" \
            ${package}/lib/odysseus/setup.py
        fi
      '';
    };
  };
}
