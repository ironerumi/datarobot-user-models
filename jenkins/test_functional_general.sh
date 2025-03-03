#!/usr/bin/env bash
# Copyright 2021 DataRobot, Inc. and its affiliates.
#
# All rights reserved.
# This is proprietary source code of DataRobot, Inc. and its affiliates.
#
# Released under the terms of DataRobot Tool and Utility Agreement.
# This file will be executed from the root of the repository in a python3 virtualenv.
# It will run the test of drum inside a predefined docker image:

# root repo folder
set -exuo pipefail

GIT_ROOT=$(git rev-parse --show-toplevel)
echo "GIT_ROOT: ${GIT_ROOT}"
source ${GIT_ROOT}/tests/functional/integration-helpers.sh

# Installing and configuring java/javac 11 in the jenkins worker
sudo apt update
sudo apt install --no-install-recommends -y openjdk-11-jdk openjdk-11-jre zip
sudo update-alternatives --set java /usr/lib/jvm/java-11-openjdk-amd64/bin/java
sudo update-alternatives --auto javac
export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64

title "DEBUG: print java version"
java -version
javac -version


title "Create python3 virtual environment"
python3 --version
sudo apt install --no-install-recommends -y python3.9-venv
python3 -m venv /tmp/venv
. /tmp/venv/bin/activate
pip install -U pip

title "Installing datarobot-mlops and pulling mlops-agent"
# > NOTE: when pinning datarobot-mlops to 8.2.1 and higher you may need to reinstall datarobot package
# as datarobot-mlops overwrites site-packages/datarobot. [AGENT-3504]

MLOPS_VERSION="9.1.3"
pip install datarobot-mlops==${MLOPS_VERSION}

MLOPS_AGENT_JAR_DIR="/tmp/jars"
REPO_BASE="https://artifactory.devinfra.drdev.io/artifactory/datarobot-maven-dev/com/datarobot"
MLOPS_AGENT_VERSION=${MLOPS_VERSION}
mkdir -p "${MLOPS_AGENT_JAR_DIR}"
curl --output "${MLOPS_AGENT_JAR_DIR}"/mlops-agent-${MLOPS_AGENT_VERSION}.jar ${REPO_BASE}/mlops-agent/${MLOPS_AGENT_VERSION}/mlops-agent-${MLOPS_AGENT_VERSION}.jar
export MLOPS_MONITORING_AGENT_JAR_PATH=${MLOPS_AGENT_JAR_DIR}/mlops-agent-${MLOPS_AGENT_VERSION}.jar

title "Installing requirements for all the tests:  ${GIT_ROOT}/requirements_test.txt"
pip install -r ${GIT_ROOT}/requirements_test.txt

pushd ${GIT_ROOT} || exit 1

# The "jenkins_artifacts" folder is created in the groovy script
DRUM_WHEEL_REAL_PATH="$(realpath "$(find jenkins_artifacts/datarobot_drum*.whl)")"
echo
title "Installing wheel: ${DRUM_WHEEL_REAL_PATH}"
echo
pip install "${DRUM_WHEEL_REAL_PATH}"

echo
title "Compiling jar for TestCustomPredictor "
pushd $GIT_ROOT/tests/functional/custom_java_predictor
mvn package
popd

# Change every environment Dockerfile to install freshly built DRUM wheel
source "${GIT_ROOT}/tools/image-build-utils.sh"
title "Change every environment Dockerfile to install local freshly built DRUM wheel: ${DRUM_WHEEL_REAL_PATH}"
build_all_dropin_env_dockerfiles "${DRUM_WHEEL_REAL_PATH}"

echo
title "Build 'python3_sklearn_test_env' image from public_dropin_environments/python3_sklearn/*"

TMP_DOCKER_CONTEXT=$(mktemp -d)

pushd "${GIT_ROOT}/public_dropin_environments/python3_sklearn/"
cp * ${TMP_DOCKER_CONTEXT}
popd

echo "uwsgi" >> ${TMP_DOCKER_CONTEXT}/requirements.txt
echo 'ENTRYPOINT ["this_is_fake_entrypoint_to_make_sure_drum_unsets_it_when_runs_with_--docker_param"]' >> $TMP_DOCKER_CONTEXT/Dockerfile
docker build -t python3_sklearn_test_env ${TMP_DOCKER_CONTEXT}/

echo
title "Running tests: sequential test cases Java Custom Predictor and MLOps Monitoring"

# only run here tests which were sequential historically
pytest tests/functional/test_inference_custom_java_predictor.py tests/functional/test_mlops_monitoring.py \
       --junit-xml="${GIT_ROOT}/results_integration_serial.xml" \
       -n 1
TEST_RESULT_1=$?

title "Running tests: all other cases in parallel"
pytest tests/functional/ \
       -k "not test_inference_custom_java_predictor.py and not test_mlops_monitoring.py" \
       -m "not sequential" \
       --junit-xml="${GIT_ROOT}/results_integration_parallel.xml" \
       -n auto
TEST_RESULT_2=$?

popd


if [ ${TEST_RESULT_1} -ne 0 ] ; then
  echo "Got error in one of the tests:"
  echo "Sequential tests: ${TEST_RESULT_1}"
  exit 1
elif [ ${TEST_RESULT_2} -ne 0 ] ; then
  echo "Got error in one of the tests:"
  echo "Non sequential tests: ${TEST_RESULT_2}"
  exit 1
else
  exit 0
fi


echo "Done running tests: ${TEST_RESULT_1} ${TEST_RESULT_2}"
exit ${TEST_RESULT_2}
