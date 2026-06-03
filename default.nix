{
  bwrap,
  nix,
  proot,
  unzip,
  zip,
  unixtools,
  stdenv,
  buildPackages,
  upx,

  busybox,
  cacert ? pkgs.cacert,
  compression ? "zstd -19 -T0",
  lib ? pkgs.lib,
  perl ? pkgs.perl,
  pkgs ? import <nixpkgs> {},
  zstd ? pkgs.pkgsStatic.zstd,
  zstdBuild ? buildPackages.zstd,
  zipBuild ? buildPackages.zip,
  unzipBuild ? buildPackages.unzip,
  unixtoolsBuild ? buildPackages.unixtools,
  nixStatic,
  bundledPackage ? null,
  ...
}@inp:
let
  pname =
    if bundledPackage == null
    then "nix-portable"
    else lib.getName bundledPackage;

  bundledExe =
    if bundledPackage == null
    then ""
    else lib.getExe bundledPackage;

  nixpkgsSrc = pkgs.path;

  # git must run inside the portable store unless NP_GIT supplies an override.
  gitAttribute = "gitMinimal";
  git = pkgs.${gitAttribute};

  zipPath = path: lib.removePrefix "/" (toString path);
  storeSubpath = path: lib.removePrefix "/nix/store" (toString path);

  maketar = targets:
    let
      closureInfo = buildPackages.closureInfo { rootPaths = targets; };
    in
      stdenv.mkDerivation {
        name = "nix-portable-store-tarball";
        nativeBuildInputs = [ perl zstdBuild ];
        exportReferencesGraph = map (x: [ ("closure-" + baseNameOf x) x ]) targets;
        buildCommand = ''
          storePaths=$(cat ${closureInfo}/store-paths)
          mkdir "$out"
          echo "$storePaths" > "$out/index"
          cp -r ${closureInfo} "$out/closureInfo"

          tar -cf - \
            --owner=0 --group=0 --mode=u+rw,uga+r \
            --hard-dereference \
            $storePaths | ${compression} > "$out/tar"
        '';
      };

  packStaticBin = binPath:
    let
      binName = baseNameOf binPath;
    in
      pkgs.runCommand binName { nativeBuildInputs = [ upx ]; } ''
        mkdir -p "$out/bin"
        upx -9 -o "$out/bin/${binName}" ${binPath}
      '';

  caBundleZstd = pkgs.runCommand "cacerts" {} ''
    ${zstdBuild}/bin/zstd -19 < ${cacert}/etc/ssl/certs/ca-bundle.crt > "$out"
  '';

  packedBwrap = packStaticBin "${inp.bwrap}/bin/bwrap";
  packedNixStatic = packStaticBin "${inp.nixStatic}/bin/nix";
  packedProot = packStaticBin "${inp.proot}/bin/proot";
  packedZstd = packStaticBin "${inp.zstd}/bin/zstd";

  storeTar = maketar ([ cacert nix nixpkgsSrc ] ++ lib.optional (bundledPackage != null) bundledPackage);

  runtimeScript = stdenv.mkDerivation {
    name = "${pname}-runtime.sh";
    src = ./runtime/runtime.sh.in;
    dontUnpack = true;
    buildCommand = ''
      cp "$src" "$out"

      busyboxBins=$(
        cd ${busybox}/bin
        for bin in *; do
          if [ -L "$bin" ]; then
            printf '%q ' "$bin"
          fi
        done
      )

      substituteInPlace "$out" \
        --replace-fail '@busyboxBins@' "$busyboxBins" \
        --replace-fail '@zstdZipPath@' '${zipPath "${packedZstd}/bin/zstd"}' \
        --replace-fail '@prootZipPath@' '${zipPath "${packedProot}/bin/proot"}' \
        --replace-fail '@bwrapZipPath@' '${zipPath "${packedBwrap}/bin/bwrap"}' \
        --replace-fail '@nixStaticZipPath@' '${zipPath "${packedNixStatic}/bin/nix"}' \
        --replace-fail '@caBundleZipPath@' '${zipPath caBundleZstd}' \
        --replace-fail '@nixStoreSubpath@' '${storeSubpath nix}' \
        --replace-fail '@nixpkgsSrc@' '${nixpkgsSrc}' \
        --replace-fail '@storeIndexZipPath@' '${zipPath "${storeTar}/index"}' \
        --replace-fail '@storeTarZipPath@' '${zipPath "${storeTar}/tar"}' \
        --replace-fail '@storeRegistrationZipPath@' '${zipPath "${storeTar}/closureInfo/registration"}' \
        --replace-fail '@bundledExe@' '${bundledExe}' \
        --replace-fail '@gitStoreSubpath@' '${storeSubpath git.out}' \
        --replace-fail '@gitAttribute@' '${gitAttribute}' \
        --replace-fail '@gitOut@' '${git.out}'

      base64 ${busybox}/bin/busybox > busybox.b64
      sed -i '/^@busyboxBase64@$/{
        r busybox.b64
        d
      }' "$out"
    '';
  };

  nixPortable = pkgs.runCommand pname { nativeBuildInputs = [ unixtoolsBuild.xxd unzipBuild ]; } ''
    mkdir -p "$out/bin"
    cp ${runtimeScript} "$out/bin/nix-portable.zip"
    chmod +w "$out/bin/nix-portable.zip"

    sizeA=$(printf "%08x" "$(stat -c "%s" "$out/bin/nix-portable.zip")" | tac -rs ..)
    echo 504b 0304 0000 0000 0000 0000 0000 0000 | xxd -r -p >> "$out/bin/nix-portable.zip"
    echo 0000 0000 0000 0000 0000 0200 0000 4242 | xxd -r -p >> "$out/bin/nix-portable.zip"

    sizeB=$(printf "%08x" "$(stat -c "%s" "$out/bin/nix-portable.zip")" | tac -rs ..)
    echo 504b 0102 0000 0000 0000 0000 0000 0000 | xxd -r -p >> "$out/bin/nix-portable.zip"
    echo 0000 0000 0000 0000 0000 0000 0200 0000 | xxd -r -p >> "$out/bin/nix-portable.zip"
    echo 0000 0000 0000 0000 0000 "$sizeA" 4242 | xxd -r -p >> "$out/bin/nix-portable.zip"

    echo 504b 0506 0000 0000 0000 0100 3000 0000 | xxd -r -p >> "$out/bin/nix-portable.zip"
    echo "$sizeB" 0000 0000 0000 0000 0000 0000 | xxd -r -p >> "$out/bin/nix-portable.zip"

    unzip -vl "$out/bin/nix-portable.zip"

    zip="${zipBuild}/bin/zip -0"
    $zip "$out/bin/nix-portable.zip" ${packedBwrap}/bin/bwrap
    $zip "$out/bin/nix-portable.zip" ${packedNixStatic}/bin/nix
    $zip "$out/bin/nix-portable.zip" ${packedProot}/bin/proot
    $zip "$out/bin/nix-portable.zip" ${packedZstd}/bin/zstd
    $zip "$out/bin/nix-portable.zip" ${storeTar}/index
    $zip "$out/bin/nix-portable.zip" ${storeTar}/tar
    $zip "$out/bin/nix-portable.zip" ${storeTar}/closureInfo/registration
    $zip "$out/bin/nix-portable.zip" ${caBundleZstd}

    fp=$(sha256sum "$out/bin/nix-portable.zip" | cut -d " " -f 1)
    sed -i "s/_FINGERPRINT_PLACEHOLDER_/$fp/g" "$out/bin/nix-portable.zip"

    ${zipBuild}/bin/zip -F "$out/bin/nix-portable.zip" --out "$out/bin/nix-portable-fixed.zip"

    rm "$out/bin/nix-portable.zip"
    executable='${bundledExe}'
    if [ "$executable" = "" ]; then
      target="$out/bin/nix-portable"
    else
      target="$out/bin/$(basename "$executable")"
    fi
    mv "$out/bin/nix-portable-fixed.zip" "$target"
    chmod +x "$target"
  '';
in
  nixPortable.overrideAttrs (prev: {
    passthru = (prev.passthru or {}) // {
      inherit packedBwrap packedProot runtimeScript;
      bwrap = packedBwrap;
      proot = packedProot;
    };
  })
