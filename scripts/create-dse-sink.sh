#!/bin/sh

# ---- Sink to Elasticsearch using timestamp-based index
#
# To use this, the source topic needs to already be in lowercase
#
# In KSQL you can do this with WITH (KAFKA_TOPIC='my-lowercase-topic') 
# when creating a stream or table
#
curl -s \
     -X "POST" "http://localhost:18083/connectors/" \
     -H "Content-Type: application/json" \
     -d '{
    "name": "dse_sink_atm_txns",
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
        "topic.atm_txns_gess.bank.atm_transactions.mapping": "atm=value.atm, account_id=value.account_id, amount=value.amount, transaction_id=value.transaction_id",
        "topic.atm_txns_gess.bank.atm_transactions.consistencyLevel": "LOCAL_ONE",
        "topic.atm_txns_gess.bank.atm_transactions.ttl": -1,
        "topic.atm_txns_gess.bank.atm_transactions.nullToUnset": "true",
        "topic.atm_txns_gess.bank.atm_transactions.deletesEnabled": "true",
        "topic.atm_txns_gess.codec.locale": "en_US",
        "topic.atm_txns_gess.codec.timeZone": "UTC",
        "topic.atm_txns_gess.codec.timestamp": "CQL_TIMESTAMP",
        "topic.atm_txns_gess.codec.date": "ISO_LOCAL_DATE",
        "topic.atm_txns_gess.codec.time": "ISO_LOCAL_TIME",
        "topic.atm_txns_gess.codec.unit": "MILLISECONDS"
    }
}'