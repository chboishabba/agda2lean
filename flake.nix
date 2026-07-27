{
  description = "agda2lean development shell and comparison workspace";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/e2587caef70cea85dd97d7daab492899902dbf5d";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = f:
        builtins.listToAttrs (map (system: {
          name = system;
          value = f system;
        }) systems);
    in {
      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in {
          default = pkgs.mkShell {
            packages = with pkgs; [
              cabal-install
              elan
              git
              coreutils
              gnumake
              jq
              haskell.compiler.ghc967
              python3
              rsync
              sqlite
              which
            ];

            shellHook = ''
              export ELAN_HOME="$PWD/.elan"
              mkdir -p "$ELAN_HOME"
              echo "agda2lean shell"
              echo "  GHC: $(ghc --version)"
              echo "  Cabal: $(cabal --version | head -n1)"
              echo "  Lean toolchain: $(tr -d '\n' < lean-toolchain)"
              echo "  ELAN_HOME: $ELAN_HOME"
            '';
          };
        });
    };
}
