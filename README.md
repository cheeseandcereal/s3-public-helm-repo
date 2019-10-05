# S3 Public Helm Repository Plugin

This repository is a [helm](https://helm.sh/) plugin which allows you to easily use S3 as a public helm repository.

S3 has the ability to act as a public webserver and serve helm files as a repository, but is tedious
to upload and update the `index.yaml` for each added chart.

This tool attempts to automate this process as much as possible.

Please note that this tool differs from the [helm-s3](https://github.com/hypnoglow/helm-s3) plugin,
as the goal of this plugin is to configure an S3 bucket for public helm usage using S3's native http features,
rather than adding S3 protocol support into helm itself.

You do **NOT** need this plugin to use/consume the created repository.
This tool is simply for managing/updating a helm chart repository hosted in S3 itself.

## Installation

In order to use this plugin, you must have the [aws cli](https://aws.amazon.com/cli/) installed and configured.
(This plugin will use the default configured aws profile with the cli)

```sh
helm plugin install https://github.com/cheeseandcereal/s3-public-helm-repo
```

## Usage

Currently there are 2 commands:

- configure: Configure (or create) an S3 bucket with the settings necessary to operate as a public helm repo
- add: Add a chart to a configured S3 bucket, effectively updating the repository

If using this in a non-interactive script, such as a CI/CD, use the appropriate `-y` or `-n` options at the end of a command.
