{
  description = "DEMOjudge toolchain";

  # Pinned to the last nixpkgs carrying gleam 1.12.0, which is the compiler this
  # tree is written against.
  inputs.nixpkgs.url =
    "github:NixOS/nixpkgs/06fe4ef2f3344c26ec0da643424a3869ee7727e2";

  outputs = { nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      each = f: nixpkgs.lib.genAttrs systems (s: f nixpkgs.legacyPackages.${s});
    in {
      devShells = each (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.gleam
            pkgs.erlang_27
            pkgs.beam27Packages.rebar3
            pkgs.tlaplus
            pkgs.python3
            pkgs.ruff
            pkgs.shellcheck
            pkgs.shfmt
          ];
        };
      });
    };
}
