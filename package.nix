# Odysseus package — nixpkgs python3.withPackages, no uv2nix, no patching.
#
# Core deps that exist in nixpkgs are baked into an immutable Python env.
# The mutable venv (bootstrapped in module.nix preStart) handles packages
# not in nixpkgs; its contents are pinned in requirements.lock.
#
# Returns { package; pythonEnv; }.

{ lib
, pkgs
, odysseus              # upstream source — path from npins or user override
, extras ? []           # optional groups: "whisper" "duckduckgo" "mupdf" "markitdown"
}:

let
  python = pkgs.python312;

  corePkgs = ps: with ps; [
    fastapi
    uvicorn
    python-multipart
    python-dotenv
    httpx
    pydantic
    pydantic-settings
    sqlalchemy
    pypdf
    beautifulsoup4
    charset-normalizer
    numpy
    markdown
    nh3
    icalendar
    python-dateutil
    caldav
    cryptography
    bcrypt
    pyotp
    qrcode
    mcp
    croniter
    chromadb
    fastembed
    huggingface-hub
    pip
  ];

  optionalPkgs = ps:
    lib.optionals (builtins.elem "duckduckgo" extras) [ ps.ddgs      ] ++
    lib.optionals (builtins.elem "mupdf"      extras) [ ps.pymupdf   ] ++
    lib.optionals (builtins.elem "markitdown" extras) [ ps.markitdown ];

  pythonEnv = python.withPackages (ps: corePkgs ps ++ optionalPkgs ps);

  package = pkgs.stdenv.mkDerivation {
    pname   = "odysseus";
    version = "0-unstable";
    src     = odysseus;

    nativeBuildInputs = [ pkgs.makeWrapper ];
    buildInputs       = [ pythonEnv ];
    dontBuild         = true;

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
      description = "Self-hosted AI assistant UI";
      license     = licenses.mit;
      platforms   = platforms.unix;
      mainProgram = "odysseus";
    };
  };

in {
  inherit package pythonEnv;
}
