import platform
import sys

from flask import Flask, jsonify

app = Flask(__name__)


@app.get("/health")
def health():
    return jsonify(ok=True, platform=f"{platform.system()} {platform.machine()}",
                   python=sys.version.split()[0])


@app.get("/add/<int:a>/<int:b>")
def add(a: int, b: int):
    return jsonify(result=a + b)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
