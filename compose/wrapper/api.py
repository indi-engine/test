# Do imports
from flask import Flask, request, jsonify
import subprocess, pika, json, pexpect, re, pymysql
from pika.exceptions import ChannelClosedByBroker

# Instantiate Flask app
app = Flask(__name__)

# Check if given queue exists, i.e. user didn't closed the browser tab yet
def queue_exists(channel, name):
    try:
        channel.queue_declare(queue=name, passive=True)
        return True, channel
    except ChannelClosedByBroker:
        return False, channel.connection.channel()

# Send websocket message to open xterm in Indi Engine UI
def ws(to, data, mq, mysql):

    # Queue name prefix
    prefix = 'indi-engine.custom.opentab--'

    # Set up initial value for refresh flag
    if to['token']:
        exists, mq = queue_exists(mq, prefix + to['token'])
        refresh = not exists
        if refresh:
            mysql.execute("DELETE FROM `realtime` WHERE `type` = 'channel' AND `token` = %s", (to['token']))
    else:
        refresh = True

    # If token should be refreshed
    if refresh:

        # Get browser tab, if any opened by the user that can be identified by that pair
        mysql.execute(
            "SELECT `token` FROM `realtime` WHERE `type` = 'channel' AND `roleId` = %s AND `adminId` = %s",
            (to['roleId'], to['adminId'])
        )

        # If at least one found - refresh token
        if mysql.rowcount:
            to['token'] = mysql.fetchone()['token']

    # Send message
    mq.basic_publish(
        exchange = '',
        routing_key = prefix + to['token'],
        body = json.dumps(data)
    )

    # Return rabbitmq channel (existing or new)
    return mq

# Spawn bash script and stream stdout/stderr to a websocket channel
def bash_stream(
    command,
    data
):
    # Connect to RabbitMQ
    nn = pika.BlockingConnection(pika.ConnectionParameters('rabbitmq'))
    mq = nn.channel()

    # Instantiate mysql connection with db cursor
    mysql_conn = pymysql.connect(host='mysql', user='custom', password='custom', database='custom', autocommit=True)
    mysql = mysql_conn.cursor(pymysql.cursors.DictCursor)

    # Start bash script in a pseudo-terminal
    child = pexpect.spawn('bash -c "' + command + '"', encoding='utf-8')

    # Recipient definition
    to=data.get('to')

    # Send websocket message to open xterm in Indi Engine UI
    mq = ws(to, data, mq, mysql)

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

            # Send websocket message to open xterm in Indi Engine UI
            mq = ws(to, {
                'type': data.get('type'),
                'id': data.get('id'),
                'bytes': bytes
            }, mq, mysql)

        # If pexpect is SURE the script is done and the PTY is closed - break the loop
        except pexpect.EOF:
            break

    # Close script process
    child.close()

    # Indicate all done, if all done
    if child.exitstatus == 0 and child.signalstatus is None:
        mq = ws(to, {
            'type': data.get('type'),
            'id': data.get('id'),
            'bytes': 'All done.'
        }, mq, mysql)

    # Clone rabbitmq connection
    nn.close()

    # Close mysql cursor and connection
    mysql.close()
    mysql_conn.close()

    # Return
    return 'Executed', 200

# Add backup endpoint
@app.route('/backup', methods=['POST'])
def backup():

    # Get json data
    data = request.get_json(silent=True) or {}

    # Basic backup command
    command = 'source backup'

    # If scenario is to patch the most recent backup with current database (or current uploads) - add to command
    if data.get('scenario') in ['dump', 'uploads']:
        command += f" {data.get('scenario')} --recent"

    # Run bash script and stream stdout/stderr
    return bash_stream(command, data)

# Get restore status
@app.route('/restore/status', methods=['GET'])
def restore_status():

    # Get branch
    branch = subprocess.run(['git', 'rev-parse', '--abbrev-ref', 'HEAD'], capture_output=True, text=True)

    # If something went wrong - flush failure
    if branch.returncode != 0:
        return jsonify({'success': False, 'msg': branch.stderr}), 500

    # Get notes
    notes = subprocess.run(['git', 'notes', 'show'], capture_output=True, text=True)

    # Chec and return json
    if (
        branch.stdout.strip() == 'HEAD'
        and notes.returncode == 0
        and re.search(r' · [a-f0-9]{7}$', notes.stdout.strip())
    ):
        return json.dumps({
           'is_uncommitted_restore': True,
           'version': notes.stdout.strip()
        }, ensure_ascii=False), 200
    else:
        return json.dumps({
           'is_uncommitted_restore': False,
           'version': ''
        }, ensure_ascii=False), 200

# Get restore choices
@app.route('/restore/choices', methods=['GET'])
def restore_choices():

    # Get restore choices list
    choices = subprocess.run(
        ['gh', 'release', 'list', '--json', 'createdAt,isDraft,isLatest,isPrerelease,name,publishedAt,tagName'],
        capture_output=True, text=True
    )

    # If something went wrong - flush failure
    if choices.returncode != 0:
        return jsonify({'success': False, 'msg': choices.stderr}), 500

    # Cache choices
    with open('var/tmp/choices.json', 'w') as file:
        file.write(choices.stdout.strip())

    # Return output
    return choices.stdout.strip(), 200

# Do restore
@app.route('/restore', methods=['POST'])
def restore():

    # Get json data
    data = request.get_json(silent=True) or {}

    # Basic restore command
    command = 'CACHED=1 source restore'

    # If scenario is to restore just the database (or uploads), or to commit/cancel the restore - add to command
    if data.get('scenario') in ['dump', 'uploads', 'commit', 'cancel']:
        command += f" {data.get('scenario')}"

    # If scenario is not 'commit' or 'cancel'
    if data.get('scenario') in ['full', 'dump', 'uploads']:
        if bool(re.fullmatch(r'[a-zA-Z0-9._-]{1,63}', data.get('tagName'))):
            command += f" {data.get('tagName')}"
        else:
            return jsonify({'success': False, 'msg': 'Invalid tag name'}), 400

    # Run bash script and stream stdout/stderr
    return bash_stream(command, data)
