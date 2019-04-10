# Demo leveraging Confluent and DataStax for fraud Analysis

## Starting Confluent Containers

1. Clone this repository on your laptop

```
git clone https://github.com/clun/confluent-datastax-demo.git
```

2. Download Kafka Connector from datastax and put `kafka-connect-dse-1.0.0.jar` jar in folder `dse-kafka-connector`

3. Start confluents containers with `zookeeper`, `kafka`, `schema-registry`, `ksql-server`, `ksql-cli`,
`gess` (injector), `send-gess-to-kafka` (UDP Proxy), `kafkahq` (Web UI)

```
cd confluent-datastax-demo

docker-compose -f docker-compose-confluent.yml up -d
```

4. Wait for containers to start. You can check that topic `atm_txns_gess` is feeded using [Confluent Control Center](http://localhost:9021). In the UI go to `Topics` then select `atm_txns_gess` and then pick tab `inspect`

You can also use the following command line :

```
docker exec -i -t confluent-datastax-demo_kafka_1 kafka-console-consumer --bootstrap-server localhost:9092 --from-beginning --topic atm_txns_gess
```

## KSQL

1. Open a shell and use the following command to get a kSQL Shell :

```
docker-compose -f docker-compose-confluent.yml  exec ksql-cli bash -c 'echo -e "\n\n⏳ Waiting for KSQL to be available before launching CLI\n"; while [ $(curl -s -o /dev/null -w %{http_code} http://ksql-server:8088/) -eq 000 ] ; do echo -e $(date) "KSQL Server HTTP state: " $(curl -s -o /dev/null -w %{http_code} http://ksql-server:8088/) " (waiting for 200)" ; sleep 5 ; done; ksql http://ksql-server:8088'
```

2. List Existing Topics with 

```
LIST TOPICS;
```

3. Display the same topic with the following 

```
PRINT 'atm_txns_gess' FROM BEGINNING;
```

4. Register the topic as a KSQL stream

```sql
CREATE STREAM ATM_TXNS_GESS (account_id VARCHAR, \
                            atm VARCHAR, \
                            location STRUCT<lon DOUBLE, \
                                            lat DOUBLE>, \
                            amount INT, \
                            timestamp VARCHAR, \
                            transaction_id VARCHAR) \
            WITH (KAFKA_TOPIC='atm_txns_gess', \
            VALUE_FORMAT='JSON', \
            TIMESTAMP='timestamp', \
            TIMESTAMP_FORMAT='yyyy-MM-dd HH:mm:ss X');
```

5. Query the stream

```sql
SELECT TIMESTAMPTOSTRING(ROWTIME, 'HH:mm:ss'), ACCOUNT_ID, ATM, AMOUNT\
        FROM ATM_TXNS_GESS \
        LIMIT 5;
```

6. Create a clone of the stream

```sql
CREATE STREAM ATM_TXNS_GESS_02 WITH (PARTITIONS=1) AS \
        SELECT * FROM ATM_TXNS_GESS;
```

7. Join the stream (two in practice, but logically still just a single Kafka topic). Also calculate time between two events (useful for spotting past-joins, not future).

We display here transactions of same Account, different transactions within 10 minutes.
 
```sql
SELECT S1.ACCOUNT_ID, \
        TIMESTAMPTOSTRING(S1.ROWTIME, 'HH:mm:ss'), \
        TIMESTAMPTOSTRING(S2.ROWTIME, 'HH:mm:ss'), \
        (S2.ROWTIME - S1.ROWTIME)/1000, \
        S1.TRANSACTION_ID ,S2.TRANSACTION_ID \
FROM   ATM_TXNS_GESS S1 \
       INNER JOIN ATM_TXNS_GESS_02 S2 \
        WITHIN 10 MINUTES \
        ON S1.ACCOUNT_ID = S2.ACCOUNT_ID \
LIMIT 40;
```

8. Filter to avoid same location

```sql
SELECT S1.ACCOUNT_ID, \
        TIMESTAMPTOSTRING(S1.ROWTIME, 'HH:mm:ss'), \
        TIMESTAMPTOSTRING(S2.ROWTIME, 'HH:mm:ss'), \
        (S2.ROWTIME - S1.ROWTIME)/1000 , \
        S1.ATM, S2.ATM, \
        S1.TRANSACTION_ID ,S2.TRANSACTION_ID \
FROM   ATM_TXNS_GESS S1 \
       INNER JOIN ATM_TXNS_GESS_02 S2 \
        WITHIN (0 MINUTES, 10 MINUTES) \
        ON S1.ACCOUNT_ID = S2.ACCOUNT_ID \
WHERE   S1.TRANSACTION_ID != S2.TRANSACTION_ID \
  AND   (S1.location->lat != S2.location->lat OR \
         S1.location->lon != S2.location->lon) \
  AND   S2.ROWTIME != S1.ROWTIME \
LIMIT 20;
```

9. Adding distance and speed

Derive distance between ATMs & calculate required speed: 

```sql
SELECT S1.ACCOUNT_ID, \
        TIMESTAMPTOSTRING(S1.ROWTIME, 'yyyy-MM-dd HH:mm:ss'), TIMESTAMPTOSTRING(S2.ROWTIME, 'HH:mm:ss'), \
        (CAST(S2.ROWTIME AS DOUBLE) - CAST(S1.ROWTIME AS DOUBLE)) / 1000 / 60 AS MINUTES_DIFFERENCE,  \
        CAST(GEO_DISTANCE(S1.location->lat, S1.location->lon, S2.location->lat, S2.location->lon, 'KM') AS INT) AS DISTANCE_BETWEEN_TXN_KM, \
        GEO_DISTANCE(S1.location->lat, S1.location->lon, S2.location->lat, S2.location->lon, 'KM') / ((CAST(S2.ROWTIME AS DOUBLE) - CAST(S1.ROWTIME AS DOUBLE)) / 1000 / 60 / 60) AS KMH_REQUIRED, \
        S1.ATM, S2.ATM \
FROM   ATM_TXNS_GESS S1 \
       INNER JOIN ATM_TXNS_GESS_02 S2 \
        WITHIN (0 MINUTES, 10 MINUTES) \
        ON S1.ACCOUNT_ID = S2.ACCOUNT_ID \
WHERE   S1.TRANSACTION_ID != S2.TRANSACTION_ID \
  AND   (S1.location->lat != S2.location->lat OR \
         S1.location->lon != S2.location->lon) \
  AND   S2.ROWTIME != S1.ROWTIME \
LIMIT 20;
```

10. Persist as a new stream:

```sql
CREATE STREAM ATM_POSSIBLE_FRAUD  \
    WITH (PARTITIONS=1) AS \
SELECT S1.ROWTIME AS TX1_TIMESTAMP, S2.ROWTIME AS TX2_TIMESTAMP, \
        GEO_DISTANCE(S1.location->lat, S1.location->lon, S2.location->lat, S2.location->lon, 'KM') AS DISTANCE_BETWEEN_TXN_KM, \
        (S2.ROWTIME - S1.ROWTIME) AS MILLISECONDS_DIFFERENCE,  \
        (CAST(S2.ROWTIME AS DOUBLE) - CAST(S1.ROWTIME AS DOUBLE)) / 1000 / 60 AS MINUTES_DIFFERENCE,  \
        GEO_DISTANCE(S1.location->lat, S1.location->lon, S2.location->lat, S2.location->lon, 'KM') / ((CAST(S2.ROWTIME AS DOUBLE) - CAST(S1.ROWTIME AS DOUBLE)) / 1000 / 60 / 60) AS KMH_REQUIRED, \
        S1.ACCOUNT_ID AS ACCOUNT_ID, \
        S1.TRANSACTION_ID AS TX1_TRANSACTION_ID, S2.TRANSACTION_ID AS TX2_TRANSACTION_ID, \
        S1.AMOUNT AS TX1_AMOUNT, S2.AMOUNT AS TX2_AMOUNT, \
        S1.ATM AS TX1_ATM, S2.ATM AS TX2_ATM, \
        CAST(S1.location->lat AS STRING) + ',' + CAST(S1.location->lon AS STRING) AS TX1_LOCATION, \
        CAST(S2.location->lat AS STRING) + ',' + CAST(S2.location->lon AS STRING) AS TX2_LOCATION \
FROM   ATM_TXNS_GESS S1 \
       INNER JOIN ATM_TXNS_GESS_02 S2 \
        WITHIN (0 MINUTES, 10 MINUTES) \
        ON S1.ACCOUNT_ID = S2.ACCOUNT_ID \
WHERE   S1.TRANSACTION_ID != S2.TRANSACTION_ID \
  AND   (S1.location->lat != S2.location->lat OR \
         S1.location->lon != S2.location->lon) \
  AND   S2.ROWTIME != S1.ROWTIME;
```

11. Run queries on the new stream

```sql
SELECT ACCOUNT_ID, \
        TIMESTAMPTOSTRING(TX1_TIMESTAMP, 'yyyy-MM-dd HH:mm:ss'), TIMESTAMPTOSTRING(TX2_TIMESTAMP, 'HH:mm:ss'), \
        TX1_ATM, TX2_ATM, \
        DISTANCE_BETWEEN_TXN_KM, MINUTES_DIFFERENCE \
FROM ATM_POSSIBLE_FRAUD;

12. Last KSQL to format stream to push to DataStax

```sql
CREATE STREAM ATM_TXNS_DSE WITH (PARTITIONS=1) AS \
  SELECT TIMESTAMPTOSTRING(ROWTIME, 'yyyy-MM-dd HH:mm:ss') AS TIMESTAMP, TRANSACTION_ID, ACCOUNT_ID, ATM, AMOUNT,location->lon AS LON, location->lat as LAT FROM ATM_TXNS_GESS;
```

13. Go back to the control center : watch KQL queries live `DEVELOPMENT > KSQL > STREAMS` and  `DEVELOPMENT > KSQL > RUNNING QUERIES`. 

Now we will send data to DataStax with Kafka-Connect. We can start by showing connect in the control center UI.


## KAFKA-CONNECT-SINK

1. Start Datastax Components

```
docker-compose -f docker-compose-datastax.yml up -d
```

You now have access to [DataStax OpsCenter](http://localhost:8888/) and [DataStax Studio](http://localhost:9091/)


2. Open the studio and go to notebook `Demo_Kafka`

3. Create `bank` keyspace and tables `transactions`, `possible_fraud` by executing  first cell

4. You can now register DSE Sink in Kafka Connect :

```
curl -s \
     -X "POST" "http://localhost:18083/connectors/" \
     -H "Content-Type: application/json" \
     -d '{
      "name": "dse_tx_flat",
      "config": {
        "connector.class": "com.datastax.kafkaconnector.DseSinkConnector",
                "tasks.max": "1",
                "topics": "ATM_TXNS_DSE",
                "contactPoints": "dse",
                "loadBalancing.localDc": "DC1",
                "port": 9042,
                "maxConcurrentRequests": 10,
                "maxNumberOfRecordsInBatch": 20,
                "queryExecutionTimeout": 1000,
                "connectionPoolLocalSize": 1,
                "jmx": false,
                "compression": "None",
                "auth.provider": "None",
                "topic.ATM_TXNS_DSE.bank.transactions.mapping": "account_id=value.ACCOUNT_ID, transaction_id=value.TRANSACTION_ID, timestamp=value.TIMESTAMP, atm=value.ATM, amount=value.AMOUNT, longitude=value.LON, latitude=value.LAT",
                "topic.ATM_TXNS_DSE.bank.transactions.consistencyLevel": "ONE",
                "topic.ATM_TXNS_DSE.bank.transactions.ttl": -1,
                "topic.ATM_TXNS_DSE.bank.transactions.nullToUnset": "true",
                "topic.ATM_TXNS_DSE.bank.transactions.deletesEnabled": "true",
                "topic.ATM_TXNS_DSE.codec.locale": "en_US",
                "topic.ATM_TXNS_DSE.codec.timeZone": "UTC",
                "topic.ATM_TXNS_DSE.codec.timestamp": "yyyy-MM-dd HH:mm:ss",
                "topic.ATM_TXNS_DSE.codec.date": "ISO_LOCAL_DATE",
                "topic.ATM_TXNS_DSE.codec.time": "ISO_LOCAL_TIME",
                "topic.ATM_TXNS_DSE.codec.unit": "MILLISECONDS"
            }
        }' 
```

5. Go back to the DataStax studio and query the table, follow the studio elements

6. Open Datastax Studio Fraud notebook (data in not in the DB so do not execute)




