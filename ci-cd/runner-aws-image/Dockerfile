FROM ghcr.io/actions/actions-runner:latest

USER root

# Install AWS CLI v2 with verbose output
RUN apt-get update && \
    apt-get install -y unzip curl && \
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip" && \
    unzip awscliv2.zip && \
    ./aws/install && \
    rm -rf awscliv2.zip aws && \
    aws --version

# Install Node.js 20.19.5 via nvm
ENV NVM_DIR=/usr/local/nvm
ENV NODE_VERSION=20.19.5

RUN mkdir -p $NVM_DIR && \
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash && \
    . $NVM_DIR/nvm.sh && \
    nvm install $NODE_VERSION && \
    nvm alias default $NODE_VERSION

# Add node and npm to PATH
ENV PATH=$NVM_DIR/versions/node/v$NODE_VERSION/bin:$PATH

# Verify installation
RUN node --version && npm --version

USER runner

ENTRYPOINT ["/bin/bash", "-c", "echo 'Runner starting...' && exec /home/runner/run.sh"]
