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
            cap_add = ["SYS_ADMIN"]
            args = ["-c", "mkdir /run/cgroup; mount -t cgroup2 none /run/cgroup; { nproc; awk '/MemTotal/ {print $2}' /proc/meminfo; cat /run/cgroup$(awk -F: '$1 == 0 {print $3}' /proc/self/cgroup)/memory.max; } > /alloc/measurements; sleep infinity"]
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
        advertise = {
          http = "127.0.0.1";
          rpc = "127.0.0.1";
          serf = "127.0.0.1";
        };
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
      pauseImage = "docker.io/library/kata-resource-test:test";
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
    try:
        machine.wait_until_succeeds("nomad node status", timeout=30)
    except Exception:
        print(machine.execute("journalctl -u nomad --no-pager -n 100")[1])
        print(machine.execute("cat /etc/nomad.json")[1])
        raise
    machine.succeed("nomad job run -detach ${job}")
    try:
        machine.wait_until_succeeds("nomad job allocs -json resources | jq -e 'any(.[]; .ClientStatus == \"running\")'", timeout=120)
    except Exception:
        print(machine.execute("nomad job allocs -json resources")[1])
        print(machine.execute("ps -ww -C qemu-system-x86_64 -o args=")[1])
        print(machine.execute("journalctl -u nomad -u containerd --no-pager -n 100")[1])
        raise
    alloc = json.loads(machine.succeed("nomad job allocs -json resources"))[0]["ID"]
    path = f"/var/lib/nomad/alloc/{alloc}/alloc/measurements"
    try:
        machine.wait_until_succeeds(f"test $(wc -l < {path}) -eq 3", timeout=30)
    except Exception:
        print(machine.execute(f"cat {path}; find /var/lib/nomad/alloc/{alloc} -name measurements; nomad alloc logs -stderr -task work {alloc}")[1])
        raise
    measurements = machine.succeed(f"cat {path}").splitlines()
    cpus = int(measurements[0])
    memory_kib = int(measurements[1])
    assert cpus == 4, f"guest has {cpus} CPUs, expected host's 4"
    assert 1600 * 1024 < memory_kib < 1800 * 1024, f"guest RAM {memory_kib} KiB, expected 1536 + 256 MiB minus kernel overhead"
    assert measurements[2] == str(1536 * 1024 * 1024)
    machine.succeed("nomad job stop -purge resources")
  '';
}
