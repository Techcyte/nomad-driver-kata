{
  pkgs,
  driverPkg,
  kataRuntime,
  skipTaskStats ? false,
}:

let
  jobs = import ./jobs.nix { inherit pkgs; };
  verify = import ./stop-verify.nix { inherit pkgs; };
  containerdSock = "/run/containerd/containerd.sock";
  nomadAddr = "http://127.0.0.1:14646";

  busyboxImage = pkgs.dockerTools.buildImage {
    name = "docker.io/library/busybox";
    tag = "latest";
    copyToRoot = pkgs.buildEnv {
      name = "busybox-root";
      paths = [ pkgs.busybox ];
      pathsToLink = [ "/bin" ];
    };
    config.Cmd = [ "/bin/sh" ];
  };

  pauseImage = pkgs.dockerTools.buildImage {
    name = "registry.k8s.io/pause";
    tag = "3.9";
    copyToRoot = pkgs.buildEnv {
      name = "pause-root";
      paths = [ pkgs.busybox ];
      pathsToLink = [ "/bin" ];
    };
    config.Cmd = [
      "/bin/sh"
      "-c"
      "sleep infinity"
    ];
  };
in
pkgs.testers.runNixOSTest {
  name = "nomad-driver-kata-stop${if skipTaskStats then "-without-stats" else ""}";

  nodes.machine =
    { lib, pkgs, ... }:
    {
      imports = [ ../module.nix ];

      virtualisation = {
        cores = 4;
        memorySize = 4096;
        diskSize = 8192;
        qemu.options = [
          "-cpu"
          "host"
        ];
      };

      virtualisation.containerd.enable = true;
      virtualisation.containerd.settings = {
        version = lib.mkForce 3;
        plugins."io.containerd.cri.v1.runtime".containerd.runtimes.kata = {
          runtime_type = "io.containerd.kata.v2";
          privileged_without_host_devices = true;
        };
      };

      environment.etc."kata-containers/runtime-rs/configuration.toml".source =
        "${kataRuntime}/share/defaults/kata-containers/runtime-rs/configuration.toml";
      systemd.services.containerd.path = [ kataRuntime ];

      services.nomad = {
        enable = true;
        enableDocker = false;
        dropPrivileges = false;
        extraSettingsPlugins = [ driverPkg ];
        settings = {
          log_level = "INFO";
          bind_addr = "127.0.0.1";
          ports = {
            http = 14646;
            rpc = 14647;
            serf = 14648;
          };
          advertise = {
            http = "127.0.0.1";
            rpc = "127.0.0.1";
            serf = "127.0.0.1";
          };
          server = {
            enabled = true;
            bootstrap_expect = 1;
          };
          telemetry.publish_allocation_metrics = true;
          client = {
            enabled = true;
            cni_path = "${pkgs.cni-plugins}/bin";
            cni_config_dir = "/etc/cni/net.d";
          };
        };
      };

      services.nomad-driver-kata = {
        enable = true;
        package = driverPkg;
        containerdAddr = containerdSock;
        namespace = "default";
        pauseImage = "registry.k8s.io/pause:3.9";
        runtime = "io.containerd.kata.v2";
      };
      services.nomad.settings.plugin."nomad-driver-kata".config.sandbox_cleanup_delay = lib.mkForce "0s";
      systemd.services.nomad.environment = lib.mkIf skipTaskStats {
        NOMAD_KATA_SKIP_TASK_STATS = "1";
      };

      environment.systemPackages = with pkgs; [
        containerd
        nomad
        jq
        cni-plugins
        iptables
        kataRuntime
      ];
      boot.kernelModules = [
        "bridge"
        "br_netfilter"
        "vhost_vsock"
        "vhost_net"
        "tun"
        "kvm"
      ];
    };

  testScript = ''
    start_all()
    machine.wait_for_unit("containerd.service")
    machine.wait_until_succeeds("ctr -a ${containerdSock} version")
    machine.succeed("ctr -a ${containerdSock} image import ${busyboxImage}")
    machine.succeed("ctr -a ${containerdSock} image import ${pauseImage}")
    machine.wait_for_unit("nomad.service")
    machine.wait_until_succeeds("nomad node status -address=${nomadAddr}")
    machine.succeed(
      "env NOMAD_ADDR=${nomadAddr} CONTAINERD_SOCK=${containerdSock} "
      "STOP_JOB=${jobs.stop} ${pkgs.lib.getExe verify}",
      timeout=240,
    )
  '';
}
