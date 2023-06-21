import requests
import time
import boto3
from ec2_metadata import ec2_metadata
import os
from config import PORT, EXIT_FLAG, QUEUE_IP, TIME_OUT
from datetime import datetime
import logging

logging.basicConfig(filename='worker/worker.log',
                    filemode='a',
                    format='%(asctime)s,%(msecs)d %(name)s %(levelname)s %(message)s',
                    datefmt='%H:%M:%S',
                    level=logging.DEBUG)


def perform_work(buffer, iterations):
    import hashlib
    output = hashlib.sha512(buffer.encode('utf-8')).digest()
    for i in range(iterations - 1):
        output = hashlib.sha512(output).digest()
    return output


def main():
    start_time = datetime.utcnow()
    while True:
        diff = datetime.utcnow() - start_time
        logging.info("Checking for available work")
        request = requests.get(f'http://{QUEUE_IP}:{PORT}/job/consume')
        workload = request.json()
        if workload:
            output = perform_work(workload['data'], workload['iterations'])
            requests.put(f"http://{QUEUE_IP}:{PORT}/job/completed",
                         headers={"Content-Type": "application/json", 'Accept': 'application/json'},
                         json={'job_id': workload['job_id'], "result": str(output)})
            start_time = datetime.utcnow()
        else:
            if diff.seconds > TIME_OUT and EXIT_FLAG:
                os.system('sudo shutdown -h now')
        time.sleep(1)


if __name__ == '__main__':
    main()
