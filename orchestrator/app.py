from flask import Flask, Response, request
from dataclasses import dataclass
from datetime import datetime
import json
import uuid
import boto3
from config import MAX_TIME_IN_QUEUE, INSTANCE_TYPE, WORKER_AMI_ID, ORCHESTRATOR_IP, USER_REGION
import threading as th
import logging

logging.basicConfig(filename='orchestrator/orchestrator.log',
                    filemode='a',
                    format='%(asctime)s,%(msecs)d %(name)s %(levelname)s %(message)s',
                    datefmt='%H:%M:%S',
                    level=logging.DEBUG)

SEC_GRP = "CC_HW2_SEC_GRP"

app = Flask(__name__)


@dataclass
class Job:
    id: int
    entry_time_utc: datetime
    iterations: int
    data: str

    def to_dict(self):
        return {"job_id": self.id, "iterations": self.iterations, "data": self.data}


@dataclass
class CompletedJob:
    id: int
    completed_at: datetime
    hash: str

    def to_dict(self):
        return {'job_id': self.id, 'completed_at': self.completed_at, 'hash': hash}


@dataclass
class Memory:
    queue: list[Job]
    completed: list[CompletedJob]


memory = Memory([], [])


@app.route('/job/enqueue', methods=['PUT'])
def enqueue_new_job():
    entry_time_utc = datetime.utcnow()
    job_id = uuid.uuid4().int
    iterations = int(request.args.get("iterations"))
    data = str(request.get_data())
    memory.queue.append(Job(id=job_id, entry_time_utc=entry_time_utc, iterations=iterations, data=data))
    return Response(response=json.dumps({'job_id': job_id}), status=200)


@app.route('/job/completed', methods=['POST'])
def get_top_k_complete_jobs():
    top = int(request.args.get('top'))
    last_top_completed = memory.completed[:min(top, len(memory.completed))]
    response = [completed_job.to_dict() for completed_job in last_top_completed]
    return Response(mimetype='application/json',
                    response=json.dumps(response),
                    status=200)


@app.route('/job/completed', methods=['PUT'])
def append_completed_job():
    '''
    Append worker completed job to completed list
    '''
    completed_job = CompletedJob(id=int(request.json['job_id']),
                                 completed_at=datetime.now(),
                                 hash=request.json['result'])
    memory.completed.append(completed_job)
    return Response(status=200)


def deploy_worker(app_path, exit_flag=True, min_count=1, max_count=1):
    user_data = f"""#!/bin/bash
    cd /home/ubuntu/cloud_computing_hw_2
    git pull > test.txt
    echo ORCHESTRATOR_IP = \\\"{ORCHESTRATOR_IP}\\\" >> worker/config.py
    echo EXIT_FLAG = {exit_flag} >> worker/config.py
    export PATH=/usr/local/bin:$PATH
    python3 {app_path}"""
    logging.info(f'User data: {user_data}')
    client = boto3.client('ec2', region_name=USER_REGION)
    response = client.run_instances(ImageId=WORKER_AMI_ID, InstanceType=INSTANCE_TYPE, MaxCount=max_count,
                                    MinCount=min_count, InstanceInitiatedShutdownBehavior='terminate',
                                    UserData=user_data, SecurityGroupIds=[SEC_GRP], KeyName='CC_HW2_EC2_KEY')
    logging.info(f'Deployed worker: {response}')
    return response


@app.route('/job/consume', methods=['GET'])
def get_work():
    logging.info("Get work called")
    if not memory.queue:
        return Response(mimetype='application/json',
                        response=json.dumps({}),
                        status=200)
    job = memory.queue.pop(0)
    return Response(mimetype='application/json',
                    response=json.dumps(job.to_dict()),
                    status=200)


@app.before_first_request
def scale_up():
    lag = 0
    if memory.queue:
        lag = datetime.utcnow() - memory.queue[0].entry_time_utc
    if lag > MAX_TIME_IN_QUEUE:
        response = deploy_worker('worker/app.py')
        resource = boto3.resource('ec2', region_name=USER_REGION)
        instance = resource.Instance(id=response['Instances'][0]['InstanceId'])
        instance.wait_until_running()
    th.Timer(10.0, scale_up).start()


deploy_worker('worker/app.py',
              exit_flag=False,
              min_count=1,
              max_count=1)
