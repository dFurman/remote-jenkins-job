#!/usr/bin/env bash
###
# Trigger a Remote Jenkins Job with parameters and get console output as well as result
# Usage:
# remote-job.sh -u https://jenkins-url.com -j JOB_NAME -p "PARAM1=999" -p "PARAM2=123" -t BUILD_TOKEN
# -u: url of jenkins host
# -j: JOB_NAME on jenkins host
# -p: parameter to pass in. Send multiple parameters by passing in multiple -p flags
# -t: BUILD_TOKEN on remote machine to run job
# -i: Tell curl to ignore cert validation
###


# Number of seconds before timing out
[ -z "$BUILD_TIMEOUT_SECONDS" ] && BUILD_TIMEOUT_SECONDS=86400 #86,400 = 24hrs
# Number of seconds between polling attempts
[ -z "$POLL_INTERVAL" ] && POLL_INTERVAL=5
while getopts j:p:t:u:l:i opt; do
  case $opt in
    p) parameters+=("$OPTARG");;
    t) TOKEN=$OPTARG;;
    j) JOB_NAME=$OPTARG;;
    u) JENKINS_URL=$OPTARG;;
    l) JENKINS_USER=$OPTARG;;
    i) CURL_OPTS="-k"# tell curl to ignore cert validation
    #...
  esac
done
shift $((OPTIND -1))

[ -z "$JENKINS_URL" ] && { echo "JENKINS_URL (-u) not set"; exit 1; }
echo "JENKINS_URL: $JENKINS_URL"
[ -z "$JOB_NAME" ] && { echo "JOB_NAME (-j) not set"; exit 1; }
echo "JOB_NAME: $JOB_NAME"

echo "The whole list of values is '${parameters[@]}'"
for parameter in "${parameters[@]}"; do
  # If PARAMS exists, add an ampersand
  [ -n "$PARAMS" ] && PARAMS=$PARAMS\&$parameter
  # If no PARAMS exist, don't add an ampersand
  [ -z "$PARAMS" ] && PARAMS=$parameter
done


# Queue up the job
# nb You must use the buildWithParameters build invocation as this
# is the only mechanism of receiving the "Queued" job id (via HTTP Location header)

CRUMB_URL="$JENKINS_URL/crumbIssuer/api/json"
echo "JENKINS_URL=$JENKINS_URL"
echo "CRUMB_URL=$CRUMB_URL"
echo "JENKINS_USER=$JENKINS_USER"
echo "TOKEN=$TOKEN"
echo "Getting Jenkins Crumb Header"
CRUMB=$(curl -sSL -X GET $CRUMB_URL --user $JENKINS_USER:$TOKEN | jq -r '.crumb')
echo "CRUMB Recived: $CRUMB"

if [ -z "$PARAMS" ]; then 
  echo "No parameters were set!"
  REMOTE_JOB_URL="$JENKINS_URL/job/$JOB_NAME/buildWithParameters?_dummy_=1"
else 
  echo "PARAMS: $PARAMS"
  REMOTE_JOB_URL="$JENKINS_URL/job/$JOB_NAME/buildWithParameters?$PARAMS"
fi
echo "Calling REMOTE_JOB_URL: $REMOTE_JOB_URL"

QUEUED_URL=$(curl -sSL -X POST $CURL_OPTS -H "Jenkins-Crumb: $CRUMB" --user $JENKINS_USER:$TOKEN -D - $REMOTE_JOB_URL |\
perl -n -e '/^Location: (.*)$/ && print "$1\n"')
[ -z "$QUEUED_URL" ] && { echo "No QUEUED_URL was found."; exit 1; }

# Remove extra \r at end, add /api/json path
QUEUED_URL=${QUEUED_URL%$'\r'}api/json

# Fetch the executable.url from the QUEUED url
JOB_URL=`curl -sSL -H "Jenkins-Crumb: $CRUMB" --user $JENKINS_USER:$TOKEN $QUEUED_URL | jq -r '.executable.url'`
[ "$JOB_URL" = "null" ] && unset JOB_URL
# Check for status of queued job, whether it is running yet
COUNTER=0
while [ -z "$JOB_URL" ]; do
  echo "The QUEUED counter is $COUNTER"
  let COUNTER=COUNTER+$POLL_INTERVAL
  sleep $POLL_INTERVAL
  if [ "$COUNTER" -gt $BUILD_TIMEOUT_SECONDS ];
  then
    echo "Error: A job was queued, but it did not start running within $BUILD_TIMEOUT_SECONDS seconds"
    echo "Queued job URL: $QUEUED_URL"
    exit 1
  fi
  JOB_URL=`curl -sSL -H "Jenkins-Crumb: $CRUMB" --user $JENKINS_USER:$TOKEN $CURL_OPTS $QUEUED_URL | jq -r '.executable.url'`
  [ "$JOB_URL" = "null" ] && unset JOB_URL
done
echo "JOB_URL: $JOB_URL"

# Job is running
IS_BUILDING="true"
COUNTER=0
OUTPUT_LINE_CURSOR=0

# Use until IS_BUILDING = false (instead of while IS_BUILDING = true)
# to avoid false positives if curl command (IS_BUILDING) fails
# while polling for status
until [ "$IS_BUILDING" = "false" ]; do
  let COUNTER=COUNTER+$POLL_INTERVAL
  sleep $POLL_INTERVAL
  if [ "$COUNTER" -gt $BUILD_TIMEOUT_SECONDS ];
  then
    echo "TIME-OUT: Exceeded $BUILD_TIMEOUT_SECONDS seconds"
    break  # Skip entire rest of loop.
  fi
  IS_BUILDING=`curl -sSL -H "Jenkins-Crumb: $CRUMB" --user $JENKINS_USER:$TOKEN $CURL_OPTS $JOB_URL/api/json | jq -r '.building'`
  # Grab total lines in console output
  NEW_LINE_CURSOR=`curl -sSL -H "Jenkins-Crumb: $CRUMB" --user $JENKINS_USER:$TOKEN $CURL_OPTS $JOB_URL/consoleText | wc -l`
  # subtract line count from cursor
  LINE_COUNT=`expr $NEW_LINE_CURSOR - $OUTPUT_LINE_CURSOR`
  if [ "$LINE_COUNT" -gt 0 ];
  then
    curl -sSL -H "Jenkins-Crumb: $CRUMB" --user $JENKINS_USER:$TOKEN $CURL_OPTS $JOB_URL/consoleText | tail -$LINE_COUNT
  fi
  OUTPUT_LINE_CURSOR=$NEW_LINE_CURSOR
done

RESULT=`curl -sSL -H "Jenkins-Crumb: $CRUMB" --user $JENKINS_USER:$TOKEN $CURL_OPTS $JOB_URL/api/json | jq -r '.result'`
if [ "$RESULT" = 'SUCCESS' ]
then
  echo "BUILD RESULT: $RESULT"
  exit 0
else
  echo "BUILD RESULT: $RESULT - Build is unsuccessful, timed out, or status could not be obtained."
  exit 1
fi