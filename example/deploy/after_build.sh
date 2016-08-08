#!/bin/bash

# This script is passed env vars of APP_NAME and DOCKER_TAG
# The DOCKER_TAG is the fully qualified "foo:12345" tag of the docker image
# Example..do an asset build inside the container

echo "Running $DOCKER_TAG to do a precompile"
docker run $DOCKER_TAG rake assets:precompile
