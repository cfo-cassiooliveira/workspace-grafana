# Cliente AMQP descartável do smoke-rabbitmq.sh (mutation check dos alertas). Mesma base do smoke do projeto rabbitmq.
FROM python:3.13-alpine@sha256:9ef1a599f863231c3d91e941389bfdc4a2d6070557243d54df1a4e57015b960e
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir --disable-pip-version-check --require-hashes -r requirements.txt
COPY amqp_fixture.py ./
USER nobody
ENTRYPOINT ["python", "/app/amqp_fixture.py"]
