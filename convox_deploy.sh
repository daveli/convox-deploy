#!/usr/bin/env bash
set -e
if [[ -z "$APP_NAME" || -z "$CONVOX_HOST" ]]; then
  echo "Usage: APP_NAME=your-app CONVOX_HOST=[url] ./convox_deploy.sh"
  echo "optional: DOCKER_COMPOSE=docker-compose.foo.yml"
  exit 1
fi

# Grab the convox password from the file, this assumes we've logged in before
if [[ -e $HOME/.convox/auth ]]
then
  CONVOX_PASSWORD=$(cat ~/.convox/auth | jq --arg host $CONVOX_HOST -r '.[$host]')
fi

# If you need to do anything special before the build, provide this file in your
# app repo and we'll invoke it
if [[ -e deploy/before_build.sh ]]
then
  deploy/before_build.sh
fi

export ECR=$(cat docker-compose.yml | grep image | cut -d":" -f2 | tr -d '[[:space:]]')
export ECR_NAME=$(echo $ECR | cut -d"/" -f2)

if [[ -z $ECR_NAME || -z $ECR ]]
then
  echo "Please make sure you have an image declaration in your docker-compose.yml pointing to an ECR repo"
  exit 1
fi

echo "ECR Repo: $ECR"

$(aws ecr get-login)

# This will only need to happen the first time. The 2>/dev/null ignores errors
set +e
aws ecr create-repository --repository-name $ECR_NAME 2>/dev/null
set -e

# Build the image and grab the image id. The image id is a unique tag identifying the contents
# We can use this tag to then tag the image to force a new push to the ECR repo

# If this is a git repo, use the git-sha for tagging. Otherwise, use the docker image id
IMAGE_ID=$(docker build -t $APP_NAME . | awk '/Successfully built/{print $NF}')

if [[ -e ".git" ]]
then
  RELEASE_ID=$(git rev-parse HEAD)
else
  RELEASE_ID=$IMAGE_ID
fi

# Tag the image with the image id
DOCKER_TAG=$APP_NAME:$IMAGE_ID

docker tag $DOCKER_TAG $APP_NAME:$RELEASE_ID
docker tag $DOCKER_TAG $ECR:$RELEASE_ID
docker tag $DOCKER_TAG $ECR:latest

if [[ -e deploy/after_build.sh ]]
then
  DOCKER_TAG=$DOCKER_TAG APP_NAME=$APP_NAME deploy/after_build.sh
fi

# Push the latest build
docker push $ECR:$RELEASE_ID

# Also tag it with the 'latest' tag
docker push $ECR:latest

# Edit the tag in the docker-compose
# Note: convox doesn't like the file living outside the current path
TEMPFILE=.docker-compose.yml
echo "Writing new docker tag to $TEMPFILE..."

sed "s/\(.*image:.*\)/\1:$RELEASE_ID/" ${DOCKER_COMPOSE:-docker-compose.yml} > $TEMPFILE

GIT_DESCRIPTION=$(git log --oneline | head -1)

echo "Building $APP_NAME release..."
convox build --file $TEMPFILE --app $APP_NAME --description "$GIT_DESCRIPTION"

echo "Grabbing last release from API..."
# These exports are needed so that the api command below has access to them
export CONVOX_HOST
export CONVOX_PASSWORD
RELEASE_ID=$(convox api get /apps/$APP_NAME/releases | jq -r 'sort_by(.created) | reverse[0] | .id')

# Any additional hooks go here
if [[ -e deploy/before_release.sh ]]
then
  APP_NAME=$APP_NAME RELEASE_ID=$RELEASE_ID deploy/before_release.sh
fi

echo "Deploying $RELEASE_ID to $CONVOX_HOST..."
convox releases promote --app $APP_NAME --wait $RELEASE_ID

# Cleanup
rm $TEMPFILE

