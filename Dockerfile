FROM rancher/agent-base:v0.3.0

RUN curl -sL https://github.com/mikefarah/yq/releases/download/1.14.0/yq_linux_amd64 > /usr/local/bin/yq && \
    chmod +x /usr/local/bin/yq
RUN curl -sL https://github.com/hairyhenderson/gomplate/releases/download/v2.3.0/gomplate_linux-amd64-slim > /usr/local/bin/gomplate && \
    chmod +x /usr/local/bin/gomplate

COPY ./rancher-entrypoint.sh /

ENTRYPOINT ["/rancher-entrypoint.sh"]
