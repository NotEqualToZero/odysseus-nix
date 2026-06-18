# Odysseus package — nixpkgs python3.withPackages, no uv2nix, no patching.
#
# Core dependencies that exist in nixpkgs are baked into an immutable Python
# environment here, including pip. Three packages missing from nixpkgs
# (chromadb-client, faster-whisper, youtube-transcript-api) plus any runtime
# cookbook installs (llama-cpp-python, etc.) are installed into a mutable
# venv at <dataDir>/venv — see module.nix preStart.
#
# The upstream cookbook scripts run `python3 -m pip install` into the active
# venv. Because pip is present in the env and $VIRTUAL_ENV points at the
# mutable venv, those installs land in the venv unmodified — so the upstream
# source needs NO patching. This keeps the packaging layer purely additive
# for a clean upstream PR.
#
# Returns { package; pythonEnv; bootstrapPackages; }.

{ lib
, pkgs
, odysseus              # upstream source (flake input)
, extras ? []           # optional groups: "whisper" "duckduckgo" "mupdf" "markitdown"
}:

let
  python = pkgs.python312;

  # ---------------------------------------------------------------- #
  # Core deps present in nixpkgs                                       #
  # ---------------------------------------------------------------- #
  corePkgs = ps: with ps; [
    # Web framework
    fastapi
    uvicorn
    python-multipart
    python-dotenv
    httpx
    pydantic
    pydantic-settings

    # Database
    sqlalchemy

    # Document / content handling
    pypdf
    beautifulsoup4
    charset-normalizer
    numpy
    markdown
    nh3

    # Calendar
    icalendar
    python-dateutil
    caldav

    # Auth / security
    cryptography
    bcrypt
    pyotp
    qrcode

    # MCP
    mcp

    # Scheduling
    croniter

    # RAG / embeddings (full chromadb provides chromadb.HttpClient,
    # the same import the lightweight chromadb-client exposes)
    chromadb
    fastembed

    # The `hf` CLI for cookbook model downloads
    huggingface-hub

    # pip: lets the upstream cookbook scripts run `python3 -m pip install`
    # into the active mutable venv without any source patching.
    pip

  ];

  # Optional groups that DO exist in nixpkgs — added to the immutable env
  # when their extra is enabled. (faster-whisper is missing, so it goes in
  # the bootstrap list below instead.)
  optionalPkgs = ps:
    lib.optionals (builtins.elem "duckduckgo" extras) [ ps.ddgs ] ++
    lib.optionals (builtins.elem "mupdf"      extras) [ ps.pymupdf ] ++
    lib.optionals (builtins.elem "markitdown" extras) [ ps.markitdown ];

  pythonEnv = python.withPackages (ps: corePkgs ps ++ optionalPkgs ps);

  # ---------------------------------------------------------------- #
  # Packages NOT in nixpkgs — installed into the mutable venv at      #
  # first boot. faster-whisper only when the whisper extra is on.    #
  # ---------------------------------------------------------------- #
  bootstrapPackages =
    [ "chromadb-client" "youtube-transcript-api" ] ++
    lib.optionals (builtins.elem "whisper" extras) [ "faster-whisper" ];

  package = pkgs.stdenv.mkDerivation {
    pname   = "odysseus";
    version = "0-unstable";
    src     = odysseus;

    nativeBuildInputs = [ pkgs.makeWrapper ];
    buildInputs       = [ pythonEnv ];
    dontBuild         = true;

    # No cookbook patching — upstream scripts run unmodified. The scripts'
    # `python3 -m pip install` works because pip is in pythonEnv and the
    # service activates the mutable venv ($VIRTUAL_ENV) before running them.
    installPhase = ''
      mkdir -p $out/lib/odysseus $out/bin
      cp -r . $out/lib/odysseus/
      [ -f _env ] && cp _env $out/lib/odysseus/.env.example || true

      makeWrapper ${pythonEnv}/bin/python $out/bin/odysseus \
        --add-flags "-m uvicorn app:app" \
        --add-flags "--host 127.0.0.1 --port 7000" \
        --set PYTHONPATH "$out/lib/odysseus" \
        --run 'cd "''${ODYSSEUS_HOME:-$HOME/.local/share/odysseus}"'

      makeWrapper ${pythonEnv}/bin/python $out/bin/odysseus-setup \
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
  inherit package pythonEnv bootstrapPackages;
}
