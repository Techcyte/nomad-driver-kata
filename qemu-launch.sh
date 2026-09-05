#!/bin/bash

# Kata's shared tmpfs RAM needs 2 MiB alignment to permit x86_64 THP mappings.
# QEMU's file-backed RAM defaults to the backing filesystem's page size; its
# guard-page reservation can leave tmpfs RAM unaligned even when THP is enabled.
# Discussion: https://github.com/kata-containers/kata-containers/issues/10997
# Exact guard-page mechanism: https://lists.openwall.net/linux-kernel/2018/04/23/103
# Alignment permits huge mappings; host tmpfs THP policy must allow them too.
# Only guest RAM is adjusted, never the read-only image/PMEM backend.
args=()
object=false
for arg in "$@"; do
	if "$object"; then
		case ",$arg," in
		,memory-backend-file,*)
			if [[ ",$arg," == *,id=entire-guest-memory-share,* &&
				",$arg," == *,mem-path=/dev/shm,* &&
				",$arg," == *,share=on,* &&
				",$arg," != *,align=* ]]; then
				arg+=",align=2097152"
			fi
			;;
		esac
	fi
	object=false
	if [[ "$arg" == -object || "$arg" == --object ]]; then
		object=true
	fi
	args+=("$arg")
done
exec @qemu@ -L @data@ "${args[@]}"
