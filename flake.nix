{
  description = "Kernel builder";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable-small";
    flake-compat.url = "github:edolstra/flake-compat";
  };

  outputs =
    {
      self,
      flake-compat,
      flake-utils,
      nixpkgs,
    }:
    let
      config = {
        allowUnfree = true;
        cudaSupport = true;
      };

      overlay = import ./overlay.nix;
    in
    flake-utils.lib.eachSystem [ flake-utils.lib.system.x86_64-linux ] (
      system:
      let
        # Plain nixkpgs that we use to access utility funtions.
        pkgs = import nixpkgs {};
        inherit (pkgs) lib;

        buildVersion = import ./lib/build-version.nix;
        flattenVersion = version: pkgs.lib.replaceStrings [ "." ] [ "_" ] (lib.versions.pad 2 version);

        # An overlay that overides CUDA to the given version.
        overlayForCudaVersion = cudaVersion: self: super: {
          cudaPackages =
            super."cudaPackages_${flattenVersion cudaVersion}";
        };

        # Construct the nixpkgs package set for the given versions.
        pkgsForVersions =
          pkgsByCudaVer:
          {
            cudaVersion,
            torchVersion,
            cxx11Abi,
          }:
          let
            pkgsForCudaVersion = pkgsByCudaVer.${cudaVersion};
            torch = pkgsForCudaVersion.python3.pkgs."torch_${flattenVersion torchVersion}".override {
              inherit cxx11Abi;
            };
          in {
            inherit torch;
            pkgs = pkgsForCudaVersion;
          };

        # Instantiate nixpkgs for the given CUDA versions. Returns
        # an attribute set like `{ "12.4" = <nixpkgs with 12.4>; ... }`.
        pkgsForCudaVersions = cudaVersions: builtins.listToAttrs (map (cudaVersion: {
          name = cudaVersion;
          value = import nixpkgs {
            inherit config system;
            overlays = [
              overlay
              (overlayForCudaVersion cudaVersion)
            ];
          };
        }) cudaVersions);

        # Supported CUDA versions.
        cudaVersions = ["11.8" "12.1" "12.4"];

        # All build configurations supported by Torch.
        buildConfigs = pkgs.lib.cartesianProduct {
          cudaVersion = cudaVersions;
          torchVersion = [
            "2.4"
            "2.5"
          ];
          cxx11Abi = [
            true
            false
          ];
        };

        pkgsByCudaVer = pkgsForCudaVersions cudaVersions;
        buildSets = map (pkgsForVersions pkgsByCudaVer) buildConfigs;
        
      in
      rec {
        formatter = pkgs.nixfmt-rfc-style;
        lib = import lib/build.nix {
          inherit (pkgs) lib;
          inherit buildSets;
        };
        packages = rec {
          # This package set is exposed so that we can prebuild the Torch versions.
          torch = builtins.listToAttrs (
            map (pkgs': {
              name = buildVersion pkgs';
              value = pkgs'.python3.pkgs.torch;
            }) buildSets
          );
        };
      }
    );
}
