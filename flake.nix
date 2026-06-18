{
  description = "CyberGroupmate — a code-driven group chat social agent";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      flake = {
        # Expose raw flake inputs (e.g. the pinned nixpkgs source) so tooling
        # can introspect them without reaching for the global registry:
        #   nix eval --raw .#inputs.nixpkgs.outPath
        inherit inputs;

        # Overlay so `pkgs.cybergroupmate` is available wherever the overlay
        # is applied (and so the Home Manager module's default `package`
        # option resolves out of the box).
        overlays.default = final: _prev: {
          cybergroupmate = final.callPackage ./nix/package.nix { };
        };

        # Home Manager module — `import cybergroupmate.flake.homeModules.default`
        # / `home-manager.sharedModules = [ ... ]`.
        homeModules.default = ./nix/home-manager.nix;
      };

      perSystem =
        {
          config,
          pkgs,
          system,
          ...
        }:
        {
          _module.args.pkgs = import inputs.nixpkgs {
            inherit system;
            overlays = [ inputs.self.overlays.default ];
          };

          # The real package is `cybergroupmate`; `default` is just an alias
          # pointing at it (so consumers can use either name, but the
          # derivation only has one canonical attribute).
          packages.cybergroupmate = pkgs.cybergroupmate;
          packages.default = config.packages.cybergroupmate;
        };
    };
}
