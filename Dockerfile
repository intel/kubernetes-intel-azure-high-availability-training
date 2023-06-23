ARG DEBIAN_FRONTEND=noninteractive

FROM python:3.9

COPY requirements.txt /src/requirements.txt
RUN python3 -m pip install -r /src/requirements.txt --quiet --no-cache-dir