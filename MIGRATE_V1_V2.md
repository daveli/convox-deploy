## Modify your docker-compose.yml

When in doubt, [look at the example](example/v2/docker-compose.yml)

1. Add `version: "2"` at the top
2. Make sure you have a `services` header and all the existing containers are indented underneath that.

        version: "2"
        services:
          mycontainer: 
            ...

3. Add the container name to each `image` declaration underneath each container, so if it was "ecr.amazonaws.com/appname" before, it becomes "ecr.amazonaws.com/appname:containername"
4. Change `build: .` to:

        build:
          context: .

## Change your deploy script

You already have something calling `convox_deploy.sh`. Change it to `convox_deploy_v2.sh`
