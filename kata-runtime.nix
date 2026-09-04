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
    url = "https://github.com/kata-containers/kata-containers/releases/download/${version}/kata-go-static-${version}-amd64.tar.zst";
    hash = "sha256-izIIBCTIhCOO6NUgYP39Bg++K1/fpOuf8ncrOCtDK1U=";
  };

  nativeBuildInputs = [ makeWrapper zstd ];

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

    substituteInPlace "$out/share/defaults/kata-containers/"*.toml \
      --replace-warn '/opt/kata/' "$out/"

    mkdir -p "$out/libexec/kata-containers"
    mv "$out/bin/containerd-shim-kata-v2" "$out/libexec/kata-containers/"
    mv "$out/bin/kata-runtime" "$out/libexec/kata-containers/"
    mv "$out/bin/qemu-system-x86_64" "$out/libexec/kata-containers/"

    for program in containerd-shim-kata-v2 kata-runtime; do
      makeWrapper "$out/libexec/kata-containers/$program" "$out/bin/$program" \
        --set KATA_CONF_FILE "/etc/kata-containers/configuration.toml"
    done
    makeWrapper \
      "$out/libexec/kata-containers/qemu-system-x86_64" \
      "$out/bin/qemu-system-x86_64" \
      --add-flags "-L $out/share/kata-qemu/qemu"
    ln -s containerd-shim-kata-v2 "$out/bin/containerd-shim-kata-qemu-v2"
    ln -s containerd-shim-kata-v2 "$out/bin/containerd-shim-kata-clh-v2"

    test "$(cat "$out/VERSION")" = "${version}"
    test -x "$out/bin/containerd-shim-kata-v2"
    test "$($out/bin/kata-runtime --version | awk 'NR == 1 { print $3 }')" = "${version}"
    test -f "$out/share/kata-containers/kata-containers.img"
    test -f "$out/share/kata-containers/vmlinux.container"

    runHook postInstall
  '';

  passthru = {
    inherit version;
    releaseAsset = "kata-go-static-${version}-amd64.tar.zst";
  };

  meta = {
    description = "Official Kata Containers Go runtime bundle";
    homepage = "https://github.com/kata-containers/kata-containers";
    changelog = "https://github.com/kata-containers/kata-containers/releases/tag/${version}";
    license = lib.licenses.asl20;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
