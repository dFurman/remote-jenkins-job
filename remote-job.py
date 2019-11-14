import argparse
import requests
import json
import os, time
import logging

parser = argparse.ArgumentParser(description='Trigger remote Jenkins job')
parser.add_argument('--jenkins-url', '-u', required=True, help='Remote Jenkins URL (http://jenkins-url:8080)')
parser.add_argument('--job-name', '-j', required=True, help='Remote Jenkins job name')
parser.add_argument('--jenkins-user', '-l', required=True, help='Remote Jenkins User')
parser.add_argument('--token', '-t', required=True, help='Remote Jenkins user token')
parser.add_argument('--parameter','-p', action='append', nargs='+' , help='Parameter to pass (-p param1=value1 -p param2=value2)')
parser.add_argument('--debug', '-d', action='store_true', help='debug output')

args = parser.parse_args()

logging_level = logging.DEBUG if args.debug else logging.INFO
logging.basicConfig(format='[%(levelname)s] %(message)s', level=logging_level)

jenkins_url = args.jenkins_url
job_name = args.job_name
jenkins_user = args.jenkins_user
token = args.token
BUILD_TIMEOUT_SECONDS = os.getenv('BUILD_TIMEOUT_SECONDS', 86400)
POLL_INTERVAL = os.getenv('POLL_INTERVAL', 5)

# You must use the buildWithParameters build invocation as this
# is the only mechanism of receiving the "Queued" job id (via HTTP Location header)

def get_crumb_token():
    crumb_url = f'{jenkins_url}/crumbIssuer/api/json'
    res = requests.get(url=crumb_url, auth=(jenkins_user, token))
    j = json.loads(res.content)
    return j['crumb']

def get_remote_job_url():
    if args.parameter:
        parameters = ""
        for param in args.parameter:
            parameters += param[0] + "&"
        parameters = parameters.rstrip("&")
        return f'{jenkins_url}/job/{job_name}/buildWithParameters?{parameters}'
    else:
        logging.warning('No Parameters were set !')
        return f'{jenkins_url}/job/{job_name}/buildWithParameters?_dummy_=1'

def main():
    crumb = get_crumb_token()
    req_headers = {
        'Jenkins-Crumb': crumb
    }

    remote_job_url = get_remote_job_url()

    logging.info(f'Calling REMOTE_JOB_URL: {remote_job_url}')
    res = requests.post(remote_job_url, auth=(jenkins_user, token), headers=req_headers)
    queued_url = res.headers._store['location'][1] + "api/json"
    if not queued_url:
        logging.error('No QUEUED_URL was found.')
        exit(1)

    # Fetch the executable.url from the QUEUED url
    res = requests.get(queued_url, auth=(jenkins_user, token), headers=req_headers)
    j = json.loads(res.content)
    job_url = j['executable']['url']

    if job_url == "null":
        job_url = None
    # Check for status of queued job, whether it is running yet
    counter = 0
    while not job_url:
        logging.info(f'The QUEUED counter is ${counter}')
        counter += POLL_INTERVAL
        time.sleep(POLL_INTERVAL)
        if counter > BUILD_TIMEOUT_SECONDS:
            logging.error(f'A job was queued, but it did not start running within {BUILD_TIMEOUT_SECONDS} seconds')
            logging.error(f'Queued job URL: {queued_url}')
            exit(1)

        # Fetch the executable.url from the QUEUED url
        res = requests.get(queued_url, auth=(jenkins_user, token), headers=req_headers)
        j = json.loads(res.content)
        job_url = j['executable']['url']
        if job_url == "null":
            job_url = None

    logging.info(f'JOB URL: {job_url}')
    # Job is running
    is_building = True
    counter = 0
    output_line_cursor = 0

    while is_building:
        counter += POLL_INTERVAL
        time.sleep(POLL_INTERVAL)
        if counter > BUILD_TIMEOUT_SECONDS:
            logging.error(f'TIME-OUT: Exceeded {BUILD_TIMEOUT_SECONDS} seconds')
            break
        res = requests.get(job_url + 'api/json', auth=(jenkins_user, token), headers=req_headers)
        j = json.loads(res.content)
        is_building = j['building']
        # Grab total lines in console output
        res = requests.get(job_url + 'consoleText', auth=(jenkins_user, token), headers=req_headers)
        text = res.text.split('\r\n')[:-1]
        new_line_cursor = len(text)
        # subtract line count from cursor
        line_count = new_line_cursor - output_line_cursor
        if line_count > 0:
            for line in text[line_count*-1:]:
                logging.info(f'[{job_name}] {line}')
        output_line_cursor = new_line_cursor
    # Get final result
    res = requests.get(job_url + 'api/json', auth=(jenkins_user, token), headers=req_headers)
    j = json.loads(res.content)
    result = j['result']
    if result == "SUCCESS":
        logging.info(f'[{job_name}] Build Result: {result}')
        exit(0)
    else:
        logging.error(f'[{job_name}] BUILD RESULT: {result} - Build is unsuccessful, timed out, or status could not be obtained.')
        exit(1)

if __name__ == "__main__":
    main()