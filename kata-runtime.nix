{
  fetchurl,
  lib,
  makeWrapper,
  stdenvNoCC,
  zstd,
}:

let
  version = "4.1.0";
in
stdenvNoCC.mkDerivation {
  pname = "kata-runtime";
  inherit version;

  src = fetchurl {
    url = "https://github.com/kata-containers/kata-containers/releases/download/${version}/kata-static-${version}-amd64.tar.zst";
    hash = "sha256-Pca2nErLeHuWewS2RZmiDQKovrGo6qswhBEN+dCwjJY=";
  };

  nativeBuildInputs = [
    makeWrapper
    zstd
  ];

  dontUnpack = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out"
    tar --use-compress-program=unzstd \
      --extract \
      --file "$src" \
      --directory "$out" \
      --strip-components=3 \
      ./opt/kata

    substituteInPlace "$out/share/defaults/kata-containers/runtime-rs/"*.toml \
      --replace-warn '/opt/kata/' "$out/"
    rm "$out/share/defaults/kata-containers/configuration.toml"

    mkdir -p "$out/libexec/kata-containers" "$out/bin"
    mv "$out/runtime-rs/bin/containerd-shim-kata-v2" "$out/libexec/kata-containers/"
    mv "$out/bin/qemu-system-x86_64" "$out/libexec/kata-containers/"
    rmdir "$out/runtime-rs/bin" "$out/runtime-rs"

    ln -s ../libexec/kata-containers/containerd-shim-kata-v2 \
      "$out/bin/containerd-shim-kata-v2"
    makeWrapper \
      "$out/libexec/kata-containers/qemu-system-x86_64" \
      "$out/bin/qemu-system-x86_64" \
      --add-flags "-L $out/share/kata-qemu/qemu"
    ln -s containerd-shim-kata-v2 "$out/bin/containerd-shim-kata-qemu-v2"
    ln -s containerd-shim-kata-v2 "$out/bin/containerd-shim-kata-clh-v2"

    test "$(cat "$out/VERSION")" = "${version}"
    test -x "$out/bin/containerd-shim-kata-v2"
    "$out/bin/containerd-shim-kata-v2" --version | grep -F "Kata Containers containerd shim (Rust)"
    "$out/bin/containerd-shim-kata-v2" --version | grep -F "id: io.containerd.kata.v2"
    "$out/bin/containerd-shim-kata-v2" --version | grep -F "version: ${version}"
    test -f "$out/share/defaults/kata-containers/runtime-rs/configuration.toml"
    test -f "$out/share/kata-containers/kata-containers.img"
    test -f "$out/share/kata-containers/vmlinux.container"

    runHook postInstall
  '';

  passthru = {
    inherit version;
    releaseAsset = "kata-static-${version}-amd64.tar.zst";
  };

  meta = {
    description = "Official Kata Containers runtime-rs bundle";
    homepage = "https://github.com/kata-containers/kata-containers";
    changelog = "https://github.com/kata-containers/kata-containers/releases/tag/${version}";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
