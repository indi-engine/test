# Do imports
from flask import Flask, request, jsonify
import subprocess, pika, json, pexpect, re

# Instantiate app
app = Flask(__name__)

# Spawn bash script and stream stdout/stderr to a websocket channel
def bash_stream(
    command,
    data
):
    # Connect to RabbitMQ
    nn = pika.BlockingConnection(pika.ConnectionParameters('rabbitmq'))
    mq = nn.channel()
    qn = 'indi-engine.custom.opentab--' + data.get('to') # todo: add validation

    # Start bash script in a pseudo-terminal
    child = pexpect.spawn('bash -c "' + command + '"', encoding='utf-8')

    # Send websocket message to open xterm in Indi Engine UI
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

    # Indicate all done, if all done
    if child.exitstatus == 0 and child.signalstatus is None:
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

    # Return
    return 'Executed', 200

# Returns True if `tag` is a valid GitHub tag name, False otherwise.
# Follows the rules of git-check-ref-format and GitHub's additional constraints.
def is_valid_github_tag(tag):

    # Forbidden start/end/substrings
    if tag.startswith('/') or tag.endswith('/') or tag.endswith('.lock') or tag == '@':
        return False

    # Forbidden patterns or characters
    if any(re.search(p, tag) for p in [
        r'[\x00-\x20\x7f]',    # ASCII control chars and DEL
        r'[\~\^:\?\*\[\\]',    # Special forbidden chars
        r'//',                 # Double slash
        r'\.\.',               # Double dot
        r'@{',                 # At sign + {
    ]):
        return False

    # It's seems it's ok
    return True

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

    # If something went wrong - flush failure
    if branch.stdout.strip() == 'HEAD' and notes.returncode != 0:
        return jsonify({'success': False, 'msg': notes.stderr}), 500

    # Return output
    return json.dumps({
       'is_uncommitted_restore': branch.stdout.strip() == 'HEAD',
       'version': notes.stdout.strip()
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

    # Return output
    return choices.stdout.strip(), 200

# Do restore
@app.route('/restore', methods=['POST'])
def restore():

    asd="test"
    # Get json data
    data = request.get_json(silent=True) or {}

    # Basic restore command
    command = 'source restore'

    # If scenario is to restore just the database (or uploads), or to commit/cancel the restore - add to command
    if data.get('scenario') in ['dump', 'uploads', 'commit', 'cancel']:
        command += f" {data.get('scenario')}"

    # If scenario is not 'commit' or 'cancel'
    if data.get('scenario') in ['full', 'dump', 'uploads']:
        if is_valid_github_tag(data.get('tagName'))
            command += f" {data.get('tagName')}"

    # Run bash script and stream stdout/stderr
    return bash_stream(command, data)
