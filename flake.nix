{
  description = "My personal blog";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    terminimal = {
      url = "github:pawroman/zola-theme-terminimal";
      flake = false;
    };
    utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, terminimal, utils, ... }:
    let
      supportedSystems = [
        "x86_64-linux"
      ];
    in
    utils.lib.eachSystem supportedSystems (system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };

        myPkgs = {
          blog = pkgs.callPackage ./blog.nix {
            inherit terminimal;
          };
        };
      in
      {
        checks = myPkgs;
        packages = myPkgs;
        defaultPackage = myPkgs.blog;

        devShell = pkgs.mkShell {
          inputsFrom = builtins.attrValues self.checks.${system};

          buildInputs = with pkgs; [
            graphviz
            nixpkgs-fmt
          ];

          # Link themes managed by Nix rather than having to go with git submodules manually
          shellHook = ''
            THEMES_PATH="$(${pkgs.git}/bin/git rev-parse --show-toplevel)/themes"
            TERMINIMAL_PATH="$THEMES_PATH/terminimal"

            function makeThemeLink() {
              mkdir -p "$THEMES_PATH"
              ln -sfn "${terminimal}" "$TERMINIMAL_PATH"
            }

            if [[ ! -e "$TERMINIMAL_PATH" ]]; then
                makeThemeLink
            elif [[ -L "$TERMINIMAL_PATH" ]]; then
              if [[ ! "$TERMINIMAL_PATH" -ef "${terminimal}" ]]; then
                echo "warning: unlinking stale theme and replacing with flake input"
                unlink "$TERMINIMAL_PATH"
                makeThemeLink
              fi
            else
              echo "warning: unsure how to link theme, consider clearing $TERMINIMAL_PATH"
            fi
          '';
        };
      });
}
