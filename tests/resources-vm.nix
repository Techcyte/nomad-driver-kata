{ pkgs, driverPkg, kataRuntime, nomadPkg }:
let
  image = pkgs.dockerTools.buildImage {
    name = "kata-resource-test";
    tag = "test";
    copyToRoot = pkgs.buildEnv {
      name = "resource-test-root";
      paths = [ pkgs.busybox ];
      pathsToLink = [ "/bin" ];
    };
    config.Cmd = [ "/bin/sh" "-c" "sleep infinity" ];
  };
  job = pkgs.writeText "resources.nomad.hcl" ''
    job "resources" {
      type = "service"
      group "guest" {
        task "prepare" {
          driver = "kata"
          lifecycle { hook = "prestart" }
          config {
            image = "kata-resource-test:test"
            command = "sh"
            args = ["-c", "true"]
          }
          resources {
            cpu = 100
            memory = 128
          }
        }
        task "work" {
          driver = "kata"
          config {
            image = "kata-resource-test:test"
            command = "sh"
            args = ["-c", "sleep infinity"]
          }
          resources {
            cpu = 100
            memory = 1024
            memory_max = 1536
          }
        }
      }
    }
  '';
in
pkgs.testers.runNixOSTest {
  name = "kata-allocation-resources";
  nodes.machine = { lib, ... }: {
    imports = [ ../module.nix ];
    virtualisation = {
      cores = 4;
      memorySize = 4096;
      diskSize = 8192;
      qemu.options = [ "-cpu" "host" ];
    };
    virtualisation.containerd.enable = true;
    systemd.services.containerd.path = [ kataRuntime ];
    environment.etc."kata-containers/runtime-rs/configuration.toml".source =
      "${kataRuntime}/share/defaults/kata-containers/runtime-rs/configuration.toml";
    services.nomad = {
      enable = true;
      package = nomadPkg;
      enableDocker = false;
      dropPrivileges = false;
      extraSettingsPlugins = [ driverPkg ];
      settings = {
        bind_addr = "127.0.0.1";
        server = {
          enabled = true;
          bootstrap_expect = 1;
          default_scheduler_config.memory_oversubscription_enabled = true;
        };
        client.enabled = true;
      };
    };
    services.nomad-driver-kata = {
      enable = true;
      package = driverPkg;
      containerdAddr = "/run/containerd/containerd.sock";
      pauseImage = "kata-resource-test:test";
    };
    environment.systemPackages = [ pkgs.containerd nomadPkg pkgs.jq ];
    boot.kernelModules = [ "kvm" "vhost_vsock" ];
  };
  testScript = ''
    import json
    start_all()
    machine.wait_for_unit("containerd.service")
    machine.succeed("ctr images import ${image}")
    machine.wait_for_unit("nomad.service")
    machine.wait_until_succeeds("nomad node status")
    machine.succeed("nomad job run ${job}")
    machine.wait_until_succeeds("nomad job allocs -json resources | jq -e 'any(.[]; .ClientStatus == \"running\")'", timeout=120)
    alloc = json.loads(machine.succeed("nomad job allocs -json resources"))[0]["ID"]
    def guest(command):
        return machine.succeed(f"nomad alloc exec -task work {alloc} sh -c '{command}'").strip()
    machine.wait_until_succeeds(f"nomad alloc exec -task work {alloc} true", timeout=120)
    cpus = int(guest("nproc"))
    memory_kib = int(guest("awk \"/MemTotal/ {{print \\$2}}\" /proc/meminfo"))
    assert cpus == 4, f"guest has {cpus} CPUs, expected host's 4"
    assert 1600 * 1024 < memory_kib < 1800 * 1024, f"guest RAM {memory_kib} KiB, expected 1536 + 256 MiB minus kernel overhead"
    assert guest("cat /sys/fs/cgroup/memory.max") == str(1536 * 1024 * 1024)
    machine.succeed("nomad job stop -purge resources")
  '';
}
