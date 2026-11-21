# Client image for the sandbox: git + curl + dig + python, no internet needed at runtime
FROM alpine:3.20
RUN apk add --no-cache git curl bind-tools python3 ca-certificates
CMD ["sleep", "infinity"]
