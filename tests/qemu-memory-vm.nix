{ pkgs, kataRuntime }:
pkgs.testers.runNixOSTest {
  name = "kata-guest-memory";
  nodes.machine = { };
  testScript = ''
    start_all()
    machine.wait_for_unit("multi-user.target")
    for setup in ["true", "touch /run/kata-memory", "rm /run/kata-memory; mkdir /run/kata-memory"]:
        machine.succeed(setup)
        machine.succeed("${pkgs.python3}/bin/python3 ${./qemu-memory.py} ${kataRuntime}/bin/qemu-system-x86_64 --reject-managed-only")
    machine.succeed("mount -t ramfs ramfs /run/kata-memory")
    machine.succeed("${pkgs.python3}/bin/python3 ${./qemu-memory.py} ${kataRuntime}/bin/qemu-system-x86_64 --reject-managed-only")
    machine.succeed("umount /run/kata-memory; mount -t tmpfs -o mode=0700,huge=within_size tmpfs /run/kata-memory")
    machine.succeed("${pkgs.python3}/bin/python3 ${./qemu-memory.py} ${kataRuntime}/bin/qemu-system-x86_64")
  '';
}
