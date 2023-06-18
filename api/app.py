from flask import Response, Flask, request
import requests
from config import ORCHESTRATOR_IP
import json
import logging

logging.basicConfig(filename='api/api.log',
                    filemode='a',
                    format='%(asctime)s,%(msecs)d %(name)s %(levelname)s %(message)s',
                    datefmt='%H:%M:%S',
                    level=logging.DEBUG)

app = Flask(__name__)

@app.route('/enqueue', methods=['PUT'])
def enqueue():
    iterations = int(request.args.get("iterations"))
    response = requests.put(url=f"http://{ORCHESTRATOR_IP}:5000/job/enqueue?iterations={iterations}",
                            data=request.get_data())
    return Response(response=json.dumps(response.json()), status=200, mimetype='application/json')


@app.route('/pullCompleted', methods=['POST'])
def pullCompleted():
    top = int(request.args.get('top'))
    response = requests.post(f"http://{ORCHESTRATOR_IP}:5000/job/completed?top={top}")
    return Response(response=json.dumps(response.json()), status=200, mimetype='application/json')


if __name__ == '__main__':
    app.run()
