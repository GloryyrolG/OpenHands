#!/bin/bash
echo "[pp-wrapper] starting at $(date), PID=$$" >&2
/usr/local/bin/openhands-agent-server-orig "$@" &
PID=$!
echo "[pp-wrapper] launched orig PID=$PID" >&2

# Wait for _MEI* dir AND system_prompt files to appear (extraction takes a moment)
PROMPT_FILES=""
for i in $(seq 1 80); do
    DIR=$(find /tmp/_MEI* -maxdepth 0 -type d 2>/dev/null | head -1)
    if [ -n "$DIR" ]; then
        PROMPT_FILES=$(find "$DIR" -name "system_prompt*.j2" 2>/dev/null)
        if [ -n "$PROMPT_FILES" ]; then
            echo "[pp-wrapper] found files on attempt $i, dir=$DIR" >&2
            break
        fi
    fi
    sleep 0.1
done

if [ -z "$PROMPT_FILES" ]; then
    echo "[pp-wrapper] WARNING: system_prompt*.j2 not found after 8s" >&2
else
    echo "[pp-wrapper] prompt files: $PROMPT_FILES" >&2

    # CDA branding
    find "$DIR" -name "system_prompt*.j2" -exec sed -i 's/OpenHands/CDA/g' {} + 2>/dev/null
    echo "[pp-wrapper] applied CDA branding" >&2

    # PREPEND TOOL_DISCIPLINE + WEB_PREVIEW at the TOP of each prompt file.
    # The original system prompt is ~70KB but the LLM limit is 50KB — appended content
    # gets truncated. Prepending ensures our instructions are always in context.
    for f in $PROMPT_FILES; do
        if ! grep -q 'TOOL_DISCIPLINE' "$f" 2>/dev/null; then
            ORIG=$(cat "$f")
            printf '<TOOL_DISCIPLINE>\nCRITICAL: Every response MUST call exactly one tool. NEVER produce a text-only response without calling a tool. Put all reasoning/analysis in the "thought" field of your tool call — not as a standalone text response. If the task is complete, call the Finish tool. If you need to think, use the terminal tool with an echo command. A response without a tool call will immediately terminate the session with an error.\n</TOOL_DISCIPLINE>\n\n<WEB_PREVIEW>\nAfter you finish building any web application, ALWAYS start it immediately on port 8011 — do not wait for the user to ask. The running app will automatically appear in the preview panel on the right side of the screen.\n\nCRITICAL execution order — follow exactly, no deviations:\n1. Write the app file\n2. NEXT action: run the nohup start command (terminal) — do NOT send a message between step 1 and 2\n3. NEXT action: verify with curl\n4. Only THEN send a message to the user with the result\n\n- Run in background: nohup ... > /tmp/app.log 2>&1 &\n- After starting, verify: sleep 2 && curl -s -o /dev/null -w '"'"'%%{http_code}'"'"' http://localhost:8011\n- If it fails to start: cat /tmp/app.log\n\nStart commands (always bind to 0.0.0.0:8011):\n  Streamlit: nohup streamlit run app.py --server.port 8011 --server.address 0.0.0.0 > /tmp/app.log 2>&1 &\n  FastAPI:   nohup uvicorn main:app --host 0.0.0.0 --port 8011 > /tmp/app.log 2>&1 &\n  Flask:     nohup flask run --host 0.0.0.0 --port 8011 > /tmp/app.log 2>&1 &\n  Gradio:    use launch(server_port=8011, server_name="0.0.0.0")\n  Node/Next: nohup npm run dev -- --port 8011 > /tmp/app.log 2>&1 &\n  Django:    nohup python manage.py runserver 0.0.0.0:8011 > /tmp/app.log 2>&1 &\n</WEB_PREVIEW>\n\n' > "$f" && printf '%s' "$ORIG" >> "$f"
            echo "[pp-wrapper] prepended TOOL_DISCIPLINE+WEB_PREVIEW to $f, exit=$?" >&2
        fi
    done
    echo "[pp-wrapper] patch complete" >&2
fi

echo "[pp-wrapper] waiting for PID=$PID" >&2
wait $PID
