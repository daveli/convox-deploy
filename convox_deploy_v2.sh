#!/bin/bash

# This script is used to deploy apps with a specially tweaked docker-compose.yml file
# and a Convox account.

# Exit immediately if a command exits with a non-zero status.
set -e

declare TAG='<TAG>'
declare DOCKER_COMPOSE=${DOCKER_COMPOSE:-docker-compose.yml}
declare TEMPFILE=.$DOCKER_COMPOSE
declare BOLD=$(tput bold)
declare NORMAL=$(tput sgr0)

export GIT_HASH=$(git rev-parse HEAD)
export GIT_DESCRIPTION=$(git log --oneline | head -1)
export GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
export RACK_NAME=${RACK_NAME:-$(convox switch)}
export APP_NAME=${APP_NAME:-${PWD##*/}}

check_arg_requirements() {
    # Grab the convox password from the file, this assumes we've logged in before
    if [[ -z "$CONVOX_HOST" ]]; then
        echo "Please set CONVOX_HOST to the full hostname of your rack"
        exit 1
    fi

    if [[ -e $HOME/.convox/auth ]]; then
      CONVOX_PASSWORD=$(cat ~/.convox/auth | jq --arg host $CONVOX_HOST -r '.[$host]')
    fi

    if [[ -z "$APP_NAME" || -z "$CONVOX_PASSWORD" || -z "$RACK_NAME" ]]; then
        echo "Usage: APP_NAME=your-app CONVOX_HOST=[url] CONVOX_PASSWORD=[password] ./convox_deploy.sh"
        echo "optional: DOCKER_COMPOSE=docker-compose.foo.yml"
        exit 1
    fi
}

check_git_repo_requirements() {
    if ! git diff-index --quiet HEAD --; then
        echo "${BOLD}Your git repo has untracked changes, please fix this before commiting code by accident.${NORMAL}"
        git status
        exit 1
    fi
}

replace_tag_with_git_hash() {
  sed "s/\(.*image:.*\)/\1.$GIT_HASH/" $DOCKER_COMPOSE > $TEMPFILE
}

run_before_build_script() {
    if [[ -e deploy/before_build.sh ]]
    then
        GIT_HASH=$GIT_HASH \
        GIT_DESCRIPTION=$GIT_DESCRIPTION \
        GIT_BRANCH=$GIT_BRANCH \
        RACK_NAME=$RACK_NAME \
        APP_NAME=$APP_NAME \
        deploy/before_build.sh
    fi
}

run_after_build_script() {
    if [[ -e deploy/after_build.sh ]]
    then
        GIT_HASH=$GIT_HASH \
        GIT_DESCRIPTION=$GIT_DESCRIPTION \
        GIT_BRANCH=$GIT_BRANCH \
        RACK_NAME=$RACK_NAME \
        APP_NAME=$APP_NAME \
        deploy/after_build.sh
    fi
}

run_before_release_script() {
    if [[ -e deploy/before_release.sh ]]
    then
        GIT_HASH=$GIT_HASH \
        GIT_DESCRIPTION=$GIT_DESCRIPTION \
        GIT_BRANCH=$GIT_BRANCH \
        RACK_NAME=$RACK_NAME \
        APP_NAME=$APP_NAME \
        RELEASE_ID=$RELEASE_ID \
        deploy/before_release.sh
    fi
}

log_into_aws_ecr()  {
    $(aws ecr get-login)
}

build_docker_images() {
    docker-compose -f $TEMPFILE build
}

push_images_to_docker() {
    ECR_LIST=$(cat $DOCKER_COMPOSE | grep image:)
    while read -r line; do

        SERVICE_NAME=$(echo $line | cut -d":" -f3 | cut -d"." -f1)
        ECR=$(echo $line | cut -d":" -f2 | tr -d '[[:space:]]')
        ECR_NAME=$(echo $ECR | cut -d"/" -f2)

        echo "${BOLD}Pushing local build of service $SERVICE_NAME to ECR${NORMAL}"

        # This will only need to happen the first time. The 2>/dev/null ignores errors
        aws ecr create-repository --repository-name $ECR_NAME 2>/dev/null || true

        # Push the latest build
        echo "Running docker push $ECR:$SERVICE_NAME.$GIT_HASH"
        docker push $ECR:$SERVICE_NAME.$GIT_HASH

    done <<< "$ECR_LIST"
}

strip_build_options() {
    sed -i.bak '/build:/d; /context:/d; /dockerfile:/d' $TEMPFILE
}

build_convox_release() {
    convox build --file $TEMPFILE --incremental --rack $RACK_NAME --app $APP_NAME --description "$GIT_DESCRIPTION"
}

get_latest_release_id() {
    export CONVOX_HOST
    export CONVOX_PASSWORD
    export RELEASE_ID=$(convox api get /apps/$APP_NAME/releases | jq -r 'sort_by(.created) | reverse[0] | .id')
}

promote_release() {
    convox releases promote --rack $RACK_NAME --app $APP_NAME --wait $RELEASE_ID
}

cleanup () {
    rm -f $TEMPFILE
    rm -f $TEMPFILE.bak
}

silence_if_necessary() {
    if [ -n "$SILENT" ]; then
        "$@" > /dev/null 2> /dev/null
    else
        "$@"
    fi
}

echo_with_feedback() {
    if [ -n "$SILENT" ]; then
        echo -n "${BOLD}$2${NORMAL}"
        if silence_if_necessary $1; then
            echo "OK"
        else
            echo " ❌"
            exit 1
        fi
    else
        echo "${BOLD}$2${NORMAL}"
        $1
    fi
}

# Sets an env variable in the convox build so it's easy to identify what build is running
# Can be used by in-app health checks
#set_revision_env() {
  # This is currently disabled because it creates a release based on the current running release,
  # whereas we want to set this on the new release prior to releasing it
  # see: https://github.com/convox/rack/issues/962

  # convox env set REVISION=$GIT_HASH --app $APP_NAME --rack $RACK_NAME
#}

main() {
    check_arg_requirements

    replace_tag_with_git_hash

    echo_with_feedback \
        run_before_build_script \
        "Running before_build script..."

    echo_with_feedback \
        build_docker_images \
        "Running docker-compose build $SERVICE_NAME..."

    echo_with_feedback \
        run_after_build_script \
        "Running after_build script..."

    echo_with_feedback \
        log_into_aws_ecr \
        "Logging into Amazon ECR..."

    echo_with_feedback \
        push_images_to_docker \
        "Pushing local builds to AWS ECR..."

    strip_build_options

    echo_with_feedback \
        build_convox_release \
        "Building $APP_NAME release..."

    # This is disabled due to a bug - see set_revision_env() for more inof
    #
    # echo_with_feedback \
    #     set_revision_env \
    #     "Setting REVISION=$GIT_HASH"

    echo_with_feedback \
        get_latest_release_id \
        "Grabbing last release from API..."

    echo_with_feedback \
        run_before_release_script \
        "Running before_release script..."

    echo_with_feedback \
        promote_release \
        "Promoting $RELEASE_ID to $CONVOX_HOST..."

    echo "${BOLD}✅  Deployment complete!${NORMAL}"
}

trap cleanup EXIT

main "$@"
