# Do imports
from flask import Flask, request
import subprocess, pika, json, pexpect

# Instantiate app
app = Flask(__name__)

# Add backup endpoint
@app.route('/backup', methods=['GET','POST'])
def backup():

    # Connect to RabbitMQ
    nn = pika.BlockingConnection(pika.ConnectionParameters('rabbitmq'))
    mq = nn.channel()

    # Get json data
    data = request.get_json(silent=True) or {}

    # Prepare queue name
    qn = 'indi-engine.custom.opentab--' + data.get('to')

    # Basic backup command
    cmd = 'source backup'

    # If scenario is to patch the most recent backup with current database (or current uploads) - add to command
    if data.get('scenario') == 'dump' or data.get('scenario') == 'uploads':
        cmd += ' ' + data.get('scenario') + ' --recent'

    # Start bash script in a pseudo-terminal
    child = pexpect.spawn('bash -c "' + cmd + '"', encoding='utf-8')

    # Open xterm in Indi Engine UI
    mq.basic_publish(
        exchange = '',
        routing_key = qn,
        body = json.dumps(data)
    )

    # While script is running
    while True:
        try:

            # Read as many bytes as written by script
            bytes = child.read_nonblocking(size=1024, timeout=100)

            # If script has finished and no bytes were read
            # (maybe just before the PTY fully closed),
            # but EOF was not raised yet - break the loop
            if not bytes and not child.isalive():
                break

            # Else push to websocket
            mq.basic_publish(
                exchange = '',
                routing_key = qn,
                body = json.dumps({
                    'type': data.get('type'),
                    'id': data.get('id'),
                    'bytes': bytes
                })
            )

        # If pexpect is SURE the script is done and the PTY is closed - break the loop
        except pexpect.EOF:
            break

    # Close script process
    child.close()

    # Indicate all done
    mq.basic_publish(
        exchange = '',
        routing_key = qn,
        body = json.dumps({
            'type': data.get('type'),
            'id': data.get('id'),
            'bytes': 'All done.'
        })
    )

    # Clone connection
    nn.close()

    #
    return 'Triggered', 200