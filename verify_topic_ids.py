#!/usr/bin/env python3

import argparse
import csv
import glob
import json
from kazoo.client import KazooClient # Doc https://kazoo.readthedocs.io/en/latest/basic_usage.html | Install: pip install kazoo
from pathlib import Path

OUTPUT_FILE = "topic_id_mismatch.csv"


def get_topic_id_from_zookeeper(zk_client, topic_name):
    """
    Retrieves the topic ID from ZooKeeper for a given topic name.
    """
    topic_path = f"/brokers/topics/{topic_name}"
    try:
        topic_data, _ = zk_client.get(topic_path)
        topic_data_decoded = topic_data.decode("utf-8")
        topic_info = json.loads(topic_data_decoded)
        topic_id = topic_info["topic_id"]
        return topic_id
    except Exception as e:
        print(f"Error retrieving topic ID from ZooKeeper for topic: {topic_name}")
        print(str(e))
        return None


def check_topic_id_mismatch(log_dir, zk_string):
    """
    Checks for topic ID mismatch between partition metadata and ZooKeeper.
    """
    zk_client = KazooClient(hosts=zk_string)
    try:
        zk_client.start()

        zk_topics = {}

        with open(OUTPUT_FILE, "w", newline="") as output_file:
            writer = csv.writer(output_file)
            writer.writerow(["Topic Partition", "Topic ID in Metadata", "Topic ID in ZooKeeper"])

            for metadata_file in glob.glob(f"{log_dir}/logs/*/partition.metadata"):
                topic_partition = Path(metadata_file).parts[-2]
                topic_name = topic_partition.rsplit("-", 1)[0]
                full_topic_partition = f"{log_dir}/{topic_partition}"

                with open(metadata_file, "r") as metadata:
                    for line in metadata:
                        if line.startswith("topic_id"):
                            topic_id_in_md = line.split()[1]
                            break

                if topic_name not in zk_topics:
                    topic_id_in_zk = get_topic_id_from_zookeeper(zk_client, topic_name)
                    zk_topics[topic_name] = topic_id_in_zk
                else:
                    topic_id_in_zk = zk_topics[topic_name]

                if topic_id_in_zk is not None and topic_id_in_md != topic_id_in_zk:
                    writer.writerow([full_topic_partition, topic_id_in_md, topic_id_in_zk])

    except Exception as e:
        print("Error occurred while checking topic ID mismatch.")
        print(str(e))

    finally:
        zk_client.stop()


if __name__ == "__main__":
    # Parse command-line arguments
    parser = argparse.ArgumentParser(description="Check topic ID mismatch between partition metadata and ZooKeeper.")
    parser.add_argument("-l", "--log-dir", required=True, help="Path to Kafka log directory")
    parser.add_argument("-z", "--zk-string", required=True, help="ZooKeeper connection string")
    args = parser.parse_args()

    log_dir = args.log_dir
    zk_string = args.zk_string

    # Perform topic ID mismatch check
    check_topic_id_mismatch(log_dir, zk_string)