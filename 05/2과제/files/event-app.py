from fastapi import FastAPI
from datetime import datetime
import uvicorn

app = FastAPI()

@app.get("/")
def root():
    return {"status": "ok", "message": "WorldSkills 2026", "time": datetime.now().isoformat()}

@app.get("/health")
def health():
    return {"status": "healthy"}
    
if __name__ == "__main__":
    uvicorn.run(app, host="127.0.0.1", port=8080)