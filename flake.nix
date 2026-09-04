{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };

      kataRuntime = pkgs.callPackage ./kata-runtime.nix { };

      driverPkg = pkgs.buildGoModule {
        pname = "nomad-driver-kata";
        version = "0.1.0";
        src = ./.;
        vendorHash = "sha256-RplDmsBNxGOkI40eFRXpa/+P01Ap1hk4NhPATZKiU80=";
        env.CGO_ENABLED = 0;
        ldflags = [
          "-s"
          "-w"
        ];

        preCheck = ''
          go vet ./...
        '';

        meta = with pkgs.lib; {
          description = "Nomad task driver for Kata Containers with sandbox-aware VM sharing";
          license = licenses.mit;
          platforms = platforms.linux;
        };
      };

      integrationTest = import ./tests/integration.nix {
        inherit pkgs driverPkg kataRuntime;
      };

      integrationVmTest = import ./tests/integration-vm.nix {
        inherit pkgs driverPkg kataRuntime;
      };

      runtimePackageTest = import ./tests/runtime-package.nix {
        inherit pkgs kataRuntime;
      };

    in
    assert kataRuntime.version == "4.1.0";
    {
      packages.${system} = {
        default = driverPkg;
        kata-runtime = kataRuntime;
        integration-vm = integrationVmTest;
      };

      checks.${system} = {
        default = driverPkg;
        runtime-package = runtimePackageTest;
      };

      apps.${system}.integration-test = {
        type = "app";
        program = pkgs.lib.getExe integrationTest;
        meta.description = "Integration test requiring root and KVM";
      };

      nixosModules.default = ./module.nix;

      devShells.${system}.default = pkgs.mkShell {
        buildInputs = with pkgs; [
          go
          gopls
          gotools
          nomad
          containerd
          kataRuntime
        ];
      };
    };
}
