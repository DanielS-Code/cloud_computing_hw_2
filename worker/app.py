import requests
import time
import boto3
from ec2_metadata import ec2_metadata
import os
from config import ORCHESTRATOR_IP, TIME_OUT, PORT, EXIT_FLAG
from datetime import datetime
import logging

logging.basicConfig(filename='worker/worker.log',
                    filemode='a',
                    format='%(asctime)s,%(msecs)d %(name)s %(levelname)s %(message)s',
                    datefmt='%H:%M:%S',
                    level=logging.DEBUG)

headers = {"Content-Type": "application/json", 'Accept': 'application/json'}


def do_work(buffer, iterations):
    import hashlib
    output = hashlib.sha512(buffer.encode('utf-8')).digest()
    for i in range(iterations - 1):
        output = hashlib.sha512(output).digest()
    return output


def main():
    start_time = datetime.utcnow()
    while True:
        dif = datetime.utcnow() - start_time
        logging.info("Checking for available work")
        request = requests.get(f'http://{ORCHESTRATOR_IP}:{PORT}/get_work')
        work = request.json()
        if work:
            res = do_work(work["file"], work["iterations"])
            requests.put(f"http://{ORCHESTRATOR_IP}:{PORT}/get_result", headers=headers,
                         json={"job_id": work["job_id"], "result": str(res)})
            start_time = datetime.utcnow()
        else:
            if dif.seconds > TIME_OUT and EXIT_FLAG:
                os.system('sudo shutdown -h now')
        time.sleep(1)


if __name__ == '__main__':
    main()
