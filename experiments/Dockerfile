FROM alpine:3.20
RUN apk add --no-cache python3 nftables
COPY exp_probe.py /exp_probe.py
ENTRYPOINT ["python3", "-u", "/exp_probe.py"]
