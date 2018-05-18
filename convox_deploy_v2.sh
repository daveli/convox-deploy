#!/bin/bash

# This script is used to deploy apps with a specially tweaked docker-compose.yml file
# and a Convox account.

# Exit immediately if a command exits with a non-zero status.
set -e

declare TAG='<TAG>'
declare DOCKER_COMPOSE=${DOCKER_COMPOSE:-docker-compose.yml}
declare BOLD=$(tput bold)
declare NORMAL=$(tput sgr0)

export TEMPFILE=.$DOCKER_COMPOSE
export GIT_HASH=$(git rev-parse HEAD)
export GIT_DESCRIPTION=$(git log --oneline | head -1)
export GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
export APP_NAME=${APP_NAME:-${PWD##*/}}
export AWS_DEFAULT_REGION=us-east-1

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
        echo "Usage: RACK_NAME=rack-name APP_NAME=your-app CONVOX_HOST=[full-rack.url.com] CONVOX_PASSWORD=[password] ./convox_deploy.sh"
        echo "optional: DOCKER_COMPOSE=docker-compose.foo.yml"
        exit 1
    fi

  #hack to get convox to pick up env vars
  export CONVOX_HOST
  export CONVOX_PASSWORD
}

check_git_repo_requirements() {
    if ! git diff-index --quiet HEAD --; then
        echo "${BOLD}Your git repo has untracked changes, please fix this before commiting code by accident.${NORMAL}"
        git status
        exit 1
    fi
}

replace_tag_with_git_hash() {
  grep -q "image:" $DOCKER_COMPOSE || (echo "ERROR: Missing 'image:' directive in docker-compos.yml; It should look like 'image: 12345.dkr.ecr.us-east-1.amazonaws.com/app-name:container-name'" && exit 1)

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
        APP_ENV=$APP_ENV \
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
        APP_ENV=$APP_ENV \
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
        APP_ENV=$APP_ENV \
        deploy/before_release.sh
    fi
}

log_into_aws_ecr()  {
    if [[ -z "$SKIP_ECR_AUTH" ]];
    then
      $(aws ecr get-login --no-include-email)
    else
      echo "Skipping ECR login..."
    fi
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
        echo "docker tag $ECR:$SERVICE_NAME.$GIT_HASH $ECR:$SERVICE_NAME.latest"
        docker tag $ECR:$SERVICE_NAME.$GIT_HASH $ECR:$SERVICE_NAME.latest

        echo "Running docker push $ECR:$SERVICE_NAME.$GIT_HASH"
        docker push $ECR:$SERVICE_NAME.$GIT_HASH

        echo "Pushing latest tag"
        docker push $ECR:$SERVICE_NAME.latest

    done <<< "$ECR_LIST"
}

strip_build_options() {
    # remove the build part of the docker compose file, using ruby so we can parse the yaml and remove arbitrary keys from that section
    ruby -e 'require "yaml"; yaml = YAML.load_file(ENV["TEMPFILE"]); yaml["services"].each { |_, service| service.delete("build") }; File.open(ENV["TEMPFILE"], "w") {|f| f.write yaml.to_yaml }'
}

build_convox_release() {
    convox build --file $TEMPFILE --rack $RACK_NAME --app $APP_NAME --description "$GIT_DESCRIPTION"
    #convox build --file $TEMPFILE --incremental --rack $RACK_NAME --app $APP_NAME --description "$GIT_DESCRIPTION"
}


get_latest_release_id() {
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

set_revision_env() {
   echo "Setting REVISION=$GIT_HASH"
   convox env set REVISION=$GIT_HASH --app $APP_NAME --rack $RACK_NAME --id
}

script_warning() {
  echo "${BOLD}"
  echo "WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING"
  echo ""
  echo ""
  echo ""
  echo ""
  echo ""
  echo ""
  echo ""
  echo "You are probably manually running this in your repo right now.  We would like to"
  echo "to sunset this script.  Please consider creating a Convox Job in Jenkins to deploy service"
  echo "via Verbo.  Here is a link on how to do it: https://doc.reverb.com/convox/#jenkins"
  echo ""
  echo ""
  echo "Also if there is a particular reason you need to keep the script around run locally please let #team-infra know."
  echo ""
  echo ""
  echo ""
  echo ""
  echo ""
  echo "WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING WARNING"
  echo "${NORMAL}"
}


main() {
    script_warning

    check_arg_requirements

    replace_tag_with_git_hash

    set_revision_env

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
