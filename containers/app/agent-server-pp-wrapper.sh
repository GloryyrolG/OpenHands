#!/bin/bash
echo "[pp-wrapper] starting at $(date), PID=$$" >&2
/usr/local/bin/openhands-agent-server-orig "$@" &
PID=$!
echo "[pp-wrapper] launched orig PID=$PID" >&2

for i in $(seq 1 80); do
    DIR=$(find /tmp/_MEI* -maxdepth 0 -type d 2>/dev/null | head -1)
    if [ -n "$DIR" ]; then
        echo "[pp-wrapper] found MEI dir=$DIR on attempt $i" >&2
        PROMPT_FILES=$(find "$DIR" -name "system_prompt*.j2" 2>/dev/null)
        echo "[pp-wrapper] prompt files: $PROMPT_FILES" >&2

        # CDA branding
        find "$DIR" -name "system_prompt*.j2" -exec sed -i 's/OpenHands/CDA/g' {} + 2>/dev/null
        echo "[pp-wrapper] applied CDA branding" >&2

        # APP_AUTO_DEPLOY instruction (use printf to avoid heredoc/pipe issues)
        for f in $PROMPT_FILES; do
            if ! grep -q 'APP_AUTO_DEPLOY' "$f" 2>/dev/null; then
                printf '\n<APP_AUTO_DEPLOY>\nWhen you finish writing a web application (Streamlit, Gradio, FastAPI, Flask, or any web framework), automatically start it in the background on port 8011 so users can preview it immediately.\n\nRules:\n- Always bind to host 0.0.0.0 and port 8011\n- Start in background so it does not block further actions\n- After starting, wait 3 seconds then verify: curl -s -o /dev/null -w '"'"'%%{http_code}'"'"' http://localhost:8011\n\nCommon start commands:\n- Streamlit:  nohup streamlit run app.py --server.port 8011 --server.address 0.0.0.0 > /tmp/app.log 2>&1 &\n- Gradio:     ensure launch(server_port=8011, server_name="0.0.0.0") then run\n- FastAPI:    nohup uvicorn main:app --host 0.0.0.0 --port 8011 > /tmp/app.log 2>&1 &\n- Flask:      nohup flask run --host 0.0.0.0 --port 8011 > /tmp/app.log 2>&1 &\n- Node/Next:  nohup npm run dev -- --port 8011 > /tmp/app.log 2>&1 &\n</APP_AUTO_DEPLOY>\n' >> "$f" 2>/dev/null
                echo "[pp-wrapper] appended APP_AUTO_DEPLOY to $f, exit=$?" >&2
            else
                echo "[pp-wrapper] APP_AUTO_DEPLOY already in $f" >&2
            fi
        done
        break
    fi
    sleep 0.1
done

if [ -z "$DIR" ]; then
    echo "[pp-wrapper] WARNING: never found _MEI* directory after 8s" >&2
fi

echo "[pp-wrapper] waiting for PID=$PID" >&2
wait $PID
