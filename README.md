## Why this exists: On-Cluster vs Off-Cluster deploys

By default a "convox deploy" command will send your docker build to the cluster in order to service it there. This has a number of disadvantages:

1. It taxes the cluster (which is running possibly production containers) with a docker build
2. Depending on the number of nodes in the cluster and their ephemeral nature you may hit a stale cache and do a full from-scratch build

To solve this, we prefer building off-cluster, meaning building on your local machine (or jenkins). To do this with convox requires a minor hack in that we have to supply the repository name and tag in docker-compose.yml and then replace the artificial `TAG` with the actual docker tag during the build.

We have also provided a number of lifecycle hooks for interesting things that people may want to run before/after the build, or prior to promoting the release, so that it's easy to adapt to common patterns such as running database migrations in the new container prior to release.


## Getting Started

1. Copy convox_deploy.sh to the root of your repo.
2. Provide a Dockerfile and a docker-compose.yml. To test that these work as expected, use `convox start` to load up your app. Example files have been provided in this repo in `/example`. Also provide a `.dockerignore` to make sure you ignore `.git` and any other temporary dirs that should not be deployed.
3. Make sure that your docker-compose.yml points to an ECR repo in its `image` directive. See the example.

If your app needs a dev-specific docker-compose, create `docker-compose.dev.yml` (convention, unrelated to this deploy script)

## Build lifecycle

1. If your app needs to do anything prior to the docker build, such as asset precompile, we will call out to `deploy/before_build.sh`
2. We now call a regular docker build
3. If you need to do anything after the container is built, for example building assets inside the container, provide a `deploy/after_build.sh` script which is passed `APP_NAME` and `DOCKER_TAG`. You can now for example do something like `docker run $DOCKER_TAG rake assets:precompile` to generate your assets inside the container.
4. We push the build to ECR and trigger a convox build which pulls our image into convox's ECR repo
5. If your app needs to do anything special such as running migrations prior to making the release live, provide a `deploy/before_release.sh` (make sure to `chmod +x` it). This file can access the variables `$APP_NAME` and `$RELEASE_ID`. We've provided an example.
6. After your app's hooks complete, we tell convox to promote the release, which triggers an ECS promotion. This may last a few minutes depending on the number of containers and free capacity on the cluster.0


## Testing your deploy locally

To test your convox deploy, first create your app. For ease of use it's a good practice to name your app the same as the name of the directory it lives in. That way other convox commands will work without an additional --app argument.

    convox apps create your-app
    convox env set FOO=bar BAZ=quux  # Set any envs that need to be set

Now fire up the deploy

    CONVOX_HOST=host_url CONVOX_PASSWORD=password APP_NAME=your-app ./convox_deploy.sh

## Move deploy to Jenkins

To create auto-deploys for your app, create a Jenkins job with the shell command you used in the local deploy. Set it to auto-poll github every minute (cron schedule `* * * * *`)
Add the CONVOX_HOST and CONVOX_PASSWORD params into a shell step, something like this:

    export CONVOX_HOST=blah
    export CONVOX_PASSWORD=blah
    export APP_NAME=your-app
    ./convox_deploy.sh
