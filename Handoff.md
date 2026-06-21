# Odysseus Nix Module — Handoff

## 1. Overview
NixOS module packaging for the Odysseus AI agent framework.
Provides a declarative, reproducible way to deploy Odysseus as a
systemd service with GPU support.

## 2. Repository
- **Location:** `~/Projects/odysseus-nix`
- **Branch:** `dev` (main branch `master` mirrors it)
- **Remote:** local bare repo at `../odysseus-nix.git`
- **GitHub:** `NotEqualToZero/odysseus-nix` — not yet connected as remote

## 3. What's been done

### Module factory (`module.nix`)
- Full NixOS module with `lib.mkOption` declarations
- All 16 options defined with types, defaults, descriptions
- GPU backend selection via `services.odysseus.backend` (`cpu` | `vulkan` | `rocm`)
- Systemd service with `KillMode = "process"` (graceful shutdown for HMM)
- GPU PCI ID pinning via `MESA_VK_DEVICE_SELECT` / `ROCR_VISIBLE_DEVICES`
- Persistent state in `/var/lib/odysseus`
- `configuration.nix` snippet for users

### Package derivation (`package.nix`)
- `python3.withPackages` for immutable core (odps, dependencies)
- `uv venv --system-site-packages` for mutable model cache
- `/bin/bash` symlink for containers that lack it
- GPU package injection: `vulkan-tools`/`vulkan-loader` or `rocmPackages.*`

### Flake setup (`flake.nix` + `default.nix`)
- Exposes `nixosModules.default`
- Packages: `packages.x86_64-linux.default` and `packages.aarch64-linux.default`
- Flake-compat shim for non-flake Nix
- Supported systems: `x86_64-linux`, `aarch64-linux`, `aarch64-darwin`, `x86_64-darwin`

### Git history (14 commits on `dev`)
All commits are on `dev`, pushed to local bare remote.
`master` is identical to `dev` (same HEAD `556fae2`).

### Documentation (added 2026-06-21)
- **README.md** — comprehensive guide covering:
  - Flake-based and channel-based installation
  - All 16 module options with types/defaults
  - GPU backend comparison table
  - Architecture diagram (immutable vs mutable layers)
  - Key design decisions
  - File layout reference
- **LICENSE** — MIT, copyright NotEqualToZero

## 4. Next Steps
- [ ] Add integration tests
- [ ] Test in systemd-nspawn
- [ ] Verify GPU backend on nspawn
- [ ] Connect GitHub remote and open PR from `dev`

## 5. Key Decisions to Preserve
1. **Venv strategy** — `withPackages` for core deps + `uv venv --system-site-packages` for mutable state; don't conflate
2. **GPU pinning** — use `PCI_ID` env vars, not device paths
3. **KillMode** — `"process"` (not `"control-group"`) for graceful shutdown
4. **Bash symlink** — required for containers; `stdenv.mkDerivation { buildCommand = ...; }`
5. **Backend enum** — `"cpu" | "vulkan" | "rocm"` with `assert` gate

## 6. Known Issues
- ROCm backend not tested on NixOS yet
- No `flake.lock` checked in (generated at build time)
- No integration test suite
