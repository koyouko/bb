#!/usr/bin/env python3

from kazoo.client import KazooClient
import csv

OUTPUT_FILE = "topic_id_mismatch.csv"

def get_topic_id_from_zookeeper(zk_client, topic_name):
    topic_path = "/brokers/topics/" + topic_name
    topic_data, _ = zk_client.get(topic_path)
    topic_id = topic_data["topic_id"]
    return topic_id

def check_topic_id_mismatch(log_dir, zk_string):
    zk_topics = []
    zk_client = KazooClient(hosts=zk_string)
    zk_client.start()

    with open(OUTPUT_FILE, "w", newline="") as csvfile:
        writer = csv.writer(csvfile)
        writer.writerow(["Topic Partition", "Topic ID (Metadata)", "Topic ID (ZooKeeper)"])

        for metadata_file in log_dir.glob("logs/*/partition.metadata"):
            topic_partition = metadata_file.parts[-2]
            topic_name = topic_partition.rsplit("-", 1)[0]

            with open(metadata_file, "r") as metadata:
                for line in metadata:
                    if line.startswith("topic_id"):
                        topic_id_in_md = line.split()[1]
                        break

            if topic_name not in zk_topics:
                zk_topics.append(topic_name)
                topic_id_in_zk = get_topic_id_from_zookeeper(zk_client, topic_name)
            else:
                topic_id_in_zk = zk_topics[zk_topics.index(topic_name) + 1]

            if topic_id_in_md != topic_id_in_zk:
                writer.writerow([topic_partition, topic_id_in_md, topic_id_in_zk])

    zk_client.stop()

if __name__ == "__main__":
    import argparse
    from pathlib import Path

    parser = argparse.ArgumentParser(description="Check topic ID mismatch between partition metadata and ZooKeeper.")
    parser.add_argument("-l", "--log-dir", required=True, help="Path to Kafka log directory")
    parser.add_argument("-z", "--zk-string", required=True, help="ZooKeeper connection string")
    
    args = parser.parse_args()

    log_dir = Path(args.log_dir)
    zk_string = args.zk_string

    check_topic_id_mismatch(log_dir, zk_string)
