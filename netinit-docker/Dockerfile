# Small, single-purpose image - see netinit-docker.sh's own header comment for what this
# does and why. Deliberately its own minimal image (not layered onto the consuming project
# or router itself) so the network_mode: host + NET_ADMIN + SYS_ADMIN + docker.sock trust
# tier this needs stays scoped to one tiny container instead of expanding an existing
# one's blast radius.
#
# That tier deserves a plain statement: a container holding docker.sock is already
# root-on-host equivalent, and mounting the socket :ro does NOT change that (the read-only
# flag applies to the inode, not to what may be written over the socket - a :ro-mounted
# socket happily serves container-create calls). SYS_ADMIN is added here for setns() into
# target network namespaces; it widens the blast radius of a bug in this script but does
# not raise the ceiling above what docker.sock already grants. Keeping this script small
# and auditable is the mitigation.
FROM alpine:3.20

# util-linux for nsenter (setns into a target's netns), nftables for the DOCKER-USER
# exemption, curl+jq to talk to the Docker API, iproute2 for `ip` both on the host side
# and inside the namespaces entered.
RUN apk add --no-cache nftables curl jq iproute2 util-linux

COPY netinit-docker.sh /netinit-docker.sh
RUN chmod +x /netinit-docker.sh

ENTRYPOINT ["/netinit-docker.sh"]
