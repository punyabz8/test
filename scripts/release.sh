#!/bin/bash

# shellcheck disable=SC2059

set -e

green="\033[32m"
reset="\033[0m"

printfln() {
  printf "\n$1\n"
}

BRANCH=$(if [ "$TRAVIS_PULL_REQUEST" == "false" ]; then echo "$TRAVIS_BRANCH"; else echo "$TRAVIS_PULL_REQUEST_BRANCH"; fi)

export BRANCH

if [ -n "$TRAVIS_COMMIT_RANGE" ]; then
  if ! git rev-list "$TRAVIS_COMMIT_RANGE" > /dev/null; then
    TRAVIS_COMMIT_RANGE=
  fi
fi

if [ -n "$TRAVIS_COMMIT_RANGE" ]; then
  PR_COMMIT_RANGE="${TRAVIS_COMMIT_RANGE/.../..}"
fi

comment_on_pr() {
  echo -e "$1" > create_task_def_info.txt
  if [ "$TRAVIS_PULL_REQUEST" != "false" ]; then
    comments=$(hub api repos/"$TRAVIS_REPO_SLUG"/issues/"$TRAVIS_PULL_REQUEST"/comments)
    comment_id=$(echo "$comments" | jq -c ".[] | select(.user.login==\"laudio-bot\")" | jq ".id" | tail -n 1) || true

    if [ -z "$comment_id" ]; then
      hub api repos/"$TRAVIS_REPO_SLUG"/issues/"$TRAVIS_PULL_REQUEST"/comments --field body=@"create_task_def_info.txt" > /dev/null
    else
      echo "Editing comment: $comment_id"
      hub api repos/"$TRAVIS_REPO_SLUG"/issues/comments/"$comment_id" --field body=@"create_task_def_info.txt" > /dev/null
    fi
  fi

  if [ "$TRAVIS_PULL_REQUEST" == "false" ]; then
    latest_commit_hash=${PR_COMMIT_RANGE##*..}
    data=$(hub api -H "Accept: application/vnd.github.groot-preview+json" /repos/"$TRAVIS_REPO_SLUG"/commits/"$latest_commit_hash"/pulls) || true
    PULL_REQUEST=$(echo "$data" | jq '.[0].number') || true
    hub api repos/"$TRAVIS_REPO_SLUG"/issues/"$PULL_REQUEST"/comments --field body=@"create_task_def_info.txt" > /dev/null || true
  fi
}

printfln "Starting release"

printfln "Commits in the commit range:"
git log --oneline $PR_COMMIT_RANGE

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

  last_image_tag=$(git tag --sort=-version:refname | grep -P "^$image_name@\d+.\d+.\d+$" | head -n 1)

  printfln "Building docker image: $green$image_name$reset"

  if [ -z "$last_image_tag" ]; then
    printfln "Last image tag:$green none$reset"
  else
    printfln "Last version: $green$last_image_tag$reset"
  fi

  last_version=${last_image_tag#*@}

  if [ -z "$last_version" ]; then
    new_version="1.0.0"
  else
    new_version=$(semver bump release "$last_version")
    new_version=$(semver bump patch "$last_version")
  fi

  if [ "$TRAVIS_BRANCH" == "main" ]; then
    new_image="$image_name:$new_version"
  else
    new_image="$image_name:$new_version-$TRAVIS_BRANCH.xxxx"
  fi

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

  printfln "Docker build completed for $green$image_tag$reset"
  printf "\n"

  printfln "Running the test stage: $image_name:test."
  printf "\n"

  if [ "$TRAVIS_BRANCH" != "main" ]; then
    task_def="$image_name-dev"
  else
    task_def="$image_name"
  fi

  if [ "${BRANCH}" == "dev" ] ||
    [ "${BRANCH}" == "alpha" ] ||
    [ "${BRANCH}" == "main" ]; then

    if [ "$TRAVIS_PULL_REQUEST" == "false" ]; then

      printfln "Pushing $green$image_tag$reset to ECR registry"

      printfln "Tagging release $green$github_tag$reset"

      if [ "$BRANCH" != "main" ]; then
        hub release create "$github_tag" -m "$github_tag" -p || true
      else
        hub release create "$github_tag" -m "$github_tag" || true
      fi

      if [ "$BRANCH" == "dev" ] || [ "$BRANCH" == "alpha" ]; then
        printfln "New task definition registered for $task_def"
      else
        printfln "Skipping task definition update."
      fi
    fi
  else
    printf "Skipping build for %s in %s" "$image" "$BRANCH"
  fi

  if [ "$deleted" == "1" ]; then
    deleted="0"
  fi

  last_revision=$(echo "$LATEST_TASK_DEFINITION" | jq '.taskDefinition.revision')
  create_task_def_info="$create_task_def_info\n$default_create_comment - **$task_def**:\`$((last_revision + 1))\` (Image: \`$new_image\`)"

  printfln "Done ..."
done

printfln "List of images"
printf "\n"
