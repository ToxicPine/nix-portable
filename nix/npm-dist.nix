{
  lib,
  runCommand,
  nixPortableX64,
  nixPortableArm64,
  version,
}:
let
  scope = "@cardelli";
  metaPackage = "nix";
  launcher = ../npm/nix/bin/nix.js;

  packageJson = attrs: builtins.toJSON attrs;

  platformPackages = [
    {
      packageName = "nix-linux-x64";
      description = "Linux x64 nix-portable binary for ${scope}/${metaPackage}.";
      os = "linux";
      cpu = "x64";
      payload = {
        type = "copy";
        path = "${nixPortableX64}/bin/nix-portable";
      };
    }
    {
      packageName = "nix-linux-arm64";
      description = "Linux arm64 nix-portable binary for ${scope}/${metaPackage}.";
      os = "linux";
      cpu = "arm64";
      payload = {
        type = "copy";
        path = "${nixPortableArm64}/bin/nix-portable";
      };
    }
    {
      packageName = "nix-darwin-x64";
      description = "macOS x64 native Nix shim for ${scope}/${metaPackage}.";
      os = "darwin";
      cpu = "x64";
      payload = {
        type = "native-nix-shim";
      };
      readme = ''
        # ${scope}/nix-darwin-x64

        This package is a macOS test shim for `${scope}/${metaPackage}`. It does
        not contain a self-contained nix-portable payload. It requires a native
        Nix installation on the Mac and dispatches to `nix`, `nix-shell`, and
        the other installed Nix tools from `PATH`.
      '';
    }
    {
      packageName = "nix-darwin-arm64";
      description = "macOS arm64 native Nix shim for ${scope}/${metaPackage}.";
      os = "darwin";
      cpu = "arm64";
      payload = {
        type = "native-nix-shim";
      };
      readme = ''
        # ${scope}/nix-darwin-arm64

        This package is a macOS test shim for `${scope}/${metaPackage}`. It does
        not contain a self-contained nix-portable payload. It requires a native
        Nix installation on the Mac and dispatches to `nix`, `nix-shell`, and
        the other installed Nix tools from `PATH`.
      '';
    }
  ];

  optionalDependencies = lib.listToAttrs (map (platform:
    lib.nameValuePair "${scope}/${platform.packageName}" version
  ) platformPackages);

  packageFiles = platform:
    [ "bin/nix-portable" ] ++ lib.optional (platform ? readme) "README.md";

  nativeNixShim = ''#!/usr/bin/env sh
    set -e

    tool="''${1:-nix}"
    case "$tool" in
      nix*)
        shift || true
        ;;
      *)
        tool="nix"
        ;;
    esac

    if ! command -v "$tool" >/dev/null 2>&1; then
      if [ "$tool" = "nix" ]; then
        echo "${scope}/${metaPackage} on macOS requires a native Nix installation in PATH." >&2
      else
        echo "${scope}/${metaPackage} on macOS requires '$tool' from a native Nix installation in PATH." >&2
      fi
      echo "Install Nix from https://nixos.org/download/ or ensure the Nix profile is loaded." >&2
      exit 1
    fi

    exec "$tool" "$@"
  '';

  writePayload = platform:
    if platform.payload.type == "copy" then ''
      cp ${platform.payload.path} "$out/packages/${platform.packageName}/bin/nix-portable"
    '' else if platform.payload.type == "native-nix-shim" then ''
      cat > "$out/packages/${platform.packageName}/bin/nix-portable" <<'SH'
${nativeNixShim}
SH
    '' else
      throw "unsupported npm platform payload type ${platform.payload.type}";

  writeReadme = platform:
    lib.optionalString (platform ? readme) ''
      cat > "$out/packages/${platform.packageName}/README.md" <<'EOF'
${platform.readme}
EOF
    '';

  writePlatformPackage = platform: ''
    mkdir -p "$out/packages/${platform.packageName}/bin"
${writePayload platform}
    chmod 755 "$out/packages/${platform.packageName}/bin/nix-portable"
    cat > "$out/packages/${platform.packageName}/package.json" <<'JSON'
${packageJson {
  name = "${scope}/${platform.packageName}";
  inherit version;
  inherit (platform) description;
  license = "MIT";
  os = [ platform.os ];
  cpu = [ platform.cpu ];
  files = packageFiles platform;
}}
JSON
${writeReadme platform}
  '';

  publishOrder = lib.concatMapStringsSep "\n" (platform:
    "  - packages/${platform.packageName}"
  ) platformPackages;

  bins = {
    nix = "bin/nix.js";
    nix-portable = "bin/nix.js";
    nix-build = "bin/nix.js";
    nix-channel = "bin/nix.js";
    nix-collect-garbage = "bin/nix.js";
    nix-copy-closure = "bin/nix.js";
    nix-daemon = "bin/nix.js";
    nix-env = "bin/nix.js";
    nix-hash = "bin/nix.js";
    nix-instantiate = "bin/nix.js";
    nix-prefetch-url = "bin/nix.js";
    nix-shell = "bin/nix.js";
    nix-store = "bin/nix.js";
  };
in
runCommand "nix-portable-npm-dist-${version}" {} ''
  mkdir -p "$out/packages/${metaPackage}/bin"
  cp ${launcher} "$out/packages/${metaPackage}/bin/nix.js"
  chmod 755 "$out/packages/${metaPackage}/bin/nix.js"
  cat > "$out/packages/${metaPackage}/package.json" <<'JSON'
${packageJson {
  name = "${scope}/${metaPackage}";
  inherit version;
  description = "Run nix-portable from npm on Linux, or native Nix from npm on macOS.";
  license = "MIT";
  repository = {
    type = "git";
    url = "git+https://github.com/DavHau/nix-portable.git";
  };
  homepage = "https://github.com/DavHau/nix-portable#readme";
  bugs = {
    url = "https://github.com/DavHau/nix-portable/issues";
  };
  bin = bins;
  files = [
    "bin/nix.js"
  ];
  inherit optionalDependencies;
}}
JSON

${lib.concatMapStringsSep "\n" writePlatformPackage platformPackages}

  cat > "$out/README.md" <<'EOF'
This directory is generated by `nix build .#npm-dist`.

Publish platform packages first:
${publishOrder}

Then publish:
- packages/nix
EOF
''
