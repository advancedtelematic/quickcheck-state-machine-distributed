FROM debian:stretch-slim AS builder

RUN apt-get update \
 && apt-get install --no-install-recommends -y \
    build-essential=12.3 \
    libffi-dev=3.2.* \
    libgmp-dev=2:6.1.* \
    zlib1g-dev=1:1.2.* \
    curl=7.52.* \
    ca-certificates=20161130+nmu1 \
    git=1:2.11.* \
    netbase=5.4 \
 && rm -rf /var/lib/apt/lists/*

RUN curl -sSL https://get.haskellstack.org/ | sh

WORKDIR /opt/distributed-tests-prototype/
COPY stack.yaml package.yaml /opt/distributed-tests-prototype/
RUN stack setup
RUN stack --no-terminal test --only-dependencies

COPY . /opt/distributed-tests-prototype/
RUN stack install --ghc-options="-fPIC"

# RUN curl -sSL https://github.com/upx/upx/releases/download/v3.94/upx-3.94-amd64_linux.tar.xz \
#   | tar -x --xz --strip-components 1 upx-3.94-amd64_linux/upx \
#   && ./upx --best --ultra-brute /root/.local/bin/distributed-tests-prototype

FROM debian:stretch-slim AS distro
COPY --from=builder /root/.local/bin/distributed-tests-prototype /bin/
ENTRYPOINT ["/bin/distributed-tests-prototype"]