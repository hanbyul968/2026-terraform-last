from flask import Flask, request, jsonify
import logging
import random
import time

app = Flask(__name__)

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s %(levelname)s %(message)s'
)
logger = logging.getLogger(__name__)

USERS = ["alice", "bob", "carol", "dave", "eve"]
ACTIONS = ["login", "logout", "purchase", "view_item", "search"]

@app.route("/")
def index():
    return jsonify({"service": "m3-log-generator", "status": "healthy"})

@app.route("/health")
def health():
    return jsonify({"status": "ok"}), 200

@app.route("/generate")
def generate():
    count = int(request.args.get("count", 10))
    logs = []
    for _ in range(count):
        user = random.choice(USERS)
        action = random.choice(ACTIONS)
        level = random.choice(["INFO", "INFO", "INFO", "WARNING", "ERROR"])
        msg = f"user={user} action={action} status={'success' if level == 'INFO' else 'failed'}"
        if level == "INFO":
            logger.info(msg)
        elif level == "WARNING":
            logger.warning(msg)
        else:
            logger.error(msg)
        logs.append({"level": level, "message": msg})
        time.sleep(0.05)
    return jsonify({"generated": count, "logs": logs})

@app.route("/error")
def trigger_error():
    logger.error("manual error triggered by /error endpoint")
    return jsonify({"status": "error logged"}), 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
