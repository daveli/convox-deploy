#!/usr/bin/env bash
if [[ -z "$APP_NAME" || -z "$CONVOX_HOST" ]]; then
  echo "Usage: APP_NAME=your-app CONVOX_HOST=[url] ./convox_deploy.sh"
  echo "optional: DOCKER_COMPOSE=docker-compose.foo.yml"
  exit 1
fi

# Grab the convox password from the file, this assumes we've logged in before
if [[ -e $HOME/.convox/auth ]]
then
  CONVOX_PASSWORD=$(cat ~/.convox/auth | jq --arg host $HOST -r '.[$host]')
fi

# If you need to do anything special before the build, provide this file in your
# app repo and we'll invoke it
if [[ -e deploy/before_build.sh ]]
then
  deploy/before_build.sh
fi

export ECR=$(cat docker-compose.yml | grep image | cut -d":" -f2 | tr -d '[[:space:]]')
export ECR_NAME=$(echo $ECR | cut -d"/" -f2)

echo "Working with ECR $ECR and NAME $ECR_NAME"

$(aws ecr get-login)

# This will only need to happen the first time. The 2>/dev/null ignores errors
aws ecr create-repository --repository-name $ECR_NAME 2>/dev/null

# Build the image and grab the image id. The image id is a unique tag identifying the contents
# We can use this tag to then tag the image to force a new push to the ECR repo
IMAGE_ID=$(docker build -t $APP_NAME . | awk '/Successfully built/{print $NF}')
DOCKER_TAG="$APP_NAME:$IMAGE_ID"

# Tag the image with the image id
docker tag $DOCKER_TAG $ECR:$IMAGE_ID

if [[ -e deploy/after_build.sh ]]
then
  DOCKER_TAG=$DOCKER_TAG APP_NAME=$APP_NAME deploy/after_build.sh
fi

# Push the latest build
docker push $ECR:$IMAGE_ID

# Edit the tag in the docker-compose
# Note: convox doesn't like the file living outside the current path
TEMPFILE=.docker-compose.yml
echo "Writing new docker tag to $TEMPFILE..."

sed "s/\(.*image:.*\)/\1:$IMAGE_ID/" ${DOCKER_COMPOSE:-docker-compose.yml} > $TEMPFILE

GIT_DESCRIPTION=$(git log --oneline | head -1)

echo "Building $APP_NAME release..."
convox build --file $TEMPFILE --incremental --app $APP_NAME --description "$GIT_DESCRIPTION"

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
