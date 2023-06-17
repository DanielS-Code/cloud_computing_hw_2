from flask import Flask, Response, request
from datetime import datetime
import json
import threading
import time
import uuid
import boto3
from config import MAX_TIME_IN_QUEUE, PERIODIC_ITERATION, INSTANCE_TYPE, WORKER_AMI_ID, ORCHESTRATOR_IP, USER_REGION
import logging

logging.basicConfig(filename='orchestrator/orchestrator.log',
                    filemode='a',
                    format='%(asctime)s,%(msecs)d %(name)s %(levelname)s %(message)s',
                    datefmt='%H:%M:%S',
                    level=logging.DEBUG)

SEC_GRP = "CC_HW2_SEC_GRP"

app = Flask(__name__)
work_queue = []
result_list = []
next_call = time.time()


@app.route('/test', methods=['GET'])
def test():
    return Response(mimetype='application/json',
                    response=json.dumps({"result": "test"}),
                    status=200)


@app.route('/pullCompleted', methods=['POST'])
def pullCompleted():
    if request.method == "POST":
        top = int(request.args.get('top'))
        slice_index = min(top, len(result_list))
        return Response(mimetype='application/json',
                        response=json.dumps({"result": result_list[:slice_index]}),
                        status=200)


@app.route('/get_result', methods=['PUT'])
def get_result():
    if request.method == "PUT":
        result_list.append({"job_id": request.json["job_id"], "result": request.json["result"]})


def deploy_worker(app_path, exit_flag=True, min_count=1, max_count=1):
    user_data = f"""#!/bin/bash
    cd /home/ubuntu/cloud_computing_hw_2
    echo test >> test.txt
    git pull
    echo ORCHESTRATOR_IP = \\\"{ORCHESTRATOR_IP}\\\" >> worker/config.py
    echo EXIT_FLAG = {exit_flag} >> worker/config.py
    python3 {app_path}"""
    logging.info(f'User data: {user_data}')
    client = boto3.client('ec2', region_name=USER_REGION)
    response = client.run_instances(ImageId=WORKER_AMI_ID, InstanceType=INSTANCE_TYPE, MaxCount=max_count,
                                    MinCount=min_count, InstanceInitiatedShutdownBehavior='terminate',
                                    UserData=user_data, SecurityGroupIds=[SEC_GRP], KeyName='CC_HW2_EC2_KEY')
    logging.info(f'Deployed worker: {response}')
    return response


def check_time_first_in_line():
    dif = datetime.utcnow() - work_queue[0]["entry_time_utc"]
    return dif.seconds


@app.before_first_request
def scale_up():
    global next_call

    if work_queue and check_time_first_in_line() > MAX_TIME_IN_QUEUE:
        resource = boto3.resource('ec2', region_name=USER_REGION)
        response = deploy_worker('worker/app.py')
        instance = resource.Instance(id=response['Instances'][0]['InstanceId'])
        instance.wait_until_running()
    next_call = next_call + PERIODIC_ITERATION
    threading.Timer(next_call - time.time(), scale_up).start()


@app.route('/addJob', methods=['PUT'])
def add_job_to_queue():
    if request.method == "PUT":
        entry_time_utc = datetime.utcnow()
        work_queue.append({
            "job_id": uuid.uuid4().int,
            "entry_time_utc": entry_time_utc,
            "iterations": int(request.args.get("iterations")),
            "file": request.get_data()})
    return Response(status=200)


@app.route('/get_work', methods=['GET'])
def get_work():
    logging.info("Get work called")
    if request.method == "GET":
        if not work_queue:
            return Response(mimetype='application/json',
                            response=json.dumps({}),
                            status=200)
        else:
            job = work_queue[0]
            del work_queue[0]

            return Response(mimetype='application/json',
                            response=json.dumps({"job_id": job["job_id"],
                                                 "iterations": job["iterations"],
                                                 "file": str(job["file"]),
                                                 }),
                            status=200)


deploy_worker('worker/app.py',
              exit_flag=False,
              min_count=1,
              max_count=1)
