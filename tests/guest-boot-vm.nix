{
  pkgs,
  kataRuntime,
  sharedMemory ? false,
  shmemHugePages ? false,
}:

pkgs.testers.runNixOSTest {
  name = "kata-guest-boot";
  nodes.machine = { ... }: {
    virtualisation = {
      cores = 1;
      memorySize = 4096;
      qemu.options = [
        "-cpu"
        "host"
      ];
    };
    boot.kernelModules = [
      "kvm"
      "vhost_vsock"
    ];
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    print(machine.succeed("cat /sys/kernel/mm/transparent_hugepage/enabled /sys/kernel/mm/transparent_hugepage/shmem_enabled"))
    if ${if shmemHugePages then "True" else "False"}:
        machine.succeed("echo within_size > /sys/kernel/mm/transparent_hugepage/shmem_enabled")
        machine.succeed("mount -o remount,huge=within_size /dev/shm")
    machine.succeed(
        "systemd-run --unit=guest-boot ${kataRuntime}/bin/qemu-system-x86_64 "
        "-name guest-boot -machine q35,accel=kvm,nvdimm=on,kernel_irqchip=on${pkgs.lib.optionalString sharedMemory ",memory-backend=ram"} "
        "${pkgs.lib.optionalString sharedMemory "-object memory-backend-file,id=ram,mem-path=/dev/shm,size=2G,share=on,prealloc=off,readonly=off${pkgs.lib.optionalString shmemHugePages ",align=2097152"} "}"
        "-cpu host,pmu=off -smp 1 -m 2G,slots=10,maxmem=3917M "
        "-kernel ${kataRuntime}/share/kata-containers/vmlinux.container "
        "-append 'reboot=k panic=1 systemd.unit=kata-containers.target "
        "systemd.mask=systemd-networkd.service systemd.mask=systemd-networkd.socket "
        "root=/dev/pmem0p1 rootflags=dax,data=ordered,errors=remount-ro ro rootfstype=ext4 "
        "cgroup_no_v1=all systemd.unified_cgroup_hierarchy=1 selinux=0 "
        "console=ttyS0 loglevel=7 initcall_debug systemd.log_target=console systemd.show_status=true' "
        "-object memory-backend-file,id=rootfs,mem-path=${kataRuntime}/share/kata-containers/kata-containers.img,"
        "size=256M,share=off,prealloc=off,readonly=on -device nvdimm,memdev=rootfs,unarmed=on "
        "-object rng-random,id=rng0,filename=/dev/urandom -device virtio-rng-pci,rng=rng0 "
        "-device vhost-vsock-pci,disable-modern=true,guest-cid=42 "
        "-serial file:/run/guest-boot.log -display none -no-user-config -nodefaults -no-reboot"
    )
    try:
        machine.wait_until_succeeds("grep -q '\"msg\":\"announce\"' /run/guest-boot.log", timeout=60)
    finally:
        print(machine.execute("pid=$(systemctl show -p MainPID --value guest-boot.service); grep -E '(/dev/shm|KernelPageSize|MMUPageSize|ShmemPmdMapped|FilePmdMapped|AnonHugePages)' /proc/$pid/smaps")[1])
        console = machine.succeed("base64 -w0 /run/guest-boot.log").strip()
        for offset in range(0, len(console), 1024):
            print(f"GUEST_CONSOLE_CHUNK={offset}:{console[offset:offset + 1024]}")
        machine.execute("systemctl stop guest-boot.service")
  '';
}
