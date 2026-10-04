import json
import subprocess
import sys
import tempfile

qemu = sys.argv[1]
managed_memory = "--unmanaged-only" not in sys.argv


def alignment(
    backend,
    expected,
    object_option="-object",
    object_id="entire-guest-memory-share",
    expected_path=None,
):
    commands = [
        {"execute": "qmp_capabilities"},
        {
            "execute": "qom-get",
            "arguments": {"path": f"/objects/{object_id}", "property": "align"},
            "id": "alignment",
        },
        {
            "execute": "qom-get",
            "arguments": {"path": f"/objects/{object_id}", "property": "mem-path"},
            "id": "memory-path",
        },
        {"execute": "quit"},
    ]
    result = subprocess.run(
        [
            qemu,
            "-machine",
            "none",
            "-display",
            "none",
            "-nodefaults",
            "-qmp",
            "stdio",
            object_option,
            backend,
        ],
        input="\n".join(json.dumps(command) for command in commands) + "\n",
        capture_output=True,
        text=True,
        timeout=15,
    )
    assert result.returncode == 0, result.stderr
    assert result.stderr == "", result.stderr
    responses = [json.loads(line) for line in result.stdout.splitlines()]
    assert not any("error" in response for response in responses), responses
    actual = next(
        response["return"]
        for response in responses
        if response.get("id") == "alignment"
    )
    assert actual == expected, (backend, actual, expected)
    actual_path = next(
        response["return"]
        for response in responses
        if response.get("id") == "memory-path"
    )
    if expected_path is None:
        expected_path = next(
            part.removeprefix("mem-path=")
            for part in backend.split(",")
            if part.startswith("mem-path=")
        )
    assert actual_path == expected_path, (backend, actual_path, expected_path)


backend = "memory-backend-file,id=entire-guest-memory-share,mem-path=/dev/shm,size=4M,share=on"
if "--reject-managed-only" in sys.argv:
    result = subprocess.run(
        [qemu, "-machine", "none", "-display", "none", "-object", backend],
        capture_output=True,
        text=True,
        timeout=15,
    )
    assert result.returncode == 1, (result.returncode, result.stderr)
    assert result.stdout == "", result.stdout
    assert result.stderr == (
        "Kata guest RAM requires /run/kata-memory to be a mounted tmpfs directory; "
        "mount the dedicated guest RAM tmpfs before launching QEMU\n"
    ), result.stderr
    print("Unsafe guest memory backing rejected")
    sys.exit(0)
if managed_memory:
    alignment(backend, 2097152, expected_path="/run/kata-memory")
    alignment(backend + ",align=4194304", 4194304, expected_path="/run/kata-memory")
    alignment(
        "memory-backend-file,share=on,size=4M,mem-path=/dev/shm,id=entire-guest-memory-share",
        2097152,
        expected_path="/run/kata-memory",
    )
    alignment(backend, 2097152, "--object", expected_path="/run/kata-memory")
alignment(backend.replace("share=on", "share=off"), 0)
alignment(backend.replace("entire-guest-memory-share", "rootfs"), 0, object_id="rootfs")
alignment(
    backend.replace("entire-guest-memory-share", "entire-guest-memory-share-other"),
    0,
    object_id="entire-guest-memory-share-other",
)
with tempfile.TemporaryDirectory(prefix="qemu memory ") as directory:
    alignment(backend.replace("/dev/shm", directory), 0)
print("QEMU shared-memory alignment checks passed")
