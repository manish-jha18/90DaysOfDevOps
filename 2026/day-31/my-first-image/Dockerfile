# Day 31 Task 1 - my first Dockerfile
FROM ubuntu:22.04

# -y answers the prompt, DEBIAN_FRONTEND stops apt asking about timezones
# clearing the apt lists in the SAME RUN keeps them out of the layer
RUN apt-get update && \
    apt-get install -y curl && \
    rm -rf /var/lib/apt/lists/*

CMD ["echo", "Hello from my custom image!"]
