# An isolated stand-in for a user's cloud server: real systemd, sshd, apt.
# Used only by scripts/test-cloudhost-e2e.sh; passwords are set at run time.
ARG BASE=ubuntu:24.04
FROM ${BASE}
ENV container=docker
COPY setup.sh /tmp/setup.sh
RUN sh /tmp/setup.sh && rm /tmp/setup.sh
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
