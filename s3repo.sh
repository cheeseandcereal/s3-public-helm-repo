#!/bin/sh
set -e

usage() {
cat << EOF
Create and manage an S3 bucket as a public helm repository.

Available Commands:
  configure  Configure (or create) an S3 bucket with the settings necessary to operate as a public helm repo
  add        Add a chart to a configured S3 bucket, effectively updating the repository
EOF
}

configure_usage() {
cat << EOF
Configure (or create) an S3 bucket with the settings necessary to operate as a public helm repo.

This will set up the specified S3 bucket with a public index.yaml file.

Usage:
  helm s3repo configure <s3-bucket> [options]

Examples:
  # Create a helm repository with a new or existing bucket named 'my-s3-bucket'
  $ helm s3repo configure my-s3-bucket

  # Create a helm repository with the existing bucket 'my-s3-bucket', and exit on failure if any conflicting files exist
  $ helm s3repo configure my-s3-bucket -n

Options:
  -y: Answer yes to all questions (attempt to create bucket if it doesn't exist, and overwrite conflicting objects if necessary)
  -n: Answer no to all questions (exit on failure with any conflicts, or if the bucket doesn't exist)
EOF
}

add_usage() {
cat << EOF
Add a chart to a configured S3 bucket.

After adding a chart, performing a 'helm repo update' should find the newly added chart.

If you have an adjacent .prov file for verification, this will be automatically uploaded as well.

Usage:
  helm s3repo add <s3-bucket> <packaged-helm-chart> [options]

Examples:
  # Add the packaged foo-0.1.0.tgz chart to the s3-hosted helm repo in my-s3-bucket
  $ helm s3repo add my-s3-bucket foo-0.1.0.tgz

  # Add the packaged foo-0.1.0.tgz chart to the repo, but exit on failure with any conflicts
  $ helm s3repo add my-s3-bucket foo-0.1.0.tgz -n

Options:
  -y: Answer yes to all questions (can overwrite existing chart with matching version)
  -n: Answer no to all questions (exit on failure with any conflicts)
EOF
}

if ! command -v aws > /dev/null 2>&1; then
  echo "The aws cli must be installed and configured"
  exit 1;
fi

is_help() {
  case "$1" in
    "-h" )
      return 0;;
    "--help" )
      return 0;;
    "help" )
      return 0;;
    * )
      return 1;;
  esac
}

if [ $# -lt 1 ] || is_help "$1"; then
  usage
  exit 0
fi

configure() {
  if is_help "$1" ; then
    configure_usage
    return
  fi
  bucket=$1
  flag=$2
  while true; do
    if ! aws s3 ls "s3://$bucket" > /dev/null 2>&1; then
      if [ "$flag" = "-n" ]; then
        (>&2 printf "S3 bucket '%s' either doesn't exist, or you don't have access to it.\\n" "$bucket")
        answer="n"
      elif [ "$flag" = "-y" ]; then
        answer="y"
      else
        printf "S3 bucket '%s' either doesn't exist, or you don't have access to it. Would you like to try to create this bucket? [y/n] " "$bucket"; read -r answer
      fi
      case "$answer" in
        [yY]* )
          aws s3 mb "s3://$bucket"
          ;;
        [nN]* )
          exit 1
          ;;
        * )
          echo "Please answer y/n"
          ;;
      esac
    else
      break
    fi
  done
  if aws s3 ls "s3://$bucket/index.yaml" > /dev/null 2>&1; then
    while true; do
      if [ "$flag" = "-n" ]; then
        (>&2 printf "ERROR! Bucket '%s' already has an index.yaml. (Maybe it's already a helm repository?)\\n" "$bucket")
        answer="n"
      elif [ "$flag" = "-y" ]; then
        answer="y"
      else
        printf "WARNING! Bucket '%s' already has an index.yaml. (Maybe it's already a helm repository?)\\nWould you like to delete this index and start a new repo in this bucket? [y/n] " "$bucket"; read -r answer
      fi
      case "$answer" in
        [yY]* )
          break
          ;;
        [nN]* )
          exit 1
          ;;
        * )
          echo "Please answer y/n"
          ;;
      esac
    done
  fi
  # Create and upload an empty public index yaml
  tempdir="$(mktemp -d /tmp/s3repo.XXXXXXXXX)"
  (
    cd "$tempdir" || exit 1
    $HELM_BIN repo index .
    aws s3api put-object --bucket "$bucket" --content-type text/yaml --key index.yaml --body ./index.yaml --acl public-read > /dev/null
  )
  rm -rf "$tempdir"
  printf "Your helm repository is now set up and empty.\\n"
  printf "Add your public repo with: 'helm repo add NAME https://%s.s3.amazonaws.com'\\n(NAME can be anything)\\n" "$bucket"
}

add() {
  if is_help "$1" ; then
    add_usage
    return
  fi
  bucket=$1
  chart=$2
  flag=$3
  if ! $HELM_BIN lint "$chart" > /dev/null 2>&1; then
    echo "'$chart' does not appear to be a valid helm chart (Doesn't pass helm lint)"
    exit 1
  fi
  if ! test -f "$chart"; then
    printf "%s is not a valid file\\nMake sure to use 'helm package' first and point to the valid .tgz file\\n" "$chart"
    exit 1
  fi
  tempdir="$(mktemp -d /tmp/s3repo.XXXXXXXXX)"
  if ! cp "$chart" "$tempdir/" > /dev/null 2>&1; then
    echo "Chart $chart isn't able to be copied. Maybe a permissions issue?"
    rm -rf "$tempdir"
    exit 1
  fi
  chart_tmp="$(ls -1 "$tempdir/")"
  if aws s3 ls "s3://$bucket/charts/$chart_tmp" > /dev/null 2>&1; then
    while true; do
      if [ "$flag" = "-n" ]; then
        (>&2 printf "Chart %s already exists in S3\\n" "$chart_tmp")
        answer="n"
      elif [ "$flag" = "-y" ]; then
        answer="y"
      else
        printf "Chart %s already exists in S3. Would you like to delete and overwrite it? [y/n] " "$chart_tmp"; read -r answer
      fi
      case "$answer" in
        [yY]* )
          break
          ;;
        [nN]* )
          rm -rf "$tempdir"
          exit 1
          ;;
        * )
          echo "Please answer y/n"
          ;;
      esac
    done
  fi
  (
    cd "$tempdir" || exit 1
    if ! aws s3 cp "s3://$bucket/index.yaml" old_index.yaml > /dev/null 2>&1; then
      printf "Bucket '%s' does not appear to be a valid helm repository\\nRun 'helm s3repo configure' first\\n" "$bucket"
      rm -rf "$tempdir"
      exit 1
    fi
    # Create the new index.yaml, merging our existing index and specifying the url
    $HELM_BIN repo index . --merge old_index.yaml --url "https://$bucket.s3.amazonaws.com/charts/"
    # Upload actual chart and new index
    aws s3api put-object --bucket "$bucket" --key "charts/$chart_tmp" --body "$chart_tmp" --acl public-read > /dev/null
    echo "Chart uploaded"
    aws s3api put-object --bucket "$bucket" --content-type text/yaml --key index.yaml --body ./index.yaml --acl public-read > /dev/null
    echo "Index updated"
  )
  # Add the adjacent .prov file too, if it exists
  if test -f "$chart.prov"; then
    aws s3api put-object --bucket "$bucket" --key "charts/$chart_tmp.prov" --body "$chart.prov" --acl public-read > /dev/null
    echo "Additional .prov file found and uploaded"
  fi
  rm -rf "$tempdir"
  printf "Chart %s has been successfully uploaded and index is updated.\\nRun 'helm repo update' to pull and confirm the new changes locally\\n" "$chart_tmp"
}

case "$1" in
  "configure" )
    if [ $# -lt 2 ]; then
      configure_usage
      printf "\\nError: S3 bucket name required\\n"
      exit 1
    fi
    configure "$2" "$3"
    ;;
  "add" )
    if [ $# -lt 2 ]; then
      add_usage
      printf "\\nError: S3 bucket name and chart required\\n"
      exit 1
    elif [ $# -lt 3 ]; then
      add_usage
      printf "\\nError: chart required\\n"
      exit 1
    fi
    add "$2" "$3" "$4"
    ;;
  * )
    usage
    exit 1
    ;;
esac
