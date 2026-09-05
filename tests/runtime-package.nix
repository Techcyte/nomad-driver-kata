{ pkgs, kataRuntime }:

pkgs.runCommand "kata-runtime-package" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  test "${kataRuntime.releaseAsset}" = "kata-static-4.1.0-amd64.tar.zst"
  test "$(cat ${kataRuntime}/VERSION)" = "4.1.0"

  shim_version="$(${kataRuntime}/bin/containerd-shim-kata-v2 --version)"
  printf '%s\n' "$shim_version" | grep -F "Kata Containers containerd shim (Rust)"
  printf '%s\n' "$shim_version" | grep -F "id: io.containerd.kata.v2"
  printf '%s\n' "$shim_version" | grep -F "version: 4.1.0"
  printf '%s\n' "$shim_version" | grep -F "commit: ddcb1ad8d23cbb4323f86c209f132b89592902df"

  test ! -e ${kataRuntime}/bin/kata-runtime
  test -f ${kataRuntime}/share/defaults/kata-containers/runtime-rs/configuration.toml
  test -f ${kataRuntime}/share/kata-containers/kata-containers.img
  test -f ${kataRuntime}/share/kata-containers/vmlinux.container

  python3 - <<'PY'
  import pathlib
  import tomllib

  runtime = pathlib.Path("${kataRuntime}")
  config_path = runtime / "share/defaults/kata-containers/runtime-rs/configuration.toml"
  with config_path.open("rb") as config_file:
      config = tomllib.load(config_file)

  qemu = config["hypervisor"]["qemu"]
  assert qemu["path"] == str(runtime / "bin/qemu-system-x86_64")
  assert qemu["kernel"] == str(runtime / "share/kata-containers/vmlinux.container")
  assert qemu["image"] == str(runtime / "share/kata-containers/kata-containers.img")
  assert qemu["virtio_fs_daemon"] == str(runtime / "libexec/virtiofsd")
  PY

  test "$(sha256sum ${kataRuntime}/libexec/kata-containers/containerd-shim-kata-v2 | cut -d' ' -f1)" = \
    "3c88c8d7f183b95912974eaa143f1c8a52c57b0a01c5ef4a4c61e22f16364481"
  test "$(sha256sum ${kataRuntime}/libexec/kata-containers/qemu-system-x86_64 | cut -d' ' -f1)" = \
    "b94419fca709f2b928a20d7b04d856f87cdfdbc2db357872096f090cc2c58abc"
  test "$(sha256sum ${kataRuntime}/share/kata-containers/vmlinux.container | cut -d' ' -f1)" = \
    "8e9dbc3a6e4c26adb089d23d31201edebce905c7f3e31aa67b32bdd41df1b86f"
  test "$(sha256sum ${kataRuntime}/share/kata-containers/kata-containers.img | cut -d' ' -f1)" = \
    "96497f64da1de9c7473fef46c3d29ddd0805d334731cf9d903a21a5b2c33cefb"

  python3 ${./qemu-memory.py} ${kataRuntime}/bin/qemu-system-x86_64

  touch "$out"
''
