{
  description = "My personal blog";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      utils,
      ...
    }:
    let
      supportedSystems = [
        "x86_64-linux"
      ];
    in
    utils.lib.eachSystem supportedSystems (
      system:
      let
        pkgs = import nixpkgs {
          inherit system;
        };

        myPkgs = {
          blog = pkgs.callPackage ./blog.nix { };
        };
      in
      {
        checks = myPkgs;
        packages = myPkgs // {
          default = myPkgs.blog;
        };

        devShells = {
          default = pkgs.mkShell {
            inputsFrom = builtins.attrValues self.checks.${system};

            buildInputs = [
              pkgs.exiftool
              pkgs.graphviz
              pkgs.nixpkgs-fmt
            ];
          };

          ci = pkgs.mkShell {
            packages = [
              pkgs.rsync
            ];
          };

          zizmor = pkgs.mkShell {
            packages = [
              pkgs.zizmor
            ];
          };
        };
      }
    );
}
