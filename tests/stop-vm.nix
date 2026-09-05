{
  pkgs,
  driverPkg,
  kataRuntime,
  skipTaskStats ? false,
  traceShim ? false,
  captureConsole ? false,
  hostCores ? 4,
}:

let
  jobs = import ./jobs.nix { inherit pkgs; };
  verify = import ./stop-verify.nix { inherit pkgs; };
  containerdSock = "/run/containerd/containerd.sock";
  nomadAddr = "http://127.0.0.1:14646";
  consoleConfig = pkgs.runCommand "kata-startup-console-configuration" { } ''
    substitute ${kataRuntime}/share/defaults/kata-containers/runtime-rs/configuration.toml "$out" \
      --replace-fail 'kernel_params = "cgroup_no_v1=all systemd.unified_cgroup_hierarchy=1"' \
        'kernel_params = "cgroup_no_v1=all systemd.unified_cgroup_hierarchy=1 loglevel=7 systemd.log_target=console systemd.show_status=true"'
  '';
  consoleCapture = pkgs.writeShellScript "capture-guest-console" ''
    for _ in $(${pkgs.coreutils}/bin/seq 1 1200); do
      for socket in /run/kata/*/root/console.sock; do
        if [ -S "$socket" ]; then
          exec ${pkgs.socat}/bin/socat -u "UNIX-CONNECT:$socket" STDOUT
        fi
      done
      ${pkgs.coreutils}/bin/sleep 0.1
    done
    exit 1
  '';

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
        cores = hostCores;
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
        if captureConsole then
          consoleConfig
        else
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
        strace
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
    ${pkgs.lib.optionalString captureConsole ''
      machine.succeed(
          "systemd-run --unit=guest-console --property=StandardOutput=file:/run/guest-console.log ${consoleCapture}"
      )
    ''}
    machine.succeed(
        "systemd-run --unit=stop-verification sh -c '"
        "${pkgs.coreutils}/bin/env NOMAD_ADDR=${nomadAddr} CONTAINERD_SOCK=${containerdSock} "
        "STOP_JOB=${jobs.stop} ${pkgs.lib.getExe verify} >/run/stop-verification.log 2>&1; "
        "echo $? >/run/stop-status'"
    )
    try:
        machine.wait_until_succeeds(
            "grep -q 'stop task reached running readiness' /run/stop-verification.log || test -f /run/stop-status",
            timeout=120,
        )
    finally:
        print(machine.succeed("cat /run/stop-verification.log"))
        ${pkgs.lib.optionalString captureConsole ''
          console = machine.succeed("base64 -w0 /run/guest-console.log").strip()
          for offset in range(0, len(console), 1024):
              print(f"GUEST_CONSOLE_CHUNK={offset}:{console[offset:offset + 1024]}")
        ''}
    machine.succeed("test ! -f /run/stop-status")
    ${pkgs.lib.optionalString traceShim ''
      shim_pid = int(machine.succeed(
          "cat /run/containerd/io.containerd.runtime.v2.task/default/*-sandbox/shim.pid"
      ).strip())
      machine.succeed(
          "systemd-run --unit=shim-exit-trace "
          f"${pkgs.strace}/bin/strace -f -ttt -e trace=exit,exit_group -o /run/shim-exit.trace -p {shim_pid}"
      )
    ''}
    machine.wait_until_succeeds("test -f /run/stop-status", timeout=240)
    print(machine.succeed("cat /run/stop-verification.log"))
    ${pkgs.lib.optionalString traceShim ''
      print(machine.succeed("cat /run/shim-exit.trace"))
    ''}
    print(machine.execute(
        "journalctl -b --no-pager -o short-monotonic | "
        "grep -E 'agent health check|stop monitor signal|runtime keep alive|shutdown shim|failed to delete task|delete hypervisor|resource clean up'"
    )[1])
    assert int(machine.succeed("cat /run/stop-status").strip()) == 0
  '';
}
