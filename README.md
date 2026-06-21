# odysseus-nix

NixOS module and Nix packaging for the [Odysseus](https://github.com/pewdiepie-archdaemon/odysseus) AI assistant UI.

[![NixOS Unstable](https://img.shields.io/badge/NixOS-26.05-blue.svg)](https://nixos.org)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Overview

This repository provides a declarative, zero-patch NixOS module for deploying Odysseus as a persistent systemd service. The packaging strategy uses an **immutable/mutable split**:

- **Immutable layer** — core Python deps from nixpkgs baked into a `python.withPackages` environment
- **Mutable layer** — packages missing from nixpkgs (`chromadb-client`, `youtube-transcript-api`, etc.) and runtime cookbook installs live in a `uv`-managed venv at `<dataDir>/venv`

This means the upstream Odysseus source needs **no patching** — the built-in `python3 -m pip install` cookbook scripts work unmodified.

## Quick Start

### Flake-based NixOS

```nix
{
  inputs.odysseus-nix.url = "github:NotEqualToZero/odysseus-nix";

  outputs = { self, nixpkgs, odysseus-nix, ... }: {
    nixosConfigurations."myhost" = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        {
          imports = [ odysseus-nix.nixosModules.default ];
          services.odysseus.enable = true;
        }
        # ... your other modules
      ];
    };
  };
}
```

### Non-flake (channel-based) NixOS

```nix
{
  imports = [
    (import (fetchTarball
      "https://github.com/NotEqualToZero/odysseus-nix/archive/master.tar.gz"
    )).nixosModules.default
  ];

  services.odysseus.enable = true;
}
```

### Direct build / run

```bash
# Build the package
nix build github:NotEqualToZero/odysseus-nix

# Run directly (for testing)
nix run github:NotEqualToZero/odysseus-nix
```

## Module Options

All options are under `services.odysseus.*`.

| Option | Type | Default | Description |
|---|---|---|---|
| `enable` | `bool` | `false` | Enable the Odysseus service |
| `gpuBackend` | `"cpu"` \| `"vulkan"` \| `"rocm"` | `"cpu"` | GPU backend for llama-cpp (model inference) |
| `gpuDeviceIndex` | `int \| null` | `null` | ROCm GPU index (multi-GPU) |
| `gpuPciId` | `str \| null` | `null` | PCI vendor:device ID for Vulkan GPU selection (e.g. `"1002:744c"`) |
| `host` | `str` | `"127.0.0.1"` | Bind address |
| `port` | `int` | `7000` | Bind port |
| `dataDir` | `path` | `"/var/lib/odysseus"` | Persistent data directory |
| `user` | `str` | `"odysseus"` | Service user |
| `group` | `str` | `"odysseus"` | Service group |
| `envFile` | `path \| null` | `null` | Path to `.env` file with secrets |
| `extraEnv` | `attrs` | `{}` | Additional environment variables |
| `optionalDeps.whisper` | `bool` | `false` | Install `faster-whisper` for local STT |
| `optionalDeps.duckduckgo` | `bool` | `false` | Install `ddgs` for search |
| `optionalDeps.mupdf` | `bool` | `false` | Install `PyMuPDF` for PDF handling |
| `optionalDeps.markitdown` | `bool` | `false` | Install `markitdown` for Office/EPUB extraction |

### GPU backends

| Backend | Use case | Notes |
|---|---|---|
| `cpu` | CPU-only inference | Default, works everywhere |
| `vulkan` | AMD/NVIDIA GPUs via Vulkan | **Recommended for AMD on Strix Point APUs** — avoids ROCm/HSA enumeration failures. Use `gpuPciId` to pin a specific GPU on mixed iGPU+dGPU systems. |
| `rocm` | AMD GPUs via HIP/ROCm | Only use if `rocminfo` lists your GPU |

### Example: AMD 7900 XTX with Vulkan

```nix
services.odysseus = {
  enable = true;
  gpuBackend = "vulkan";
  gpuPciId = "1002:744c";  # RX 7900 XTX
  port = 7000;
};
```

### Example: Full stack with Whisper

```nix
services.odysseus = {
  enable = true;
  gpuBackend = "vulkan";
  gpuPciId = "1002:744c";
  dataDir = "/var/lib/odysseus";

  optionalDeps = {
    whisper = true;
    duckduckgo = true;
  };

  extraEnv = {
    SEARXNG_INSTANCE = "http://localhost:8080";
    OLLAMA_HOST = "http://127.0.0.1:11434";
  };
};
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                   systemd service                       │
│                                                         │
│  ┌──────────────────┐    ┌──────────────────────────┐   │
│  │  Immutable layer  │    │    Mutable venv           │   │
│  │  (nixpkgs)        │    │    (<dataDir>/venv)       │   │
│  │                   │    │                           │   │
│  │  fastapi          │    │  chromadb-client          │   │
│  │  uvicorn          │    │  youtube-transcript-api   │   │
│  │  sqlalchemy       │    │  faster-whisper (opt)     │   │
│  │  chromadb         │    │  ddgs (opt)               │   │
│  │  mcp              │    │  markitdown (opt)         │   │
│  │  huggingface-hub  │    │  runtime cookbook installs │   │
│  │  pip              │    │                           │   │
│  └──────────────────┘    └──────────────────────────┘   │
│                                                         │
│  ┌──────────────────────────────────────────────────┐   │
│  │         Odysseus app (uvicorn + FastAPI)          │   │
│  │                                                   │   │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────────────┐  │   │
│  │  │ Cookbook   │ │ RAG/     │ │ Calendar/Email/  │  │   │
│  │  │ (models)  │ │ Embeddings│ │ Tasks/Research   │  │   │
│  │  │           │ │           │ │                  │  │   │
│  │  │ llama-    │ │           │ │                  │  │   │
│  │  │ server    │ │           │ │                  │  │   │
│  │  │ (tmux)    │ │           │ │                  │  │   │
│  │  └──────────┘ └──────────┘ └──────────────────┘  │   │
│  └──────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

### Key design decisions

- **Venv strategy** — The venv is created with `--system-site-packages --seed`, linking it to the immutable nixpkgs Python env. This lets Odysseus's built-in `pip install` scripts write into the venv while still importing nixpkgs packages.
- **`/bin/bash` symlink** — Odysseus cookbook runner scripts use `#!/bin/bash` shebangs. A system activation script provides `/bin/bash -> nix-bash` so detached tmux sessions work.
- **`KillMode=process`** — Systemd only kills the main uvicorn PID on stop/restart, leaving detached tmux model servers alive.
- **`MESA_VK_DEVICE_SELECT`** — For the Vulkan backend, RADV is pinned to a specific GPU by PCI ID rather than by index. This avoids mis-selection and hangs on mixed iGPU+dGPU systems.
- **`VK_ICD_FILENAMES`** — Pins Vulkan to the RADV (AMD) ICD only, preventing the NixOS driver directory from trying every Mesa Vulkan driver and falling back to llvmpipe.

## File Layout

```
├── flake.nix          Flake entry point (module + package outputs)
├── flake.lock         Pinned inputs (nixpkgs, odysseus, flake-compat)
├── default.nix        flake-compat shim for non-flake consumers
├── module.nix         NixOS module (service, user, GPU config, venv setup)
├── package.nix        Python package derivation (immutable env + bootstrap list)
└── README.md          This file
```

## Supported Systems

- `x86_64-linux`
- `aarch64-linux`
- `aarch64-darwin`
- `x86_64-darwin`

## Upstream

This packaging layer is designed to be **purely additive** — no patches to the upstream Odysseus source. The goal is a clean upstream PR.

- **Odysseus**: <https://github.com/pewdiepie-archdaemon/odysseus>
- **odysseus-nix**: <https://github.com/NotEqualToZero/odysseus-nix>

## License

MIT — see the [upstream license](https://github.com/pewdiepie-archdaemon/odysseus/blob/master/LICENSE) for details.
