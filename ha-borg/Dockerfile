ARG BUILD_FROM
FROM $BUILD_FROM

RUN apk add --no-cache borgbackup openssh-client jq curl

COPY lib.sh run.sh /
RUN chmod +x /run.sh

# One-shot script: no s6 supervision, run.sh is the whole job.
ENTRYPOINT []
CMD ["/run.sh"]
