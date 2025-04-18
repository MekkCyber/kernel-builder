{
  description = "Kernel builder";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable-small";
    flake-compat.url = "github:edolstra/flake-compat";
    rocm-nix = {
      url = "github:huggingface/rocm-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      flake-compat,
      flake-utils,
      nixpkgs,
      rocm-nix,
    }:
    let
      systems = with flake-utils.lib.system; [
        aarch64-linux
        x86_64-linux
      ];

      # Create an attrset { "<system>" = [ <buildset> ...]; ... }.
      buildSetPerSystem = builtins.listToAttrs (
        builtins.map (system: {
          name = system;
          value = import ./lib/buildsets.nix {
            inherit nixpkgs system;
            rocm = rocm-nix.overlays.default;
          };
        }) systems
      );

      libPerSystem = builtins.mapAttrs (
        system: buildSet:
        import lib/build.nix {
          inherit (nixpkgs) lib;
          buildSets = buildSetPerSystem.${system};
        }
      ) buildSetPerSystem;

      # The lib output consists of two parts:
      #
      # - Per-system build functions.
      # - `genFlakeOutputs`, which can be used by downstream flakes to make
      #   standardized outputs (for all supported systems).
      lib = {
        genFlakeOutputs =
          { path, rev }:
          flake-utils.lib.eachSystem systems (
            system:
            let
              build = libPerSystem.${system};
              revUnderscored = builtins.replaceStrings [ "-" ] [ "_" ] rev;
            in
            {
              devShells = rec {
                default = shells."torch26-cxx98-cu126-${system}";
                shells = build.torchExtensionShells {
                  inherit path;
                  rev = revUnderscored;
                };
              };
              packages = {
                bundle = build.buildTorchExtensionBundle {
                  inherit path;
                  rev = revUnderscored;
                };
                redistributable = build.buildDistTorchExtensions {
                  inherit path;
                  rev = revUnderscored;
                };
              };
            }
          );
      } // libPerSystem;

    in
    flake-utils.lib.eachSystem systems (
      system:
      let
        # Plain nixkpgs that we use to access utility funtions.
        pkgs = import nixpkgs {
          inherit system;
        };
        inherit (nixpkgs) lib;

        buildVersion = import ./lib/build-version.nix;

        buildSets = buildSetPerSystem.${system};

      in
      rec {
        formatter = pkgs.nixfmt-rfc-style;

        packages = rec {
          build2cmake = pkgs.callPackage ./pkgs/build2cmake { };

          # This package set is exposed so that we can prebuild the Torch versions.
          torch = builtins.listToAttrs (
            map (buildSet: {
              name = buildVersion buildSet;
              value = buildSet.torch;
            }) buildSets
          );

          # Dependencies that should be cached.
          forCache =
            let
              filterDist = lib.filter (output: output != "dist");
              # Get all `torch` outputs except for `dist`. Not all outputs
              # are dependencies of `out`, but we'll need the `cxxdev` and
              # `dev` outputs for kernel builds.
              torchOutputs = builtins.listToAttrs (
                lib.flatten (
                  # Map over build sets.
                  map (
                    buildSet:
                    # Map over all outputs of `torch` in a buildset.
                    map (output: {
                      name = "${buildVersion buildSet}-${output}";
                      value = buildSet.torch.${output};
                    }) (filterDist buildSet.torch.outputs)
                  ) buildSets
                )
              );
              oldLinuxStdenvs = builtins.listToAttrs (
                map (buildSet: {
                  name = "stdenv-${buildVersion buildSet}";
                  value = buildSet.pkgs.stdenvGlibc_2_27;
                }) buildSets
              );
            in
            pkgs.linkFarm "packages-for-cache" (torchOutputs // oldLinuxStdenvs);
        };
      }
    )
    // {
      inherit lib;
    };
}
