#!/usr/bin/env bash

set -exo pipefail

if [ "$#" -lt 1 ]
then
  echo "Usage: ./build-testnet-develop-release.sh [debug|release] [profiling=[true|false]]"
  exit 1
fi

BUILD_TYPE=$1

CONSENSUS_PROFILING="false"
if [[ ! -z "$2" && "$2" == "true" ]]; then
  CONSENSUS_PROFILING="true"
fi

if [ -z "$JENKINS_HOME" ]; then
  git pull
fi

VERSION=`git rev-parse --verify HEAD`
GENESIS_VERSION=$(cat ./scripts/GENESIS_DATA_VERSION)

./scripts/testnet-deployments/build-all-docker.sh $VERSION $BUILD_TYPE $CONSENSUS_PROFILING

echo "Finished building and pushing develop release with tag $VERSION with profiling $CONSENSUS_PROFILING and genesis $GENESIS_VERSION"