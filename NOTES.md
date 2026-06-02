I have a complete picture. Here's my investigation and plan — no code changes yet, since this is a design/planning task. I'll flag at the end that I can implement any part of it.
Part 1 — Design investigation & maintenance pressure points
How it works today (the 30-second model)
nix-portable is a single, fully-static, self-extracting executable, one per CPU arch (x86_64, aarch64), Linux-only. The build (default.nix) does three things:
Bakes a runtime bash script (runtimeScript, ~520 lines) that, on first run, unpacks bundled binaries + a /nix/store tarball into $HOME/.nix-portable, picks a sandbox runtime (nix → bwrap → proot, auto-detected and cached), then execs the real nix binary inside the virtualized store.
Assembles a polyglot file: a bash script prepended to a hand-crafted ZIP archive (binaries, store tarball, CA bundle). The script unzips pieces out of itself ($self). A SHA fingerprint of the zip is the cache-invalidation key.
Bundling mode: the same machinery, with bundledPackage hardcoding the executable — this is what powers nix bundle --bundler github:DavHau/nix-portable.
The architecture is genuinely clever and the runtime-fallback ladder is the core value. The pressure points are almost all in how the artifact is authored and shipped, not in what it does.
Pressure points (ranked by pain)
1. The double-escaped heredoc — the #1 hazard.
runtimeScript is a Nix string containing bash where every runtime $ is written \$, plus a final replaceStrings ["\""] ["\\\""] pass to escape quotes (default.nix:615). You're maintaining bash through two layers of escaping simultaneously, and build-time vs run-time evaluation is distinguished only by whether you remembered the backslash. This is unlintable, untestable, and every edit risks a class of bug that only surfaces at runtime.
→ Idiomatic fix: move the script to a standalone runtime.sh (real file, shellcheck-able, no escaping), inject build-time values via substituteAll/placeholder tokens (@nixBin@, @storeTar@, etc.) instead of Nix interpolation. This single change removes ~all the \$ noise and makes the script independently testable.
2. Hand-rolled ZIP via raw hex (default.nix:617-648).
ZIP end-of-central-directory records are written byte-by-byte with xxd -r -p, then patched, then repaired with zip -F. It works, but it's opaque, and it couples the artifact format to an exact byte layout that no one will want to touch.
→ Idiomatic fix: either document the format with a diagram and a comment block, or replace the SFX mechanism with makeself/a small C stub. At minimum, isolate it into its own mkSelfExtractor.nix so the magic is contained.
3. Dead/duplicated proot sourcing.
Five files in proot/ (alpine, github, gitlab, nixpkgs, termux) but only alpine.nix is wired into flake.nix. And alpine.nix fetches a static proot from web.archive.org snapshots — a single-point-of-failure URL that can rot.
→ Fix: delete the unused variants (or fold them into one parameterized file), and pin proot via a content-addressed source you control (vendored release asset or your own cache), not an archive.org snapshot.
4. Version drift / fragile upgrades.
nix is pinned to 2.20.6 (current nix is far ahead); flake.nix:8 and :38 carry TODO/"crashes if nixpkgs updated" comments. Bumping nixpkgs is known-scary, which means the artifact silently ages. There's no test that asserts "produces a working nix of version X."
→ Fix: add a smoke-test check that runs nix --version + a trivial build through each runtime, so upgrades fail loudly in CI instead of silently shipping.
5. No release automation.
CI (nix-portable.yml) builds and uploads artifacts but there is no release workflow — GitHub releases (which the README's curl install depends on) are produced by hand. This is the gap you must close first for npm, because npm needs a reliable, versioned artifact source.
6. Minor idiom cleanups. with builtins; with lib; at top-of-file obscures scope; default.nix is one 666-line god-file (store-tar, sfx, runtime, packaging all inline); bwrap/proot/zstd/nixStatic are re-bound with let shadowing the function args, which is confusing.
Suggested refactor target layout:
Code
None of this changes behavior — it makes every future change (nix bumps, new runtimes, the npm work below) tractable.
Part 2 — Plan: portable nix via npx @cardelli/nix
The artifact is ideal for npm: a single self-contained executable per platform, zero runtime deps. This is exactly the esbuild / swc / @napi-rs distribution pattern — optional per-platform packages + a thin launcher.
Package topology
Code
npm/yarn/pnpm honor os/cpu and install only the matching optional dep, so a macOS/Windows user downloads none of the Linux binaries.
On unsupported platforms (darwin, win32) the launcher prints a clear "nix-portable supports Linux x64/arm64 only — on macOS use the native Nix installer; on Windows use WSL" message and exits non-zero. WSL is just Linux, so it works for free.
The launcher (esbuild-style, ~30 lines)
Js
Key insight from the runtime code (default.nix:503-518): nix-portable selects which nix tool to run from basename($0) (or $1 when invoked as nix-portable). So we get the whole tool family naturally:
Jsonc
npx @cardelli/nix run nixpkgs#hello → launcher passes ["nix","run","nixpkgs#hello"] to the binary. nix-shell -p htop works via the nix-shell bin entry. This matches the README's symlink method exactly, for free.
Where the binaries come from — make it a Nix output (the "straightforward" bit)
Keep packaging reproducible and inside the flake rather than gluing it together in CI shell. Add a flake output that emits a ready-to-publish npm tree:
Nix
Then nix build .#npm-dist produces the exact directory tree to npm publish. CI just runs that build and publishes — no bespoke copying logic.
Versioning
Lockstep all three packages to one version (esbuild does this), derived from nix-portable's own version (nix version + a build number, e.g. 2.20.6-portable.N). The meta package pins exact optional-dep versions ("@cardelli/nix-linux-x64": "2.20.6-portable.N") so a user never gets a mismatched launcher/binary pair.
Release pipeline (the missing piece)
New release.yml, triggered on tag:
nix build .#packages.x86_64-linux.nix-portable and .#packages.aarch64-linux.nix-portable (aarch64 via the existing QEMU/cross setup already in CI).
nix build .#npm-dist to assemble the tree.
npm publish --access public each platform package, then the meta package (order matters: platform deps first).
Also upload the raw binaries to the GitHub Release (closes pressure-point #5, keeps the curl install working).
Auth via NPM_TOKEN repo secret with provenance (npm publish --provenance) for supply-chain trust.
Sharp edges to decide up front
Issue
Recommendation
Binary size (~tens of MB each, bundled nixpkgs + nix + busybox + proot/bwrap)
Fine for npm (esbuild ships ~10MB binaries). Optionally publish a "slim" variant that fetches the store tarball on first run, but start with the simple all-in-one.
macOS/Windows
Not supported by nix-portable. Graceful launcher error + docs pointer. Don't fake it.
First-run cost
First npx invocation extracts to $HOME/.nix-portable (seconds). Document it; it's cached after.
Scope @cardelli
Needs the npm org/scope created and the token scoped to it.
npx semantics
npx @cardelli/nix … maps to the nix bin. Works. The other tools (nix-shell etc.) are reachable as separate bins once installed, but npx only exposes one default — fine for the headline use case.
Suggested sequencing
Refactor first (low risk, high leverage): extract runtime.sh + substituteAll, prune proot/. This de-risks everything after.
Add release automation for the raw binaries (independently valuable).
Add npm-dist flake output + launcher + package.json templates.
Add npm publish step to the release workflow; cut 2.20.6-portable.0 as the first npx release.
(Later) nix version bump with a smoke-test guard.
Two things I'd want your call on before writing any code:
