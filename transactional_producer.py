from confluent_kafka import Producer
from confluent_kafka.admin import AdminClient, NewTopic
from datetime import datetime
from avro import schema, io
from avro.datafile import DataFileWriter

# Kafka broker configuration
bootstrap_servers = 'localhost:9092'
topic = 'Rajeev'
avro_schema_str = """
{
    "type": "record",
    "name": "Message",
    "fields": [
        {"name": "id", "type": "int"},
        {"name": "content", "type": "string"}
    ]
}
"""

# Define Avro schema
avro_schema = schema.Parse(avro_schema_str)

# Create a Kafka producer instance
producer = Producer({
    'bootstrap.servers': bootstrap_servers,
    'transactional.id': 'my_transactional_producer'
})

# Initialize the producer as a transactional producer
producer.init_transactions()

# Start the transaction
producer.begin_transaction()

try:
    # Create Avro message
    message_value = {"id": 1, "content": "Hello, Avro!"}

    # Serialize the Avro message
    avro_writer = io.DatumWriter(avro_schema)
    avro_bytes_writer = io.BytesIO()
    data_file_writer = DataFileWriter(avro_bytes_writer, avro_writer, avro_schema)
    data_file_writer.append(message_value)
    data_file_writer.flush()
    serialized_message = avro_bytes_writer.getvalue()

    # Produce the Avro message within the transaction
    producer.produce(topic=topic, value=serialized_message)

    # Commit the transaction
    producer.commit_transaction()
    print("Transaction committed successfully.")

except Exception as e:
    # Abort the transaction in case of any exception
    producer.abort_transaction()
    print(f"Transaction aborted: {str(e)}")

finally:
    # Close the producer
    producer.close()
