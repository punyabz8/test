#!/bin/bash

# shellcheck disable=SC2059

set -e

#####
##
## Detect changes in docker/images directory and identify the list of images
## that have changed. If a change is detected, the docker image is built
## with a new tag and then published to Amazon ECR registry.
##
## Image Tag Convention
##
## Major Release (master):
##
## helloworld@1.0.1
## helloworld@1.0.0
##
## Pre-Release (branches other than master):
##
## helloworld@1.0.1-dev.20190827085122
## helloworld@1.0.0-dev.20190727063712
## helloworld@1.0.0-staging.20190621085122
##
#####

green="\033[32m"
reset="\033[0m"

printfln() {
  printf "\n$1\n"
}

BRANCH=$(if [ "$TRAVIS_PULL_REQUEST" == "false" ]; then echo "$TRAVIS_BRANCH"; else echo "$TRAVIS_PULL_REQUEST_BRANCH"; fi)

export BRANCH

# TRAVIS_COMMIT_RANGE is usually invalid for force pushes - ignore such values
# This is just a safe guard against force push on the main branch(s).
if [ -n "$TRAVIS_COMMIT_RANGE" ]; then
  if ! git rev-list "$TRAVIS_COMMIT_RANGE" > /dev/null; then
    TRAVIS_COMMIT_RANGE=
  fi
fi

# Find all the commits for the current build
if [ -n "$TRAVIS_COMMIT_RANGE" ]; then
  # $TRAVIS_COMMIT_RANGE contains "..." instead of ".."
  # https://github.com/travis-ci/travis-ci/issues/4596
  PR_COMMIT_RANGE="${TRAVIS_COMMIT_RANGE/.../..}"
fi

comment_on_pr() {
  echo -e "$1" > create_task_def_info.txt
  if [ "$TRAVIS_PULL_REQUEST" != "false" ]; then
    comments=$(hub api repos/"$TRAVIS_REPO_SLUG"/issues/"$TRAVIS_PULL_REQUEST"/comments)
    # Get last comment ID by laudio-bot
    comment_id=$(echo "$comments" | jq -c ".[] | select(.user.login==\"laudio-bot\")" | jq ".id" | tail -n 1) || true

    if [ -z "$comment_id" ]; then
      # Initial new comment on PR.
      hub api repos/"$TRAVIS_REPO_SLUG"/issues/"$TRAVIS_PULL_REQUEST"/comments --field body=@"create_task_def_info.txt" > /dev/null
    else
      # Edit previous comment by laudio-bot on PR
      echo "Editing comment: $comment_id"
      hub api repos/"$TRAVIS_REPO_SLUG"/issues/comments/"$comment_id" --field body=@"create_task_def_info.txt" > /dev/null
    fi
  fi

  # New comment on merge
  if [ "$TRAVIS_PULL_REQUEST" == "false" ]; then
    latest_commit_hash=${PR_COMMIT_RANGE##*..}
    # Gets metadata about pull request associated to the commit hash
    data=$(hub api -H "Accept: application/vnd.github.groot-preview+json" /repos/"$TRAVIS_REPO_SLUG"/commits/"$latest_commit_hash"/pulls) || true
    PULL_REQUEST=$(echo "$data" | jq '.[0].number') || true
    hub api repos/"$TRAVIS_REPO_SLUG"/issues/"$PULL_REQUEST"/comments --field body=@"create_task_def_info.txt" > /dev/null || true
  fi
}

printfln "Starting release"

printfln "Commits in the commit range:"
git log --oneline $PR_COMMIT_RANGE

# Using cat here so that grep doesn't fail with exit status 1
# https://unix.stackexchange.com/a/403707
images=$(git diff --name-only $TRAVIS_COMMIT_RANGE | sort -u | grep -oP "images\/.+?\/" | cat | uniq)

if [ -z "${images}" ]; then
  printfln "No changes detected ... skipping build ... ¯\_(ツ)_/¯"
  comment_on_pr "No changes in task definitions... ¯\\\\\\\\(ツ)/¯"

  exit 0
fi

printfln "Changes detected in following images:"
for img in $images; do
  printfln "$green> $img$reset"
done

create_ecr_repo() {
  printfln "Creating new ECR repository $1."

  aws ecr create-repository --repository-name "${1}" \
    --image-tag-mutability IMMUTABLE \
    --image-scanning-configuration scanOnPush=true \
    --region us-east-1
}

if [ "$TRAVIS_PULL_REQUEST" != "false" ]; then
  create_task_def_info="Task definition(s) to be registered:"
else
  create_task_def_info="Registered task definition(s):"
fi

delete_task_def_info="Deleted/Renamed task defination(s):"
deleted="0"

for image in $images; do
  printfln "Starting release for image: $green$image$reset"

  image_dir="$TRAVIS_BUILD_DIR/$image"

  image_name=${image/images\//}
  image_name=${image_name::-1}

  if [ ! -d "$image_dir" ]; then
    printfln "Directory $green$image_dir$reset doesn't exist. It has been either renamed or deleted."
    printfln "Skipping build ... ¯\_(ツ)_/¯"
    deleted="1"
    delete_task_def_info="$delete_task_def_info\n - **$image_name**"
    create_task_def_info=$delete_task_def_info
    continue
  fi

  printfln "Image directory: $green$image_dir$reset"

  # Get last image tag from last major release
  last_image_tag=$(git tag --sort=-version:refname | grep -P "^$image_name@\d+.\d+.\d+$" | head -n 1)

  printfln "Building docker image: $green$image_name$reset"

  if [ -z "$last_image_tag" ]; then
    printfln "Last image tag:$green none$reset"
  else
    printfln "Last version: $green$last_image_tag$reset"
  fi

  last_version=${last_image_tag#*@}

  # Create a new version if no tags for the image is found
  # However, if a tag is found bump the version as per
  # convention.
  if [ -z "$last_version" ]; then
    new_version="1.0.0"
  else
    # Safe guard to clean up any pre-release tag if it sneaks in
    new_version=$(semver bump release "$last_version")
    new_version=$(semver bump patch "$last_version")
  fi

  if [ "$TRAVIS_BRANCH" == "main" ]; then
    new_image="$image_name:$new_version"
  else
    new_image="$image_name:$new_version-$TRAVIS_BRANCH.xxxx"
  fi

  # If current branch is not master
  #   a. If current build is not a pull request append the branch name in the tag
  #   b. Otherwise, append `pr` along with the pull request number
  if [ "$BRANCH" != "main" ]; then
    if [ "$TRAVIS_PULL_REQUEST" == "false" ]; then
      timestamp=$(date -u +%Y%m%d%H%M%S)
      new_version="$new_version-$BRANCH.$timestamp"
      new_image="$image_name:$new_version"
    else
      new_version="$new_version-pr.$TRAVIS_PULL_REQUEST"
    fi
  fi

  github_tag="$image_name@$new_version"
  image_tag="$LAUDIO_DOCKER_REGISTRY/$image_name:$new_version"

  printfln "Building image with tag: $green$image_tag$reset"
  printfln "Authenticating with AWS ECR"

  # shellcheck disable=SC2091
  $(aws ecr get-login --no-include-email)

  # Yes, buildctl ¯\_(ツ)_/¯
  # Build the image's required stages.
  # Every image definition must contain at least two images: "main" and "test"

  # Build the "test" stage.
  # The test stage is an intermediate stage which runs tests and
  # other validations in the image eg: lints or checks that needs to pass
  # before publishing the image.
#   buildctl build \
#     --frontend=dockerfile.v0 \
#     --local context="$image_dir" \
#     --local dockerfile="$image_dir" \
#     --ssh default="$SSH_AUTH_SOCK" \
#     --progress plain \
#     --opt build-arg:LAUDIO_DOCKER_REGISTRY="$LAUDIO_DOCKER_REGISTRY" \
#     --opt build-arg:LAUDIO_GITHUB_TOKEN="$GITHUB_TOKEN" \
#     --opt target=test \
#     --output type=docker,name="$image_name:test" | docker load

  # Build the "main" stage.
  # The main stage is the actual image that is to be built and published.
#   buildctl build \
#     --frontend=dockerfile.v0 \
#     --local context="$image_dir" \
#     --local dockerfile="$image_dir" \
#     --ssh default="$SSH_AUTH_SOCK" \
#     --progress plain \
#     --opt build-arg:LAUDIO_DOCKER_REGISTRY="$LAUDIO_DOCKER_REGISTRY" \
#     --opt build-arg:LAUDIO_GITHUB_TOKEN="$GITHUB_TOKEN" \
#     --opt target=main \
#     --output type=docker,name="$image_name" | docker load

  printfln "Docker build completed for $green$image_tag$reset"
  printf "\n"

  # Run tests and validations
  # If this stage fails the process halts.
  printfln "Running the test stage: $image_name:test."
#   docker run "$image_name:test"
  printf "\n"

#   docker tag "$image_name" "$image_tag"
#   docker images "$LAUDIO_DOCKER_REGISTRY/*"

  if [ "$TRAVIS_BRANCH" != "main" ]; then
    task_def="$image_name-dev"
  else
    task_def="$image_name"
  fi

#   DEFAULT_TASK_DEFINITION=$(jq ".containerDefinitions[0].name=\"$image_name\"" < "task_def_template.json" |
#     jq ".containerDefinitions[0].image=\"$image_tag\"" |
#     jq ".containerDefinitions[0].logConfiguration.options[\"awslogs-group\"]=\"/ecs/$task_def\"" |
#     jq ".family=\"$task_def\"")

#   # Create task definition by reading the latest task definition
#   LATEST_TASK_DEFINITION=$(aws ecs describe-task-definition --task-definition "$task_def") &&
#     echo "$LATEST_TASK_DEFINITION" |
#     jq '.taskDefinition' | jq '{family, taskRoleArn, executionRoleArn, networkMode, containerDefinitions, volumes, placementConstraints, requiresCompatibilities, cpu, memory}' | jq ".containerDefinitions[0].image=\"$image_tag\"" > /tmp/task_def.json ||
#     # Create a task definition from default template
#     echo "$DEFAULT_TASK_DEFINITION" > /tmp/task_def.json

  # Only release the build for following branches
  if [ "${BRANCH}" == "dev" ] ||
    [ "${BRANCH}" == "alpha" ] ||
    [ "${BRANCH}" == "main" ]; then

    if [ "$TRAVIS_PULL_REQUEST" == "false" ]; then

      # Create ECR repository if it doesn't exist
    #   ecr_images=$( (aws ecr list-images --repository-name "${image_name}") || echo "0")

    #   if [ "$ecr_images" == "0" ]; then
    #     printfln "$image_name repository doesn't exist."
    #     create_ecr_repo "$image_name"
    #   fi

      printfln "Pushing $green$image_tag$reset to ECR registry"
    #   docker push "$image_tag"

      printfln "Tagging release $green$github_tag$reset"

      # Create a new release in GitHub
      if [ "$BRANCH" != "main" ]; then
        hub release create "$github_tag" -m "$github_tag" -p || true
      else
        hub release create "$github_tag" -m "$github_tag" || true
      fi

      # Register task definition
      if [ "$BRANCH" == "dev" ] || [ "$BRANCH" == "alpha" ]; then
        # Register task definitions (eg. file-transfer-sftp-to-s3 or file-transfer-sftp-to-s3-dev)
        # aws ecs register-task-definition --family "$task_def" --cli-input-json file:///tmp/task_def.json
        printfln "New task definition registered for $task_def"
      else
        printfln "Skipping task definition update."
      fi
    fi
  else
    printf "Skipping build for %s in %s" "$image" "$BRANCH"
  fi

  if [ "$deleted" == "1" ]; then
    # default_create_comment="Task definition(s) to be registered:\n"
    deleted="0"
  fi

  last_revision=$(echo "$LATEST_TASK_DEFINITION" | jq '.taskDefinition.revision')
  create_task_def_info="$create_task_def_info\n$default_create_comment - **$task_def**:\`$((last_revision + 1))\` (Image: \`$new_image\`)"

  printfln "Done ..."
done

# Comment in GitHub pull request thread
# comment_on_pr "$create_task_def_info"

printfln "List of images"
printf "\n"

# docker images "$LAUDIO_DOCKER_REGISTRY/*"
