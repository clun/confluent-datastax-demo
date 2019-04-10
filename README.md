# Demo leveraging Confluent and DataStax for fraud Analysis

## Starting Confluent Containers

1. Clone this repository on your laptop






1. Start confluents containers with `zookeeper`, `kafka`, `schema-registry`, `ksql-server`, `ksql-cli`,
`gess` (injector), `send-gess-to-kafka` (UDP Proxy), `kafkahq` (Web UI)

```
docker-compose -f docker-compose-confluent.yml up -d
```

2. Wait for containers to start. You can check that topic `atm_txns_gess` is feeded using [KafkaHQ UI](http://localhost:8080/docker-kafka-server/topic).You can also use the following command line :

```
docker exec -i -t confluent-datastax-demo_kafka_1 kafka-console-consumer --bootstrap-server localhost:9092 --from-beginning --topic atm_txns_gess
```

## KSQL

1. Open a shell and use the following command to get a kSQL Shell :

```
docker-compose exec ksql-cli bash -c 'echo -e "\n\n⏳ Waiting for KSQL to be available before launching CLI\n"; while [ $(curl -s -o /dev/null -w %{http_code} http://ksql-server:8088/) -eq 000 ] ; do echo -e $(date) "KSQL Server HTTP state: " $(curl -s -o /dev/null -w %{http_code} http://ksql-server:8088/) " (waiting for 200)" ; sleep 5 ; done; ksql http://ksql-server:8088'
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
```

## KAFKA-CONNECT-SINK

1. Start Datastax Components

```
docker-compose -f docker-compose-2-db.yml up -d
```

2. Open the studio and go to notebook `Demo_Kafka`

3. Create `bank` keyspace and tables `transactions`, `possible_fraud` by executing the first cell

4. You can now start the Kafka Connect :

```

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
            
CREATE STREAM ATM_TXNS_DSE WITH (PARTITIONS=1) AS \
	SELECT TIMESTAMPTOSTRING(ROWTIME, 'yyyy-MM-dd HH:mm:ss') AS TIMESTAMP, TRANSACTION_ID, ACCOUNT_ID, ATM, AMOUNT,location->lon AS LON, location->lat as LAT FROM ATM_TXNS_GESS;
```

```
docker-compose -f docker-compose-3-kafkaconnect.yml up -d
```

docker-compose -f docker-compose-3-kafkaconnect.yml stop kafka-connect
docker-compose -f docker-compose-3-kafkaconnect.yml rm kafka-connect




### KAFKA-CONNECT-SOURCES

1. Start the source containers with 

```
docker-compose -f docker-compose-4-kafkaconnect-source.yml up -d
```
2. Launch MySQL CLI

```
docker-compose -f docker-compose-4-kafkaconnect-source.yml exec mysql bash -c 'mysql -u $MYSQL_USER -p$MYSQL_PASSWORD demo'
```

3. Show Tables in MYSQL

```
SHOW TABLES;
```

4. Show the `Account` table

```
SELECT ACCOUNT_ID, FIRST_NAME, LAST_NAME, EMAIL, PHONE FROM accounts LIMIT 5;
```

5. in KSQL display information coming from this DB

```
SET 'auto.offset.reset' = 'earliest';
CREATE STREAM ACCOUNTS_STREAM WITH (KAFKA_TOPIC='asgard.demo.accounts', VALUE_FORMAT='AVRO');
CREATE STREAM ACCOUNTS_REKEYED WITH (PARTITIONS=1) AS SELECT * FROM ACCOUNTS_STREAM PARTITION BY ACCOUNT_ID;
-- This select statement is simply to make sure that we have time for the ACCOUNTS_REKEYED topic
-- to be created before we define a table against it
SELECT * FROM ACCOUNTS_REKEYED LIMIT 1;
CREATE TABLE ACCOUNTS WITH (KAFKA_TOPIC='ACCOUNTS_REKEYED',VALUE_FORMAT='AVRO',KEY='ACCOUNT_ID');
```

6. Update mySQL

Display edited line: 

```sql
SELECT ACCOUNT_ID, FIRST_NAME, LAST_NAME, EMAIL, PHONE FROM ACCOUNTS WHERE ACCOUNT_ID='a42';
```

```sql
UPDATE accounts SET EMAIL='none' WHERE ACCOUNT_ID='a42';
UPDATE accounts SET EMAIL='robin@rmoff.net' WHERE ACCOUNT_ID='a42';
UPDATE accounts SET EMAIL='robin@confluent.io' WHERE ACCOUNT_ID='a42';
```
 
7. Create a stream with enriched DATA

```sql
CREATE STREAM ATM_POSSIBLE_FRAUD_ENRICHED WITH (PARTITIONS=1) AS \
SELECT A.ACCOUNT_ID AS ACCOUNT_ID, \
      A.TX1_TIMESTAMP, A.TX2_TIMESTAMP, \
      A.TX1_AMOUNT, A.TX2_AMOUNT, \
      A.TX1_ATM, A.TX2_ATM, \
      A.TX1_LOCATION, A.TX2_LOCATION, \
      A.TX1_TRANSACTION_ID, A.TX2_TRANSACTION_ID, \
      A.DISTANCE_BETWEEN_TXN_KM, \
      A.MILLISECONDS_DIFFERENCE, \
      A.MINUTES_DIFFERENCE, \
      A.KMH_REQUIRED, \
      B.FIRST_NAME + ' ' + B.LAST_NAME AS CUSTOMER_NAME, \
      B.EMAIL AS CUSTOMER_EMAIL, \
      B.PHONE AS CUSTOMER_PHONE, \
      B.ADDRESS AS CUSTOMER_ADDRESS, \
      B.COUNTRY AS CUSTOMER_COUNTRY \
FROM ATM_POSSIBLE_FRAUD A \
     INNER JOIN ACCOUNTS B \
     ON A.ACCOUNT_ID = B.ACCOUNT_ID;
```

8. Query the stream

```sql
SELECT ACCOUNT_ID, CUSTOMER_NAME, CUSTOMER_PHONE, \
        TIMESTAMPTOSTRING(TX1_TIMESTAMP, 'yyyy-MM-dd HH:mm:ss'), TIMESTAMPTOSTRING(TX2_TIMESTAMP, 'HH:mm:ss'), \
        TX1_ATM, TX2_ATM, \
        DISTANCE_BETWEEN_TXN_KM, MINUTES_DIFFERENCE \
FROM ATM_POSSIBLE_FRAUD_ENRICHED;  
```

docker-compose -f docker-compose-1-confluent.yml down
docker-compose -f docker-compose-2-db.yml down
docker-compose -f docker-compose-3-kafkaconnect.yml down

docker-compose -f docker-compose-1-confluent.yml up -d
docker-compose -f docker-compose-2-db.yml up -d
docker-compose -f docker-compose-3-kafkaconnect.yml up -d


KAFKA CONNECT :
http://localhost:18083/connectors
http://localhost:18083/connectors/dse_tx

list connector :
curl -X DELETE http://localhost:18083/connectors/dse_tx
curl -X DELETE http://localhost:18083/connectors/dse_tx_flat


        
curl -s \
     -X "POST" "http://localhost:18083/connectors/" \
     -H "Content-Type: application/json" \
     -d '{
      "name": "dse_tx_flat",
      "config": {
        "connector.class": "com.datastax.kafkaconnector.DseSinkConnector",
                "tasks.max": "1",
                "topics": "ATM_POSSIBLE_FRAUD",
                "contactPoints": "dse",
                "loadBalancing.localDc": "DC1",
                "port": 9042,
                "maxConcurrentRequests": 5,
                "maxNumberOfRecordsInBatch": 8,
                "queryExecutionTimeout": 200,
                "connectionPoolLocalSize": 4,
                "jmx": false,
                "compression": "None",
                "auth.provider": "None",
                "auth.username": "",
                "auth.password": "",
                "auth.gssapi.keyTab": "",
                "auth.gssapi.principal": "",
                "auth.gssapi.service": "dse",
                "ssl.provider": "None",
                "ssl.hostnameValidation": true,
                "ssl.keystore.password": "",
                "ssl.keystore.path": "",
                "ssl.openssl.keyCertChain": "",
                "ssl.openssl.privateKey": "",
                "ssl.truststore.password": "",
                "ssl.truststore.path": "",
                "ssl.cipherSuites": "",
                "topic.ATM_POSSIBLE_FRAUD.bank.transactions.mapping": "account_id=value.ACCOUNT_ID, transaction_id=value.TRANSACTION_ID, timestamp=value.TIMESTAMP, atm=value.ATM, amount=value.AMOUNT, longitude=value.LON, latitude=value.LAT",
                "topic.ATM_POSSIBLE_FRAUD.bank.transactions.consistencyLevel": "ONE",
                "topic.ATM_POSSIBLE_FRAUD.bank.transactions.ttl": -1,
                "topic.ATM_POSSIBLE_FRAUD.bank.transactions.nullToUnset": "true",
                "topic.ATM_POSSIBLE_FRAUD.bank.transactions.deletesEnabled": "true",
                "topic.ATM_POSSIBLE_FRAUD.codec.locale": "en_US",
                "topic.ATM_POSSIBLE_FRAUD.codec.timeZone": "UTC",
                "topic.ATM_POSSIBLE_FRAUD.codec.timestamp": "yyyy-MM-dd HH:mm:ss",
                "topic.ATM_POSSIBLE_FRAUD.codec.date": "ISO_LOCAL_DATE",
                "topic.ATM_POSSIBLE_FRAUD.codec.time": "ISO_LOCAL_TIME",
                "topic.ATM_POSSIBLE_FRAUD.codec.unit": "MILLISECONDS"
            }
        }'
        
  ACCOUNT_ID=value.ACCOUNT_ID,
  TX1_TRANSACTION_ID=value.TX1_TRANSACTION_ID,
  TX1_TIMESTAMP=value.TX1_TIMESTAMP,
  TX1_AMOUNT=value.TX1_AMOUNT,
  
  TX1_LATITUDE=value.,
  TX1_LONGITUDE=value.,
  TX1_ATM=value.TX1_ATM,
  TX2_TRANSACTION_ID=value.,
  TX2_TIMESTAMP=value.TX2_TIMESTAMP,
  TX2_AMOUNT=value.,
  TX2_LATITUDE=value.,
  TX2_LONGITUDE=value.,
  TX2_ATM=value.,
  DISTANCE_IN_KM=value.DISTANCE_BETWEEN_TXN_KM,
  SHIFT_IN_MILLIS=value.MILLISECONDS_DIFFERENCE,
  SHIFT_IN_MINUTE=value.MINUTES_DIFFERENCE,
  KMH_REQUIRED=value.KMH_REQUIRED,
  
  "TX1_TRANSACTION_ID": "xxxa2ffa566-4021-11e9-8735-0242c0a82002",
  "TX2_TRANSACTION_ID": "c9cf23d4-4020-11e9-8735-0242c0a82002",
  "TX1_AMOUNT": 300,
  "TX2_AMOUNT": 200,
  "TX1_ATM": "RBS",
  "TX2_ATM": "The Co-Operative",
  "TX1_LOCATION": "53.8135182,-1.6020819",
  "TX2_LOCATION": "53.5434148,-1.5649997"
  
  
  
curl -s \
     -X "POST" "http://localhost:18083/connectors/" \
     -H "Content-Type: application/json" \
     -d '{
      "name": "dse_fraud",
      "config": {
        "connector.class": "com.datastax.kafkaconnector.DseSinkConnector",
                "tasks.max": "1",
                "topics": "atm_txns_gess",
                "contactPoints": "dse",
                "loadBalancing.localDc": "DC1",
                "port": 9042,
                "maxConcurrentRequests": 500,
                "maxNumberOfRecordsInBatch": 32,
                "queryExecutionTimeout": 30,
                "connectionPoolLocalSize": 4,
                "jmx": false,
                "compression": "None",
                "auth.provider": "None",
                "topic.atm_txns_gess.bank.transactions.mapping": "account_id=value.account_id, transaction_id=value.transaction_id, timestamp=value.timestamp, atm=value.atm, amount=value.amount",
                "topic.atm_txns_gess.bank.transactions.consistencyLevel": "ONE",
                "topic.atm_txns_gess.bank.transactions.ttl": -1,
                "topic.atm_txns_gess.bank.transactions.nullToUnset": "true",
                "topic.atm_txns_gess.bank.transactions.deletesEnabled": "true",
                "topic.atm_txns_gess.codec.locale": "en_US",
                "topic.atm_txns_gess.codec.timeZone": "UTC",
                "topic.atm_txns_gess.codec.timestamp": "yyyy-MM-dd HH:mm:ss X",
                "topic.atm_txns_gess.codec.date": "ISO_LOCAL_DATE",
                "topic.atm_txns_gess.codec.time": "ISO_LOCAL_TIME",
                "topic.atm_txns_gess.codec.unit": "MILLISECONDS"
            }
        }'
        
