FROM debian:12-slim

## <Misc> ##
RUN apt-get update && apt-get install -fy mc curl wget lsb-release cron bsdextrautils zip unzip jq python3-flask python3-pika python3-pexpect
## </Misc> ##

## <GitHub CLI>
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
    apt update && apt install gh -y
## </GitHub CLI>

## <Sendmail> ##
RUN bash -c "DEBIAN_FRONTEND=noninteractive apt install -y postfix <<< $'2' && apt install -y opendkim opendkim-tools"
## </Sendmail> ##

## Setup entrypoint ##
ENTRYPOINT ["bash", "-c", "source $DOC/compose/wrapper/docker-entrypoint.sh"]
