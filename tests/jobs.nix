# Shared Nomad job specifications used by both the sudo-based integration
# script (tests/integration.nix) and the NixOS VM test (tests/integration-vm.nix).
# Pure data — no environment assumptions.
{ pkgs }:
{
  single = pkgs.writeText "test-job.nomad.hcl" ''
    job "kata-driver-test" {
      type        = "batch"
      datacenters = ["dc1"]

      group "test" {
        restart {
          attempts = 2
          delay    = "1s"
          interval = "10m"
          mode     = "delay"
        }

        task "hello" {
          driver = "kata"

          config {
            image       = "docker.io/library/busybox:latest"
            command     = "sh"
            args        = ["-c", "echo KATA_DRIVER_OK && cat /proc/version && sleep 60"]
            extra_hosts = ["mydb:10.0.0.5", "cache:10.0.0.6"]
          }

          resources {
            cpu    = 100
            memory = 64
          }
        }

        task "sidecar" {
          driver = "kata"

          lifecycle {
            hook    = "prestart"
            sidecar = true
          }

          config {
            image      = "docker.io/library/busybox:latest"
            pids_limit = 256
            command    = "sh"
            args       = ["-c", "echo SIDECAR_OK; sleep 3600"]
          }

          resources {
            cpu    = 50
            memory = 32
          }
        }
      }
    }
  '';

  exitIo = pkgs.writeText "exit-io-job.nomad.hcl" ''
    job "kata-exit-io" {
      type        = "batch"
      datacenters = ["dc1"]

      group "test" {
        restart {
          attempts = 0
          mode     = "fail"
        }

        reschedule {
          attempts  = 0
          unlimited = false
        }

        task "output" {
          driver = "kata"

          config {
            image   = "docker.io/library/busybox:latest"
            command = "sh"
            args = [
              "-c",
              "i=0; while [ $i -lt 4096 ]; do printf 'STDOUT-%04d-abcdefghijklmnopqrstuvwxyz0123456789\\n' $i; printf 'STDERR-%04d-ABCDEFGHIJKLMNOPQRSTUVWXYZ9876543210\\n' $i >&2; i=$((i + 1)); done; exit 42",
            ]
          }

          resources {
            cpu    = 100
            memory = 64
          }
        }
      }
    }
  '';

  stop = pkgs.writeText "stop-job.nomad.hcl" ''
    job "kata-stop" {
      type        = "service"
      datacenters = ["dc1"]

      group "test" {
        restart {
          attempts = 0
          mode     = "fail"
        }

        reschedule {
          attempts  = 0
          unlimited = false
        }

        task "sleeper" {
          driver = "kata"

          config {
            image   = "docker.io/library/busybox:latest"
            command = "sh"
            args    = ["-c", "trap 'echo TERM_SEEN; exit 17' TERM; echo STOP_READY; while :; do sleep 1; done"]
          }

          kill_signal  = "SIGTERM"
          kill_timeout = "5s"

          resources {
            cpu    = 100
            memory = 64
          }
        }
      }
    }
  '';

  lifecycle = pkgs.writeText "lifecycle-job.nomad.hcl" ''
    job "kata-lifecycle" {
      type        = "batch"
      datacenters = ["dc1"]

      group "test" {
        restart {
          attempts = 0
          mode     = "fail"
        }

        reschedule {
          attempts  = 0
          unlimited = false
        }

        task "once" {
          driver = "kata"

          config {
            image   = "docker.io/library/busybox:latest"
            command = "sh"
            args    = ["-c", "echo LIFECYCLE_OK"]
          }

          resources {
            cpu    = 100
            memory = 64
          }
        }
      }
    }
  '';

  multiVm = pkgs.writeText "multi-vm-job.nomad.hcl" ''
    job "kata-multi-vm" {
      type        = "batch"
      datacenters = ["dc1"]

      group "server" {
        network {
          mode = "bridge"
          port "http" {
            to = 8080
          }
        }

        task "web" {
          driver = "kata"
          config {
            image   = "docker.io/library/busybox:latest"
            command = "sh"
            args    = ["-c", "echo WEB_OK && mkdir -p /www && echo SERVER_OK > /www/index.html && httpd -f -p 8080 -h /www"]
          }
          resources {
            cpu    = 100
            memory = 128
          }
        }

        task "web-sidecar" {
          driver = "kata"
          lifecycle {
            hook    = "prestart"
            sidecar = true
          }
          config {
            image   = "docker.io/library/busybox:latest"
            command = "sh"
            args    = ["-c", "echo WEB_SIDECAR_OK; sleep 3600"]
          }
          resources {
            cpu    = 50
            memory = 64
          }
        }
      }

      group "client" {
        network {
          mode = "bridge"
        }

        task "fetcher" {
          driver = "kata"
          config {
            image   = "docker.io/library/busybox:latest"
            command = "sh"
            args    = ["-c", "echo FETCHER_OK; sleep 3600"]
          }
          resources {
            cpu    = 100
            memory = 128
          }
        }

        task "fetcher-sidecar" {
          driver = "kata"
          lifecycle {
            hook    = "prestart"
            sidecar = true
          }
          config {
            image   = "docker.io/library/busybox:latest"
            command = "sh"
            args    = ["-c", "echo FETCHER_SIDECAR_OK; sleep 3600"]
          }
          resources {
            cpu    = 50
            memory = 64
          }
        }
      }
    }
  '';
}
