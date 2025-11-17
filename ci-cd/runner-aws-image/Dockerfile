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

USER runner

ENTRYPOINT ["/bin/bash", "-c", "echo 'Runner starting...' && exec /home/runner/run.sh"]
