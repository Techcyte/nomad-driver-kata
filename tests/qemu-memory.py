import json
import subprocess
import sys
import tempfile

qemu = sys.argv[1]


def alignment(
    backend, expected, object_option="-object", object_id="entire-guest-memory-share"
):
    commands = [
        {"execute": "qmp_capabilities"},
        {
            "execute": "qom-get",
            "arguments": {"path": f"/objects/{object_id}", "property": "align"},
            "id": "alignment",
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


backend = "memory-backend-file,id=entire-guest-memory-share,mem-path=/dev/shm,size=4M,share=on"
alignment(backend, 2097152)
alignment(backend + ",align=4194304", 4194304)
alignment(
    "memory-backend-file,share=on,size=4M,mem-path=/dev/shm,id=entire-guest-memory-share",
    2097152,
)
alignment(backend, 2097152, "--object")
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
