# nix-portable

Run Nix on Linux without root access or system configuration.

`nix-portable` is a self-extracting executable that carries Nix, a pinned
`nixpkgs`, static helper binaries, and a bootstrap store. On first use it
extracts into `$HOME/.nix-portable`, then runs Nix with the best available
runtime:

1. plain `nix --store`
2. Bubblewrap
3. PRoot

Linux `x86_64` and `aarch64` are supported.

## npm

The npm package is designed for `npx` and project-local installs:

```sh
npx @cardelli/nix run nixpkgs#hello
npx @cardelli/nix shell nixpkgs#{git,hello}
```

Installed bins map to the same portable binary, so these also work after
installing the package:

```sh
npm install --save-dev @cardelli/nix
npx nix --version
npx nix-shell --help
```

The npm distribution follows the native-binary package pattern:

- `@cardelli/nix` is the small JavaScript launcher.
- `@cardelli/nix-linux-x64` contains the Linux x64 `nix-portable` binary.
- `@cardelli/nix-linux-arm64` contains the Linux arm64 `nix-portable` binary.

Unsupported platforms fail with a direct message. Windows users should run it
inside WSL; macOS users should use the native Nix installer.

## Direct Binary

Download the release binary and invoke the Nix tool as the first argument:

```sh
curl -L https://github.com/DavHau/nix-portable/releases/latest/download/nix-portable-$(uname -m) > nix-portable
chmod +x nix-portable
./nix-portable nix --version
./nix-portable nix run nixpkgs#hello
```

You can also symlink tool names to `nix-portable`:

```sh
ln -s ./nix-portable ./nix-shell
./nix-shell --help
```

## Build

Build the native binary for the current system:

```sh
nix build .#nix-portable
```

Build the npm publish tree on `x86_64-linux`:

```sh
nix build .#npm-dist
tree result/packages
```

The generated package directories are publishable with `npm publish` in this
order:

1. `result/packages/nix-linux-x64`
2. `result/packages/nix-linux-arm64`
3. `result/packages/nix`

## Runtime Environment

Optional environment variables:

```txt
NP_DEBUG      1 = debug logs, 2 = debug logs plus shell trace
NP_GIT        path to a git executable to use instead of installing git
NP_LOCATION   parent directory for .nix-portable, defaults to $HOME
NP_RUNTIME    runtime override: nix, bwrap, or proot
NP_NIX        static nix executable override for the nix runtime
NP_BWRAP      bubblewrap executable override
NP_PROOT      proot executable override
NP_RUN        full runtime command override for debugging/custom runtimes
```

## Bundling Programs

`nix-portable` remains a Nix bundler. For example:

```sh
nix bundle --bundler github:DavHau/nix-portable -o bundle nixpkgs#hello
cp ./bundle/bin/hello ./hello
./hello
```

Use `github:DavHau/nix-portable#zstd-max` for smaller bundles and slower
compression.

## Maintenance Notes

The runtime script lives in `runtime/runtime.sh.in` and is linted as normal
Bash. `default.nix` only substitutes build-time paths into that template and
assembles the self-extracting zip.
