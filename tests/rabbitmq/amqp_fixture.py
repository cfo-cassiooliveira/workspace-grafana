"""Fixture AMQP do smoke-rabbitmq.sh: cria/remove uma fila de teste sem consumidor na vhost dev.

Uso: amqp_fixture.py fill <fila> <quantidade> | amqp_fixture.py delete <fila>
A senha do smoke-app vem da variável SMOKE_APP_PASSWORD (nunca do argv). O smoke-app só publica em exchanges smoke.*
(sem permissão na exchange padrão), por isso a fila é ligada à smoke.events com uma routing key própria.
"""
import os
import sys

import pika

EXCHANGE = "smoke.events"
PREFIX = "smoke-consumer.grafana-"


def connect():
    credentials = pika.PlainCredentials("smoke-app", os.environ["SMOKE_APP_PASSWORD"])
    params = pika.ConnectionParameters(host=os.environ.get("AMQP_HOST", "rabbitmq"), virtual_host="dev",
                                       credentials=credentials, connection_attempts=3, retry_delay=2,
                                       socket_timeout=10, blocked_connection_timeout=30)
    return pika.BlockingConnection(params)


def fill(channel, queue, count):
    # Fila clássica durável, não exclusiva e sem auto-delete: continua existindo (sem consumidor) depois que a conexão fecha.
    # Durável porque o RabbitMQ 4.x recusa fila transitória não exclusiva (feature transient_nonexcl_queues).
    channel.queue_declare(queue=queue, durable=True, auto_delete=False, arguments={"x-queue-type": "classic"})
    channel.queue_bind(queue=queue, exchange=EXCHANGE, routing_key=queue)
    channel.confirm_delivery()
    for i in range(count):
        channel.basic_publish(EXCHANGE, queue, f"grafana smoke {i}".encode(), mandatory=True)
    print(f"PASS  {count} mensagens publicadas em {queue}", flush=True)


def delete(channel, queue):
    channel.queue_delete(queue=queue)
    print(f"PASS  fila {queue} removida", flush=True)


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("fill", "delete") or not sys.argv[2].startswith(PREFIX):
        sys.exit(f"uso: fill|delete {PREFIX}<id> [quantidade]")
    connection = connect()
    try:
        channel = connection.channel()
        if sys.argv[1] == "fill":
            fill(channel, sys.argv[2], int(sys.argv[3]))
        else:
            delete(channel, sys.argv[2])
    finally:
        if connection.is_open:
            connection.close()


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:  # noqa: BLE001 - o smoke lê a linha FAIL e reprova.
        print(f"FAIL  {type(exc).__name__}: {exc}", flush=True)
        sys.exit(1)
