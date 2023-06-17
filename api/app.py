from flask import Response, Flask, request
import requests
from config import ORCHESTRATOR_IP
import json


@app.route('/enqueue', methods=['PUT'])
def enqueue():
    iterations = int(request.args.get("iterations"))
    res = requests.put(url=f"http://{ORCHESTRATOR_IP}:5000/addJob?iterations={iterations}", data=request.get_data())
    return Response(status=res.status_code)


@app.route('/pullCompleted', methods=['POST'])
def pullCompleted():
    top = int(request.args.get('top'))
    respond = requests.post(f"http://{ORCHESTRATOR_IP}:5000/pullCompleted?top={top}")
    return Response(mimetype='application/json', response=json.dumps(respond.json()), status=200)


app = Flask(__name__)

if __name__ == '__main__':
    app.run()
