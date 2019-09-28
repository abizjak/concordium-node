# syntax=docker/dockerfile:experimental
FROM 192549843005.dkr.ecr.eu-west-1.amazonaws.com/concordium/base:0.2
COPY . /build-project
WORKDIR /build-project
COPY ./scripts/init.build.env.sh ./init.build.env.sh
COPY ./scripts/gen_data.sh ./gen_data.sh
COPY ./scripts/start.sh ./start.sh
COPY ./scripts/genesis-data ./genesis-data
ENV LD_LIBRARY_PATH=/usr/local/lib
RUN --mount=type=ssh ./init.build.env.sh 
RUN --mount=type=ssh cargo build --release --features=instrumentation,benchmark,profiling,elastic_logging,collector && \
    cp /build-project/target/release/p2p_client-cli /build-project/target/release/p2p_bootstrapper-cli /build-project/ && \
    cp /build-project/target/release/node-collector /build-project/ && \
    cp /build-project/target/release/node-collector-backend /build-project/ && \
    cargo clean && \
    # Sanitizer build
    #rustup install nightly-2019-03-22 && \
    #rustup default nightly-2019-03-22 && \
    #rustup component add rust-src --toolchain nightly-2019-03-22-x86_64-unknown-linux-gnu && \
    #RUSTFLAGS="-Z sanitizer=address" cargo build --target x86_64-unknown-linux-gnu --features=instrumentation && \
    #RUSTFLAGS="-Z sanitizer=address" cargo test --no-run --target x86_64-unknown-linux-gnu --features=instrumentation && \
    #mkdir -p sanitized && \
    #mv target/x86_64-unknown-linux-gnu/debug/p2p_client-cli sanitized/ && \
    #mv target/x86_64-unknown-linux-gnu/debug/p2p_bootstrapper-cli sanitized/ && \
    #cp target/x86_64-unknown-linux-gnu/debug/address_sanitizer* sanitized/ && \
    #cp target/x86_64-unknown-linux-gnu/debug/p2p_client-* sanitized/ && \
    cargo clean && \
    #rustup default 1.38.0  && \
    # Clean
    rm -rf ~/.cargo ~/.rustup && \
    rm -rf deps src benches tests src concordium-common && \
    rm -rf scripts rustfmt.toml README.md p2p.capnp && \ 
    rm -rf init.build.env.sh .gitmodules .gitlab-ci.yml && \ 
    rm -rf .gitignore .gitattributes .dockerignore && \
    rm -rf consensus-sys Cargo.toml Cargo.lock build.rs && \
    rm -rf concordium-dns concordium-global-state && \
    rm -rf scripts/build-all-docker.sh && \
    chmod +x ./start.sh
