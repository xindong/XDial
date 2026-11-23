#!/usr/bin/env bash
# End-to-end test of "add my server" against isolated containers that stand in
# for a user's cloud server (real systemd, sshd and apt). Never targets a real
# server. Needs Docker with privileged containers and Internet access for apt.
#
#   scripts/test-cloudhost-e2e.sh [ubuntu:24.04 debian:12 ...]
#   XDIAL_E2E_PLATFORM=linux/amd64 scripts/test-cloudhost-e2e.sh   # other architecture
set -euo pipefail
cd "$(dirname "$0")/.."

bases=("$@")
[ ${#bases[@]} -gt 0 ] || bases=(ubuntu:24.04 ubuntu:22.04 ubuntu:20.04 debian:12)
platform="${XDIAL_E2E_PLATFORM:-}"
platform_args=()
[ -n "$platform" ] && platform_args=(--platform "$platform")
ssh_port=42222
ports=(43111 43112 43113)

make -s prepare-patched-go >/dev/null
gowork="$PWD/build/patched-go/xdial.work"

for base in "${bases[@]}"; do
  tag="xdial-cloudhost-test:${base//[:\/.]/-}${platform:+-${platform//\//-}}"
  name="xdial-cloudhost-e2e-${base//[:\/.]/-}"
  echo "== $base ${platform:-native}"
  if [ -n "$platform" ]; then
    # The classic builder resolves the base for the host architecture, so build
    # foreign images by running the setup in a container of that platform.
    builder="xdial-cloudhost-build-$$"
    docker run -d -q --platform "$platform" --name "$builder" "$base" sleep infinity >/dev/null
    docker cp test/cloudhost/setup.sh "$builder:/tmp/setup.sh"
    docker exec "$builder" sh /tmp/setup.sh >/dev/null
    docker exec "$builder" rm /tmp/setup.sh
    docker commit --change 'ENV container=docker' --change 'STOPSIGNAL SIGRTMIN+3' \
      --change 'CMD ["/sbin/init"]' "$builder" "$tag" >/dev/null
    docker rm -f "$builder" >/dev/null
  else
    docker build -q --build-arg BASE="$base" -t "$tag" test/cloudhost >/dev/null
  fi
  docker rm -f "$name" >/dev/null 2>&1 || true
  publish=(-p "127.0.0.1:$ssh_port:22")
  for port in "${ports[@]}"; do publish+=(-p "127.0.0.1:$port:$port/tcp" -p "127.0.0.1:$port:$port/udp"); done
  docker run -d ${platform_args[@]+"${platform_args[@]}"} --name "$name" --privileged --cgroupns=host \
    -v /sys/fs/cgroup:/sys/fs/cgroup:rw "${publish[@]}" "$tag" >/dev/null
  trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT
  for _ in $(seq 1 30); do
    docker exec "$name" systemctl is-active --quiet ssh 2>/dev/null && break
    sleep 1
  done
  # Shell metacharacters in the password prove it is never evaluated on the server.
  password="Xd-$(openssl rand -hex 6)'\"\$(touch /tmp/xdial-pwned-password);|&<>!"
  for user in deploy nopass plain; do
    printf '%s:%s\n' "$user" "$password" | docker exec -i "$name" chpasswd
  done
  XDIAL_E2E_SSH_ADDR="127.0.0.1:$ssh_port" XDIAL_E2E_PASSWORD="$password" XDIAL_E2E_CONTAINER="$name" \
  XDIAL_E2E_PORT_A="${ports[0]}" XDIAL_E2E_PORT_B="${ports[1]}" XDIAL_E2E_PORT_C="${ports[2]}" \
    GOWORK="$gowork" go test -tags "with_gvisor,with_utls,xdial_omit_tailssh,cloudhost_e2e" \
      -run TestCloudHostEndToEnd -count=1 -v -timeout 40m ./core/libbox/
  docker rm -f "$name" >/dev/null
  trap - EXIT
done
